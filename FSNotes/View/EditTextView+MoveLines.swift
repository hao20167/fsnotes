//
//  EditTextView+MoveLines.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 15.12.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa
import Carbon.HIToolbox

extension EditTextView {
    func moveSelectedLinesUp() {
        guard let textStorage = textStorage,
              textStorage.length > 0 else { return }
        
        let selectedRange = selectedRange()
        
        let lineRange = textStorage.mutableString.lineRange(for: selectedRange)
        if lineRange.location == 0 {
            NSSound.beep()
            return
        }
        
        let previousLineStart = textStorage.mutableString.lineRange(
            for: NSRange(location: lineRange.location - 1, length: 0)
        ).location
        
        let previousLineRange = NSRange(
            location: previousLineStart,
            length: lineRange.location - previousLineStart
        )
        
        let currentLinesAttr = textStorage.attributedSubstring(from: lineRange)
        let previousLineAttr = textStorage.attributedSubstring(from: previousLineRange)
        
        let offsetInLine = selectedRange.location - lineRange.location
        
        let currentLinesString = currentLinesAttr.string
        let needsNewline = !currentLinesString.hasSuffix("\n")
        
        let newContent = NSMutableAttributedString()
        newContent.append(currentLinesAttr)
        
        if needsNewline {
            let attrs = currentLinesAttr.length > 0
                ? currentLinesAttr.attributes(at: currentLinesAttr.length - 1, effectiveRange: nil)
                : [:]
            newContent.append(NSAttributedString(string: "\n", attributes: attrs))
        }
        
        var previousToAppend = previousLineAttr
        if needsNewline && previousLineAttr.string.hasSuffix("\n") {
            let trimmedPrevious = NSMutableAttributedString(attributedString: previousLineAttr)
            trimmedPrevious.deleteCharacters(in: NSRange(location: trimmedPrevious.length - 1, length: 1))
            previousToAppend = trimmedPrevious
        }
        
        newContent.append(previousToAppend)
        
        let combinedRange = NSRange(
            location: previousLineRange.location,
            length: previousLineRange.length + lineRange.length
        )
        
        newContent.saveData()
        if shouldChangeText(in: combinedRange, replacementString: newContent.string) {
            textStorage.replaceCharacters(in: combinedRange, with: newContent)
            didChangeText()
        }
        
        let newSelectionLocation = previousLineRange.location + offsetInLine
        
        setSelectedRange(NSRange(
            location: newSelectionLocation,
            length: selectedRange.length
        ))
        
        scrollRangeToVisible(self.selectedRange())
    }

    func moveSelectedLinesDown() {
        guard let textStorage = textStorage,
              textStorage.length > 0 else { return }
        
        let selectedRange = selectedRange()
        let lineRange = textStorage.mutableString.lineRange(for: selectedRange)
        
        if NSMaxRange(lineRange) >= textStorage.length {
            NSSound.beep()
            return
        }
        
        let nextLineRange = textStorage.mutableString.lineRange(
            for: NSRange(location: NSMaxRange(lineRange), length: 0)
        )
        
        let currentLinesAttr = textStorage.attributedSubstring(from: lineRange)
        let nextLineAttr = textStorage.attributedSubstring(from: nextLineRange)
        
        let offsetInLine = selectedRange.location - lineRange.location
        
        let nextLineString = nextLineAttr.string
        let needsNewline = !nextLineString.hasSuffix("\n")
        
        let newContent = NSMutableAttributedString()
        var nextLineFinalLength = nextLineAttr.length
        
        newContent.append(nextLineAttr)
        
        if needsNewline {
            let attrs = nextLineAttr.length > 0
                ? nextLineAttr.attributes(at: nextLineAttr.length - 1, effectiveRange: nil)
                : [:]
            newContent.append(NSAttributedString(string: "\n", attributes: attrs))
            nextLineFinalLength += 1
        }
        
        var currentToAppend = currentLinesAttr
        if needsNewline && currentLinesAttr.string.hasSuffix("\n") {
            let trimmedCurrent = NSMutableAttributedString(attributedString: currentLinesAttr)
            trimmedCurrent.deleteCharacters(in: NSRange(location: trimmedCurrent.length - 1, length: 1))
            currentToAppend = trimmedCurrent
        }
        
        newContent.append(currentToAppend)
        
        let combinedRange = NSRange(
            location: lineRange.location,
            length: lineRange.length + nextLineRange.length
        )
        
        newContent.saveData()
        if shouldChangeText(in: combinedRange, replacementString: newContent.string) {
            textStorage.replaceCharacters(in: combinedRange, with: newContent)
            didChangeText()
        }
        
        let newSelectionLocation = lineRange.location + nextLineFinalLength + offsetInLine
        
        setSelectedRange(NSRange(
            location: newSelectionLocation,
            length: selectedRange.length
        ))
        
        scrollRangeToVisible(self.selectedRange())
    }
}

// MARK: - Vim mode (basic)

enum VimMode {
    case normal, insert, visual, visualLine
}

struct VimKey {
    let chars: String
    let control: Bool
    let keyCode: UInt16
}

/// Per-editor vim state. Text is edited only through NSTextView APIs so undo, saving
/// and attachments (images are one character carrying their metadata) keep working.
final class VimEngine {
    weak var view: EditTextView?

    var mode: VimMode = .normal {
        didSet { if oldValue != mode { modeChanged() } }
    }

    // Pending command state
    private var count = ""
    private var opCount = ""
    private var pendingOperator: Character?
    private var pendingPrefix: String = ""        // "g", "f", "t", "F", "T", "r", "i"/"a" (text objects)
    private var keyLog = [VimKey]()               // keys of the command being typed (for ".")

    // Registers / repeat state
    private var register = NSAttributedString()
    private var registerLinewise = false
    private var lastFind: (char: String, kind: Character)?
    private var desiredColumn: Int?
    private var visualAnchor = 0
    private var cursor = 0

    private var lastChange = [VimKey]()
    private var lastInserted: NSAttributedString?
    private var recordingChange = false
    private var insertStart: Int?
    private var replaying = false

    // One undo step per command, including the insert session it opens (`o…<Esc>`, `cw…<Esc>`)
    private var commandUndoOpen = false
    // The manager the group was opened on: switching notes swaps the view's manager
    private weak var commandUndoManager: UndoManager?

    private func beginCommandUndo() {
        guard !commandUndoOpen, let um = view?.undoManager, um.groupingLevel == 0 else { return }
        view?.breakUndoCoalescing()
        um.groupsByEvent = false
        um.beginUndoGrouping()
        commandUndoManager = um
        commandUndoOpen = true
    }

    func endCommandUndo() {
        guard commandUndoOpen else { return }
        commandUndoOpen = false
        let um = commandUndoManager
        commandUndoManager = nil
        view?.breakUndoCoalescing()
        guard let um = um else { return }
        if um.groupingLevel > 0 { um.endUndoGrouping() }
        um.groupsByEvent = true
    }

    /// The editor switched to another note: nothing pending may leak into it.
    func noteDidChange() {
        endCommandUndo()
        reset()
        recordingChange = false
        insertStart = nil
        desiredColumn = nil
        if mode != .normal { mode = .normal }
    }

    private var hasPendingCommand: Bool {
        pendingOperator != nil || !pendingPrefix.isEmpty || !count.isEmpty || !opCount.isEmpty
    }

    init(view: EditTextView) {
        self.view = view
    }

    // MARK: Entry

    /// Returns true when the event was consumed by vim.
    func handle(event: NSEvent) -> Bool {
        guard let view = view else { return false }

        // Let the system finish IME composition (Vietnamese Telex etc.)
        if view.hasMarkedText() { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Never steal menu shortcuts
        if flags.contains(.command) { return false }

        if mode == .insert {
            if event.keyCode == UInt16(kVK_Escape) || (flags.contains(.control) && event.charactersIgnoringModifiers == "[") {
                leaveInsert()
                return true
            }
            // Cmd+Z during insert closes our group: reopen so typing stays registrable
            if commandUndoOpen, let um = commandUndoManager, um === view.undoManager, um.groupingLevel == 0 {
                um.beginUndoGrouping()
            }
            return false
        }

        // Arrow keys / page keys keep working natively in normal mode
        let passthrough = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_PageUp, kVK_PageDown, kVK_Home, kVK_End]
        if passthrough.contains(Int(event.keyCode)) && mode == .normal {
            return false
        }

        let chars: String
        if event.keyCode == UInt16(kVK_Escape) {
            chars = "\u{1B}"
        } else if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            chars = "\r"
        } else if event.keyCode == UInt16(kVK_Delete) {
            chars = "\u{7F}"
        } else if flags.contains(.control) {
            chars = event.charactersIgnoringModifiers ?? ""
        } else {
            // Use the key's character for the US layout position when an input method rewrites it
            chars = event.characters ?? ""
        }

        guard !chars.isEmpty else { return true }

        // The undo group is opened lazily by the first edit (see `replace`/`enterInsert`):
        // empty groups would otherwise become no-op undo steps.
        let isUndoKey = !hasPendingCommand && ((chars == "u" && !flags.contains(.control)) || (chars == "r" && flags.contains(.control)))
        if isUndoKey {
            endCommandUndo()
        }

        process(VimKey(chars: chars, control: flags.contains(.control), keyCode: event.keyCode))

        if mode != .insert && !hasPendingCommand {
            endCommandUndo()
        }
        return true
    }

    // MARK: Text helpers

    private var text: NSString { (view?.textStorage?.string ?? "") as NSString }
    private var length: Int { text.length }

    private func lineRange(_ loc: Int) -> NSRange {
        text.lineRange(for: NSRange(location: min(loc, length), length: 0))
    }

    /// End of the line's content (before the newline)
    private func lineEnd(_ loc: Int) -> Int {
        let r = lineRange(loc)
        var end = NSMaxRange(r)
        if end > r.location, end <= length, end > 0, text.character(at: end - 1) == 0x0A { end -= 1 }
        return end
    }

    private func lineStart(_ loc: Int) -> Int { lineRange(loc).location }

    /// Last character position a normal-mode cursor may stand on
    private func lastCharPos(_ loc: Int) -> Int {
        let start = lineStart(loc), end = lineEnd(loc)
        guard end > start else { return start }
        return text.rangeOfComposedCharacterSequence(at: end - 1).location
    }

    private func firstNonBlank(_ loc: Int) -> Int {
        var i = lineStart(loc)
        let end = lineEnd(loc)
        while i < end, isBlank(text.character(at: i)) { i += 1 }
        return i
    }

    private func isBlank(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
    private func isNewline(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D }

    private func next(_ loc: Int) -> Int {
        guard loc < length else { return length }
        return NSMaxRange(text.rangeOfComposedCharacterSequence(at: loc))
    }

    private func prev(_ loc: Int) -> Int {
        guard loc > 0 else { return 0 }
        return text.rangeOfComposedCharacterSequence(at: loc - 1).location
    }

    private func column(_ loc: Int) -> Int { loc - lineStart(loc) }

    private func lineIndex(_ loc: Int) -> Int {
        var n = 0, i = 0
        let target = min(loc, length)
        while i < target {
            if text.character(at: i) == 0x0A { n += 1 }
            i += 1
        }
        return n
    }

    private func lineCount() -> Int {
        guard length > 0 else { return 1 }
        return lineIndex(length) + 1
    }

    private func startOfLine(index: Int) -> Int {
        var n = 0, i = 0
        if index <= 0 { return 0 }
        while i < length {
            if text.character(at: i) == 0x0A {
                n += 1
                if n == index { return i + 1 }
            }
            i += 1
        }
        return lineStart(length)
    }

    private enum CharClass { case blank, newline, word, punct }

    private func charClass(_ loc: Int, bigWord: Bool) -> CharClass {
        guard loc < length else { return .newline }
        let c = text.character(at: loc)
        if isNewline(c) { return .newline }
        if isBlank(c) { return .blank }
        if bigWord { return .word }
        if let scalar = UnicodeScalar(c), CharacterSet.alphanumerics.contains(scalar) || c == 0x5F { return .word }
        if c >= 0xD800 && c <= 0xDFFF { return .word }
        if c == 0xFFFC { return .punct }   // attachment (image) is its own word
        return .punct
    }

    // MARK: Selection / cursor

    private func setCursor(_ loc: Int, keepColumn: Bool = false) {
        guard let view = view else { return }
        var loc = max(0, min(loc, length))
        if mode == .normal {
            loc = min(loc, lastCharPos(loc))
        }
        cursor = loc
        if !keepColumn { desiredColumn = nil }

        switch mode {
        case .visual:
            let a = min(visualAnchor, loc), b = max(visualAnchor, loc)
            view.setSelectedRange(NSRange(location: a, length: min(next(b), length) - a))
        case .visualLine:
            let a = lineStart(min(visualAnchor, loc)), b = NSMaxRange(lineRange(max(visualAnchor, loc)))
            view.setSelectedRange(NSRange(location: a, length: b - a))
        default:
            view.setSelectedRange(NSRange(location: loc, length: 0))
        }
        view.scrollRangeToVisible(NSRange(location: loc, length: 0))
        view.needsDisplay = true
    }

    private func syncCursorFromView() {
        guard let view = view else { return }
        let sel = view.selectedRange()
        if mode == .visual || mode == .visualLine { return }
        cursor = min(sel.location, length)
    }

    // MARK: Editing primitives (undoable)

    private func replace(_ range: NSRange, with string: NSAttributedString) {
        guard let view = view, let storage = view.textStorage else { return }
        let safe = NSRange(location: min(range.location, storage.length),
                           length: min(range.length, storage.length - min(range.location, storage.length)))
        beginCommandUndo()
        guard view.shouldChangeText(in: safe, replacementString: string.string) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: safe, with: string)
        storage.endEditing()
        view.didChangeText()
    }

    private func replace(_ range: NSRange, with string: String) {
        guard let view = view else { return }
        let attrs = view.typingAttributes
        replace(range, with: NSAttributedString(string: string, attributes: attrs))
    }

    private func yank(_ range: NSRange, linewise: Bool) {
        guard let storage = view?.textStorage, range.location <= storage.length else { return }
        let safe = NSRange(location: range.location, length: min(range.length, storage.length - range.location))
        let sub = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: safe))
        if linewise, sub.length == 0 || !sub.string.hasSuffix("\n") {
            sub.append(NSAttributedString(string: "\n"))
        }
        register = sub
        registerLinewise = linewise

        // Mirror plain text to the system pasteboard (images stay in the vim register)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(sub.string.replacingOccurrences(of: "\u{FFFC}", with: ""), forType: .string)
    }

    private func group(_ block: () -> Void) {
        beginCommandUndo()
        let um = view?.undoManager
        view?.breakUndoCoalescing()
        um?.beginUndoGrouping()
        block()
        um?.endUndoGrouping()
        view?.breakUndoCoalescing()
    }

    // MARK: Modes

    func enterInsert(at loc: Int) {
        beginCommandUndo()
        mode = .insert
        guard let view = view else { return }
        let l = max(0, min(loc, length))
        view.setSelectedRange(NSRange(location: l, length: 0))
        insertStart = l
        view.breakUndoCoalescing()
        view.needsDisplay = true
    }

    private func leaveInsert() {
        guard let view = view else { return }
        let loc = view.selectedRange().location

        if recordingChange, !replaying, let start = insertStart, loc >= start, let storage = view.textStorage {
            lastInserted = storage.attributedSubstring(from: NSRange(location: start, length: loc - start))
            lastChange = keyLog
        }
        recordingChange = false
        if !replaying { keyLog = [] }
        insertStart = nil
        view.breakUndoCoalescing()
        endCommandUndo()

        mode = .normal
        var target = loc
        if target > lineStart(target) { target = prev(target) }
        setCursor(target)
    }

    func reset() {
        count = ""; opCount = ""; pendingOperator = nil; pendingPrefix = ""; keyLog = []
    }

    private func modeChanged() {
        view?.needsDisplay = true
        view?.updateVimIndicator()
    }

    // MARK: Dispatcher

    private func process(_ key: VimKey) {
        guard view != nil else { return }
        if !replaying { keyLog.append(key) }

        if mode == .normal || mode == .visual || mode == .visualLine {
            if mode == .normal, pendingOperator == nil, pendingPrefix.isEmpty, count.isEmpty {
                syncCursorFromView()
            }
            normal(key)
        }
    }

    private func finishCommand(isChange: Bool) {
        if isChange, !replaying {
            if mode == .insert {
                recordingChange = true          // completed when leaving insert
            } else {
                lastChange = keyLog
                lastInserted = nil
            }
        }
        if mode != .insert || !isChange {
            if !(mode == .insert && recordingChange) { keyLog = [] }
        }
        count = ""; opCount = ""; pendingOperator = nil; pendingPrefix = ""
    }

    private var effectiveCount: Int {
        let a = Int(count) ?? 1, b = Int(opCount) ?? 1
        return max(1, a * b)
    }

    private var hasCount: Bool { !count.isEmpty || !opCount.isEmpty }

    // MARK: Normal / visual mode

    private func normal(_ key: VimKey) {
        let c = key.chars

        if c == "\u{1B}" {
            if mode == .visual || mode == .visualLine {
                mode = .normal
                setCursor(cursor)
            }
            keyLog = []
            count = ""; opCount = ""; pendingOperator = nil; pendingPrefix = ""
            return
        }

        if key.control {
            switch c {
            case "r":
                for _ in 0..<effectiveCount { view?.undoManager?.redo() }
                afterUndo()
            case "d":
                scrollHalfPage(down: true)
            case "u":
                scrollHalfPage(down: false)
            default:
                break
            }
            keyLog = []
            count = ""
            return
        }

        // Pending single-char arguments
        if !pendingPrefix.isEmpty {
            handlePrefix(pendingPrefix, key: c)
            return
        }

        // Counts
        if let ch = c.first, c.count == 1, ch.isNumber, ch.isASCII, !(ch == "0" && count.isEmpty) {
            count.append(ch)
            return
        }

        // Operators
        if ["d", "c", "y", ">", "<"].contains(c) {
            let op = Character(c)
            if mode == .visual || mode == .visualLine {
                applyVisual(op)
                return
            }
            if pendingOperator == op {
                // dd, cc, yy, >>, <<
                let lines = effectiveCount
                let start = lineStart(cursor)
                let lastLineStart = startOfLine(index: min(lineIndex(cursor) + lines - 1, lineCount() - 1))
                apply(op, range: NSRange(location: start, length: NSMaxRange(lineRange(lastLineStart)) - start), linewise: true)
                return
            }
            if pendingOperator == nil {
                pendingOperator = op
                opCount = count
                count = ""
                return
            }
            reset()
            return
        }

        // Text objects after an operator or in visual mode
        if (pendingOperator != nil || mode == .visual) && (c == "i" || c == "a") {
            pendingPrefix = c
            return
        }

        switch c {
        case "g", "f", "F", "t", "T", "r":
            pendingPrefix = c
            return
        default:
            break
        }

        if let motion = motion(for: c) {
            runMotion(motion)
            return
        }

        // Commands without operator
        if pendingOperator != nil { reset(); return }

        if mode == .visual || mode == .visualLine {
            switch c {
            case "x": applyVisual("d")
            case "s": applyVisual("c")
            case "J": applyVisual("J")
            case "o":
                let a = visualAnchor
                visualAnchor = cursor
                setCursor(a)
            case "v":
                mode = mode == .visual ? .normal : .visual
                setCursor(cursor)
            case "V":
                mode = mode == .visualLine ? .normal : .visualLine
                setCursor(cursor)
            case "p", "P":
                applyVisualPut()
            default: break
            }
            if mode == .normal { keyLog = [] }
            count = ""
            return
        }

        command(c)
    }

    private func handlePrefix(_ prefix: String, key c: String) {
        pendingPrefix = ""
        switch prefix {
        case "g":
            if c == "g" {
                let target = hasCount ? startOfLine(index: (Int(count) ?? 1) - 1) : 0
                count = ""
                runMotion(Motion(target: firstNonBlank(target), kind: .linewise))
            } else if c == "J" {
                command("gJ")
            } else {
                reset()
            }
        case "f", "F", "t", "T":
            lastFind = (c, Character(prefix))
            if let target = find(c, kind: Character(prefix), from: cursor, count: effectiveCount) {
                runMotion(Motion(target: target, kind: prefix == "f" || prefix == "t" ? .inclusive : .exclusive))
            } else {
                reset()
            }
        case "r":
            replaceChars(with: c)
        case "i", "a":
            if let range = textObject(c, inner: prefix == "i") {
                if mode == .visual {
                    visualAnchor = range.location
                    setCursor(max(range.location, NSMaxRange(range) - 1))
                    count = ""
                } else if let op = pendingOperator {
                    apply(op, range: range, linewise: false)
                }
            } else {
                reset()
            }
        default:
            reset()
        }
    }

    // MARK: Motions

    private enum MotionKind { case exclusive, inclusive, linewise }

    private struct Motion {
        let target: Int
        let kind: MotionKind
        var keepColumn = false
    }

    private func motion(for c: String) -> Motion? {
        let n = effectiveCount
        switch c {
        case "h", "\u{7F}":
            var t = cursor
            for _ in 0..<n where t > lineStart(cursor) { t = prev(t) }
            return Motion(target: t, kind: .exclusive)
        case "l", " ":
            var t = cursor
            let limit = pendingOperator != nil ? lineEnd(cursor) : lastCharPos(cursor)
            for _ in 0..<n where t < limit { t = next(t) }
            return Motion(target: min(t, limit), kind: .exclusive)
        case "j", "k", "\r", "+", "-":
            let down = c == "j" || c == "\r" || c == "+"
            let idx = lineIndex(cursor)
            let targetIdx = max(0, min(lineCount() - 1, idx + (down ? n : -n)))
            let start = startOfLine(index: targetIdx)
            if c == "\r" || c == "+" || c == "-" {
                return Motion(target: firstNonBlank(start), kind: .linewise)
            }
            let col = desiredColumn ?? column(cursor)
            desiredColumn = col
            let t = min(start + col, mode == .normal && pendingOperator == nil ? lastCharPos(start) : lineEnd(start))
            return Motion(target: t, kind: .linewise, keepColumn: true)
        case "w", "W":
            var t = cursor
            for i in 0..<n { t = wordForward(t, bigWord: c == "W", stopAtLineEnd: pendingOperator != nil && i == n - 1) }
            // cw behaves like ce
            if pendingOperator == "c", charClass(cursor, bigWord: c == "W") != .blank {
                var e = cursor
                for _ in 0..<n { e = wordEnd(e, bigWord: c == "W", fromCursor: true) }
                return Motion(target: e, kind: .inclusive)
            }
            return Motion(target: t, kind: .exclusive)
        case "b", "B":
            var t = cursor
            for _ in 0..<n { t = wordBackward(t, bigWord: c == "B") }
            return Motion(target: t, kind: .exclusive)
        case "e", "E":
            var t = cursor
            for _ in 0..<n { t = wordEnd(t, bigWord: c == "E", fromCursor: false) }
            return Motion(target: t, kind: .inclusive)
        case "0":
            return Motion(target: lineStart(cursor), kind: .exclusive)
        case "^", "_":
            return Motion(target: firstNonBlank(cursor), kind: .exclusive)
        case "$":
            let idx = min(lineCount() - 1, lineIndex(cursor) + n - 1)
            let start = startOfLine(index: idx)
            let end = lineEnd(start)
            return Motion(target: end > start ? prev(end) : start, kind: .inclusive)
        case "G":
            let idx = hasCount ? (Int(count) ?? 1) - 1 : lineCount() - 1
            return Motion(target: firstNonBlank(startOfLine(index: max(0, min(idx, lineCount() - 1)))), kind: .linewise)
        case ";", ",":
            guard let last = lastFind else { return nil }
            var kind = last.kind
            if c == "," {
                let opposite: [Character: Character] = ["f": "F", "F": "f", "t": "T", "T": "t"]
                kind = opposite[kind] ?? kind
            }
            guard let t = find(last.char, kind: kind, from: cursor, count: n, repeating: true) else { return Motion(target: cursor, kind: .exclusive) }
            return Motion(target: t, kind: kind == "f" || kind == "t" ? .inclusive : .exclusive)
        case "}":
            var t = cursor
            for _ in 0..<n { t = paragraphForward(t) }
            return Motion(target: t, kind: .exclusive)
        case "{":
            var t = cursor
            for _ in 0..<n { t = paragraphBackward(t) }
            return Motion(target: t, kind: .exclusive)
        default:
            return nil
        }
    }

    private func runMotion(_ motion: Motion) {
        if let op = pendingOperator {
            var a = min(cursor, motion.target), b = max(cursor, motion.target)
            switch motion.kind {
            case .linewise:
                a = lineStart(a)
                b = NSMaxRange(lineRange(b))
                apply(op, range: NSRange(location: a, length: b - a), linewise: true)
            case .inclusive:
                b = next(b)
                apply(op, range: NSRange(location: a, length: b - a), linewise: false)
            case .exclusive:
                apply(op, range: NSRange(location: a, length: b - a), linewise: false)
            }
            return
        }

        setCursor(motion.target, keepColumn: motion.keepColumn)
        count = ""
        keyLog = []
    }

    private func wordForward(_ from: Int, bigWord: Bool, stopAtLineEnd: Bool) -> Int {
        var i = from
        guard i < length else { return length }
        let startLineEnd = lineEnd(from)
        let cls = charClass(i, bigWord: bigWord)
        if cls == .word || cls == .punct {
            while i < length, charClass(i, bigWord: bigWord) == cls { i = next(i) }
        }
        if stopAtLineEnd && i >= startLineEnd && from < startLineEnd { return startLineEnd }
        // skip blanks; an empty line is a word
        while i < length {
            let k = charClass(i, bigWord: bigWord)
            if k == .blank { i = next(i); continue }
            if k == .newline {
                if stopAtLineEnd && i >= startLineEnd { return i }
                i += 1
                if i < length, text.character(at: i) == 0x0A { return i }   // empty line
                continue
            }
            break
        }
        return i
    }

    private func wordEnd(_ from: Int, bigWord: Bool, fromCursor: Bool) -> Int {
        var i = fromCursor ? from : next(from)
        while i < length, [.blank, .newline].contains(charClass(i, bigWord: bigWord)) { i = next(i) }
        guard i < length else { return max(0, prev(length)) }
        let cls = charClass(i, bigWord: bigWord)
        while next(i) < length, charClass(next(i), bigWord: bigWord) == cls { i = next(i) }
        return i
    }

    private func wordBackward(_ from: Int, bigWord: Bool) -> Int {
        var i = prev(from)
        while i > 0, [.blank, .newline].contains(charClass(i, bigWord: bigWord)) {
            if charClass(i, bigWord: bigWord) == .newline, i > 0, text.character(at: i - 1) == 0x0A { return i }
            i = prev(i)
        }
        let cls = charClass(i, bigWord: bigWord)
        while i > 0, charClass(prev(i), bigWord: bigWord) == cls { i = prev(i) }
        return i
    }

    /// The line starting at `start` is empty (the empty last line counts)
    private func isBlankLine(at start: Int, in t: NSString) -> Bool {
        start >= t.length || t.character(at: start) == 0x0A
    }

    /// Start of the following line, nil on the last line
    private func nextLineStart(_ start: Int, in t: NSString) -> Int? {
        var i = start
        let n = t.length
        while i < n, t.character(at: i) != 0x0A { i += 1 }
        return i < n ? i + 1 : nil
    }

    /// `}`: skip blank lines (when starting on one), then stop at the next blank line.
    /// Walks line by line from the cursor (linear, no rescans from the top).
    private func paragraphForward(_ from: Int) -> Int {
        let t = text
        var p: Int? = lineStart(from)
        while let q = p, isBlankLine(at: q, in: t) { p = nextLineStart(q, in: t) }
        while let q = p, !isBlankLine(at: q, in: t) { p = nextLineStart(q, in: t) }
        return p ?? lastCharPos(t.length)
    }

    /// `{`: same, backwards
    private func paragraphBackward(_ from: Int) -> Int {
        let t = text
        var p = lineStart(from)
        while p > 0, isBlankLine(at: p, in: t) { p = t.lineRange(for: NSRange(location: p - 1, length: 0)).location }
        while p > 0, !isBlankLine(at: p, in: t) { p = t.lineRange(for: NSRange(location: p - 1, length: 0)).location }
        return p
    }

    private func find(_ ch: String, kind: Character, from: Int, count: Int, repeating: Bool = false) -> Int? {
        guard let target = (ch as NSString).length > 0 ? (ch as NSString).character(at: 0) : nil else { return nil }
        let start = lineStart(from), end = lineEnd(from)
        var pos = from
        for n in 0..<count {
            switch kind {
            case "f", "t":
                var i = next(pos)
                // ";" after "t" must skip the char right before the target
                if kind == "t", repeating || n > 0 { i = next(i) }
                while i < end, text.character(at: i) != target { i = next(i) }
                guard i < end else { return nil }
                pos = kind == "t" ? prev(i) : i
            default:
                var i = pos - 1
                if kind == "T", repeating || n > 0 { i -= 1 }
                while i >= start, text.character(at: i) != target { i -= 1 }
                guard i >= start else { return nil }
                pos = kind == "T" ? next(i) : i
            }
        }
        return pos
    }

    // MARK: Text objects

    private func textObject(_ c: String, inner: Bool) -> NSRange? {
        switch c {
        case "w", "W":
            let big = c == "W"
            var a = cursor, b = cursor
            guard cursor < length else { return nil }
            let cls = charClass(cursor, bigWord: big)
            while a > lineStart(cursor), charClass(prev(a), bigWord: big) == cls { a = prev(a) }
            while b < lineEnd(cursor), charClass(b, bigWord: big) == cls { b = next(b) }
            if !inner {
                var e = b
                while e < lineEnd(cursor), charClass(e, bigWord: big) == .blank { e = next(e) }
                if e > b { b = e } else {
                    while a > lineStart(cursor), charClass(prev(a), bigWord: big) == .blank { a = prev(a) }
                }
            }
            return NSRange(location: a, length: b - a)
        case "\"", "'", "`":
            let q = (c as NSString).character(at: 0)
            let start = lineStart(cursor), end = lineEnd(cursor)
            var positions = [Int]()
            var i = start
            while i < end { if text.character(at: i) == q { positions.append(i) }; i += 1 }
            var pair: (Int, Int)?
            var k = 0
            while k + 1 < positions.count {
                if cursor >= positions[k] && cursor <= positions[k + 1] { pair = (positions[k], positions[k + 1]); break }
                k += 2
            }
            if pair == nil, let first = positions.firstIndex(where: { $0 > cursor }), first + 1 < positions.count {
                pair = (positions[first], positions[first + 1])
            }
            guard let (open, close) = pair else { return nil }
            return inner ? NSRange(location: open + 1, length: close - open - 1) : NSRange(location: open, length: close - open + 1)
        case "(", ")", "b", "[", "]", "{", "}", "B", "<", ">":
            let pairs: [String: (unichar, unichar)] = [
                "(": (0x28, 0x29), ")": (0x28, 0x29), "b": (0x28, 0x29),
                "[": (0x5B, 0x5D), "]": (0x5B, 0x5D),
                "{": (0x7B, 0x7D), "}": (0x7B, 0x7D), "B": (0x7B, 0x7D),
                "<": (0x3C, 0x3E), ">": (0x3C, 0x3E)
            ]
            guard let (open, close) = pairs[c] else { return nil }
            var depth = 0
            var i = min(cursor, length - 1)
            var openPos: Int?
            if i >= 0, i < length, text.character(at: i) == close { i -= 1 }
            while i >= 0 {
                let ch = text.character(at: i)
                if ch == close { depth += 1 }
                if ch == open { if depth == 0 { openPos = i; break }; depth -= 1 }
                i -= 1
            }
            guard let o = openPos else { return nil }
            depth = 0
            var j = o + 1
            var closePos: Int?
            while j < length {
                let ch = text.character(at: j)
                if ch == open { depth += 1 }
                if ch == close { if depth == 0 { closePos = j; break }; depth -= 1 }
                j += 1
            }
            guard let cl = closePos else { return nil }
            return inner ? NSRange(location: o + 1, length: cl - o - 1) : NSRange(location: o, length: cl - o + 1)
        default:
            return nil
        }
    }

    // MARK: Operators

    private func apply(_ op: Character, range: NSRange, linewise: Bool) {
        guard view != nil else { return }
        var range = range
        range.length = min(range.length, length - range.location)

        switch op {
        case "y":
            yank(range, linewise: linewise)
            mode = .normal
            setCursor(linewise ? min(cursor, max(range.location, cursor)) : range.location)
            finishCommand(isChange: false)

        case "d":
            yank(range, linewise: linewise)
            group {
                var r = range
                // Deleting the last line(s): also remove the newline before them
                if linewise, NSMaxRange(r) == length, r.location > 0, !(text.substring(with: r).hasSuffix("\n")) {
                    r = NSRange(location: r.location - 1, length: r.length + 1)
                }
                replace(r, with: "")
            }
            mode = .normal
            setCursor(linewise ? firstNonBlank(min(range.location, length)) : range.location)
            finishCommand(isChange: true)

        case "c":
            yank(range, linewise: linewise)
            var r = range
            if linewise {
                // keep the line (and its indentation), replace its content
                let indentEnd = firstNonBlank(r.location)
                let end = text.substring(with: r).hasSuffix("\n") ? NSMaxRange(r) - 1 : NSMaxRange(r)
                r = NSRange(location: indentEnd, length: max(0, end - indentEnd))
            }
            view?.breakUndoCoalescing()
            replace(r, with: "")
            mode = .normal
            enterInsert(at: r.location)
            finishCommand(isChange: true)

        case ">", "<":
            indentLines(range, outdent: op == "<")
            mode = .normal
            setCursor(firstNonBlank(range.location))
            finishCommand(isChange: true)

        case "J":
            let lines = max(2, lineIndex(NSMaxRange(range) - 1) - lineIndex(range.location) + 1)
            mode = .normal
            setCursor(range.location)
            join(lines: lines, spaces: true)
            finishCommand(isChange: true)

        default:
            reset()
        }
    }

    private func applyVisual(_ op: Character) {
        let sel = view?.selectedRange() ?? NSRange(location: cursor, length: 0)
        let linewise = mode == .visualLine
        apply(op, range: sel, linewise: linewise)
    }

    private func applyVisualPut() {
        let sel = view?.selectedRange() ?? NSRange(location: cursor, length: 0)
        let content = register
        group {
            replace(sel, with: content)
        }
        mode = .normal
        setCursor(sel.location)
        finishCommand(isChange: true)
    }

    private func indentUnit() -> String {
        switch UserDefaultsManagement.indentUsing {
        case 0x01: return "  "
        case 0x02: return "    "
        default: return "\t"
        }
    }

    private func indentLines(_ range: NSRange, outdent: Bool) {
        let first = lineIndex(range.location)
        let last = lineIndex(max(range.location, NSMaxRange(range) - 1))
        let unit = indentUnit()
        group {
            for idx in stride(from: last, through: first, by: -1) {
                let start = startOfLine(index: idx)
                if outdent {
                    var n = 0
                    let end = lineEnd(start)
                    while n < (unit as NSString).length, start + n < end, isBlank(text.character(at: start + n)) {
                        n += 1
                        if text.character(at: start + n - 1) == 0x09 { break }
                    }
                    if n > 0 { replace(NSRange(location: start, length: n), with: "") }
                } else if lineEnd(start) > start {
                    replace(NSRange(location: start, length: 0), with: unit)
                }
            }
        }
    }

    // MARK: Simple commands

    private func command(_ c: String) {
        let n = effectiveCount
        switch c {
        case "i": enterInsert(at: cursor); finishCommand(isChange: true)
        case "a": enterInsert(at: lineEnd(cursor) > lineStart(cursor) ? next(cursor) : cursor); finishCommand(isChange: true)
        case "I": enterInsert(at: firstNonBlank(cursor)); finishCommand(isChange: true)
        case "A": enterInsert(at: lineEnd(cursor)); finishCommand(isChange: true)
        case "o":
            let end = lineEnd(cursor)
            let indent = text.substring(with: NSRange(location: lineStart(cursor), length: firstNonBlank(cursor) - lineStart(cursor)))
            view?.breakUndoCoalescing()
            replace(NSRange(location: end, length: 0), with: "\n" + indent)
            enterInsert(at: end + 1 + (indent as NSString).length)
            finishCommand(isChange: true)
        case "O":
            let start = lineStart(cursor)
            let indent = text.substring(with: NSRange(location: start, length: firstNonBlank(cursor) - start))
            view?.breakUndoCoalescing()
            replace(NSRange(location: start, length: 0), with: indent + "\n")
            enterInsert(at: start + (indent as NSString).length)
            finishCommand(isChange: true)
        case "v":
            mode = .visual
            visualAnchor = cursor
            setCursor(cursor)
            count = ""; keyLog = []
        case "V":
            mode = .visualLine
            visualAnchor = cursor
            setCursor(cursor)
            count = ""; keyLog = []
        case "x", "X":
            guard lineEnd(cursor) > lineStart(cursor) else { reset(); return }
            var a = cursor, b = cursor
            if c == "x" {
                for _ in 0..<n where b < lineEnd(cursor) { b = next(b) }
            } else {
                for _ in 0..<n where a > lineStart(cursor) { a = prev(a) }
            }
            guard b > a else { reset(); return }
            apply("d", range: NSRange(location: a, length: b - a), linewise: false)
        case "s":
            var b = cursor
            for _ in 0..<n where b < lineEnd(cursor) { b = next(b) }
            apply("c", range: NSRange(location: cursor, length: b - cursor), linewise: false)
        case "S":
            pendingOperator = "c"; process(VimKey(chars: "c", control: false, keyCode: 0))
        case "D", "C":
            let end = lineEnd(startOfLine(index: min(lineCount() - 1, lineIndex(cursor) + n - 1)))
            apply(c == "D" ? "d" : "c", range: NSRange(location: cursor, length: max(0, end - cursor)), linewise: false)
        case "Y":
            let start = lineStart(cursor)
            let lastStart = startOfLine(index: min(lineCount() - 1, lineIndex(cursor) + n - 1))
            apply("y", range: NSRange(location: start, length: NSMaxRange(lineRange(lastStart)) - start), linewise: true)
        case "p", "P":
            put(after: c == "p", count: n)
        case "J":
            join(lines: max(2, n), spaces: true)
            finishCommand(isChange: true)
        case "gJ":
            join(lines: max(2, n), spaces: false)
            finishCommand(isChange: true)
        case "~":
            toggleCase(count: n)
        case "u":
            for _ in 0..<n { view?.undoManager?.undo() }
            afterUndo()
            keyLog = []; count = ""
        case ".":
            repeatLastChange()
        default:
            // Unknown key in normal mode: swallow it so nothing gets typed
            reset()
        }
    }

    private func put(after: Bool, count n: Int) {
        guard register.length > 0 else { reset(); return }
        let content = NSMutableAttributedString()
        for _ in 0..<n { content.append(register) }

        group {
            if registerLinewise {
                if after {
                    let lr = lineRange(cursor)
                    var insertAt = NSMaxRange(lr)
                    if insertAt == length, !(text.substring(with: lr).hasSuffix("\n")) {
                        // last line without newline: prepend one, drop the trailing one
                        let c = NSMutableAttributedString(string: "\n")
                        let body = NSMutableAttributedString(attributedString: content)
                        if body.string.hasSuffix("\n") { body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1)) }
                        c.append(body)
                        replace(NSRange(location: insertAt, length: 0), with: c)
                        insertAt += 1
                    } else {
                        replace(NSRange(location: insertAt, length: 0), with: content)
                    }
                    setCursor(firstNonBlank(insertAt))
                } else {
                    let start = lineStart(cursor)
                    replace(NSRange(location: start, length: 0), with: content)
                    setCursor(firstNonBlank(start))
                }
            } else {
                let at = after && lineEnd(cursor) > lineStart(cursor) ? next(cursor) : cursor
                replace(NSRange(location: at, length: 0), with: content)
                setCursor(at + content.length - 1)
            }
        }
        finishCommand(isChange: true)
    }

    private func replaceChars(with c: String) {
        let n = effectiveCount
        var b = cursor
        for _ in 0..<n where b < lineEnd(cursor) { b = next(b) }
        guard b > cursor, b - cursor >= n || n == 1 else { reset(); return }
        let replacement = c == "\r" ? "\n" : String(repeating: c, count: n)
        let start = cursor
        group { replace(NSRange(location: start, length: b - start), with: replacement) }
        setCursor(c == "\r" ? start + 1 : start + (replacement as NSString).length - 1)
        finishCommand(isChange: true)
    }

    private func join(lines: Int, spaces: Bool) {
        group {
            for _ in 0..<(lines - 1) {
                let end = lineEnd(cursor)
                guard end < length else { break }
                var k = end + 1
                // gJ keeps the next line's leading whitespace, J drops it
                while spaces, k < length, isBlank(text.character(at: k)) { k += 1 }
                let nextEmpty = k >= length || text.character(at: k) == 0x0A
                let prevBlank = end > lineStart(cursor) && isBlank(text.character(at: end - 1))
                let sep = (!spaces || nextEmpty || prevBlank || end == lineStart(cursor)) ? "" : " "
                replace(NSRange(location: end, length: k - end), with: sep)
                cursor = end
            }
        }
        setCursor(cursor)
    }

    private func toggleCase(count n: Int) {
        var b = cursor
        for _ in 0..<n where b < lineEnd(cursor) { b = next(b) }
        guard b > cursor else { reset(); return }
        let r = NSRange(location: cursor, length: b - cursor)
        let s = text.substring(with: r)
        let toggled = s.map { ch -> String in
            let str = String(ch)
            return str == str.uppercased() ? str.lowercased() : str.uppercased()
        }.joined()
        let start = cursor
        group { replace(r, with: toggled) }
        setCursor(start + (toggled as NSString).length)
        finishCommand(isChange: true)
    }

    private func afterUndo() {
        guard let view = view else { return }
        mode = .normal
        setCursor(view.selectedRange().location)
    }

    private func scrollHalfPage(down: Bool) {
        guard let view = view, let lm = view.layoutManager, let container = view.textContainer else { return }
        _ = lm; _ = container
        let visible = view.visibleRect
        let lines = Int(visible.height / max(1, UserDefaultsManagement.noteFont.pointSize * 1.5)) / 2
        let idx = max(0, min(lineCount() - 1, lineIndex(cursor) + (down ? lines : -lines)))
        setCursor(firstNonBlank(startOfLine(index: idx)))
    }

    private func repeatLastChange() {
        guard !lastChange.isEmpty else { reset(); return }
        var keys = lastChange
        let inserted = lastInserted
        let repeatCount = count
        count = ""; keyLog = []

        // A count typed before "." replaces the original leading count
        if !repeatCount.isEmpty {
            while let first = keys.first, first.chars.count == 1, let ch = first.chars.first, ch.isNumber, ch != "0" || false {
                keys.removeFirst()
            }
            keys = repeatCount.map { VimKey(chars: String($0), control: false, keyCode: 0) } + keys
        }

        replaying = true
        group {
            for key in keys {
                process(key)
            }
            if mode == .insert, let inserted = inserted, let view = view {
                let loc = view.selectedRange().location
                replace(NSRange(location: loc, length: 0), with: inserted)
                view.setSelectedRange(NSRange(location: loc + inserted.length, length: 0))
                leaveInsert()
            }
        }
        replaying = false
        keyLog = []
    }
}

// MARK: - EditTextView glue

private var vimEngineKey: UInt8 = 0

extension EditTextView {
    var vim: VimEngine {
        if let engine = objc_getAssociatedObject(self, &vimEngineKey) as? VimEngine {
            return engine
        }
        let engine = VimEngine(view: self)
        objc_setAssociatedObject(self, &vimEngineKey, engine, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return engine
    }

    /// Block caret in normal/visual mode
    var isVimBlockCaret: Bool {
        UserDefaultsManagement.vimMode && vim.mode != .insert
    }

    /// "-- INSERT -- " style prefix for the status counter
    var vimIndicatorPrefix: String {
        guard UserDefaultsManagement.vimMode else { return "" }
        switch vim.mode {
        case .normal: return "NORMAL  "
        case .insert: return "INSERT  "
        case .visual: return "VISUAL  "
        case .visualLine: return "V-LINE  "
        }
    }

    func updateVimIndicator() {
        guard let vc = ViewController.shared(), vc.editor === self, let counter = vc.counter else { return }
        var base = counter.stringValue
        for prefix in ["NORMAL  ", "INSERT  ", "VISUAL  ", "V-LINE  "] where base.hasPrefix(prefix) {
            base = String(base.dropFirst(prefix.count))
        }
        counter.stringValue = vimIndicatorPrefix + base
    }

    func vimModeDidToggle() {
        vim.endCommandUndo()
        vim.reset()
        vim.mode = .normal
        updateVimIndicator()
        needsDisplay = true
    }

    /// Called from keyDown; returns true when vim consumed the event.
    func handleVimKeyDown(_ event: NSEvent) -> Bool {
        guard UserDefaultsManagement.vimMode, isEditable, note != nil else { return false }
        return vim.handle(event: event)
    }

    /// Steady (non-blinking) block caret
    func drawVimBlockCaret(in rect: NSRect, color: NSColor) {
        var block = rect
        block.size.width = vimCaretWidth()
        color.withAlphaComponent(0.45).setFill()
        block.fill(using: .sourceOver)
    }

    func vimCaretWidth() -> CGFloat {
        guard let storage = textStorage, let lm = layoutManager, let container = textContainer else { return 8 }
        let loc = selectedRange().location
        if loc < storage.length, (storage.string as NSString).character(at: loc) != 0x0A {
            let glyph = lm.glyphIndexForCharacter(at: loc)
            let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            if rect.width > 1 { return min(rect.width, UserDefaultsManagement.noteFont.pointSize * 1.2) }
        }
        return max(6, UserDefaultsManagement.noteFont.pointSize * 0.55)
    }
}
