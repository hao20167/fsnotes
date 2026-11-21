//
//  CustomLayoutManager.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 24.08.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Cocoa
#if canImport(SwiftMath)
import SwiftMath
#endif

fileprivate extension NSRange {
    /// Clamp range to fit inside given maxRange
    func clamped(to maxRange: NSRange) -> NSRange {
        if maxRange.length == 0 { return NSRange(location: maxRange.location, length: 0) }
        if self.location >= NSMaxRange(maxRange) { return NSRange(location: NSMaxRange(maxRange), length: 0) }
        let start = max(self.location, maxRange.location)
        let end = min(NSMaxRange(self), NSMaxRange(maxRange))
        if end <= start { return NSRange(location: start, length: 0) }
        return NSRange(location: start, length: end - start)
    }
}

class LayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    weak var processor: TextStorageProcessor?
    
    override init() {
        super.init()
        
        self.allowsNonContiguousLayout = true
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        self.allowsNonContiguousLayout = true
    }
    
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        if var modified = mathGlyphProperties(glyphs: glyphs, properties: properties, characterIndexes: characterIndexes, glyphRange: glyphRange) {
            layoutManager.setGlyphs(glyphs, properties: &modified, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            return glyphRange.length
        }

        return NotesTextProcessor.generateConcealedGlyphs(layoutManager, glyphs: glyphs, properties: properties,
                                                        characterIndexes: characterIndexes, font: font, glyphRange: glyphRange)
    }

    public var lineHeightMultiple: CGFloat = CGFloat(UserDefaultsManagement.lineHeightMultiple)

    private var defaultFont: NSFont {
        return self.firstTextView?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }

    private func font(for glyphRange: NSRange) -> NSFont {
        guard let textStorage = self.textStorage else {
            return defaultFont
        }
        
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let storageRange = NSRange(location: 0, length: textStorage.length)
        let safeCharRange = characterRange.clamped(to: storageRange)
        guard safeCharRange.length > 0 else {
            return defaultFont
        }
        
        var tallestFont: NSFont?
        var tallestHeight: CGFloat = 0
        textStorage.enumerateAttributes(in: safeCharRange) { attributes, _, _ in
            guard attributes[NotesTextProcessor.concealedSyntaxHidden] as? Bool != true,
                  let font = attributes[.font] as? NSFont else { return }
            let height = self.defaultLineHeight(for: font)
            if height > tallestHeight {
                tallestFont = font
                tallestHeight = height
            }
        }
        return tallestFont ?? defaultFont
    }
    
    private func hasAttachment(in glyphRange: NSRange) -> (hasAttachment: Bool, maxAttachmentHeight: CGFloat) {
        guard let textStorage = self.textStorage else {
            return (false, 0)
        }
        
        let characterRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let storageRange = NSRange(location: 0, length: textStorage.length)
        let safeCharRange = characterRange.clamped(to: storageRange)
        if safeCharRange.length == 0 {
            return (false, 0)
        }
        
        var maxHeight: CGFloat = 0
        var hasAttachment = false
        
        textStorage.enumerateAttribute(.attachment, in: safeCharRange, options: []) { value, _, _ in
            if let attachment = value as? NSTextAttachment {
                hasAttachment = true
                let attachmentBounds = attachment.bounds
                maxHeight = max(maxHeight, attachmentBounds.height)
            }
        }
        
        return (hasAttachment, maxHeight)
    }

    public func lineHeight(for font: NSFont) -> CGFloat {
        let fontLineHeight = self.defaultLineHeight(for: font)
        let lineHeight = fontLineHeight * lineHeightMultiple
        return lineHeight
    }

    private func isInCodeBlock(characterIndex: Int) -> Bool {
        guard let textStorage = self.textStorage else {
            return false
        }
        
        let ns = textStorage.string as NSString
        let storageFullRange = NSRange(location: 0, length: ns.length)

        if characterIndex < 0 || characterIndex >= NSMaxRange(storageFullRange) {
            return false
        }
        
        guard let codeBlocks = processor?.editor?.note?.codeBlockRangesCache else { return false }
        return codeBlocks.contains { NSLocationInRange(characterIndex, $0) }
    }
    
    // MARK: - Private mode

    /// Character range that stays visible in private mode: the paragraph(s) holding the selection/caret.
    public func privateVisibleCharacterRange() -> NSRange? {
        guard UserDefaultsManagement.privateMode,
              let textStorage = textStorage,
              let textView = firstTextView else { return nil }

        let string = textStorage.string as NSString
        let length = string.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        var union: NSRange?
        for value in textView.selectedRanges {
            var range = value.rangeValue
            range.location = min(range.location, length)
            range.length = min(range.length, length - range.location)

            var paragraph = string.paragraphRange(for: range)

            // Caret at the very end right after a newline: the (empty) last line is current
            if range.location == length && length > 0 && string.character(at: length - 1) == 0x0A {
                paragraph = NSRange(location: length, length: 0)
            }

            union = union.map { NSUnionRange($0, paragraph) } ?? paragraph
        }

        guard var visible = union else { return NSRange(location: 0, length: 0) }

        // Extra context lines above and below
        let context = UserDefaultsManagement.privateModeContextLines
        if context > 0 {
            var start = visible.location
            var end = NSMaxRange(visible)
            for _ in 0..<context where start > 0 {
                start = string.paragraphRange(for: NSRange(location: start - 1, length: 0)).location
            }
            for _ in 0..<context where end < length {
                end = NSMaxRange(string.paragraphRange(for: NSRange(location: end, length: 0)))
            }
            visible = NSRange(location: start, length: end - start)
        }

        return visible
    }

    private func privateGlyphRange(intersecting glyphsToShow: NSRange) -> NSRange? {
        guard let visible = privateVisibleCharacterRange() else { return glyphsToShow }
        guard visible.length > 0 else { return NSRange(location: glyphsToShow.location, length: 0) }

        let visibleGlyphs = glyphRange(forCharacterRange: visible, actualCharacterRange: nil)
        return NSIntersectionRange(glyphsToShow, visibleGlyphs)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let range = privateGlyphRange(intersecting: glyphsToShow) else { return }
        guard range.length > 0 else { return }

        super.drawGlyphs(forGlyphRange: range, at: origin)
        drawMath(forGlyphRange: range, at: origin)
    }

    // MARK: - Drawing
    
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        if UserDefaultsManagement.privateMode {
            // Selection highlight still has to work everywhere, but no code block boxes etc. outside the current line
            if let range = privateGlyphRange(intersecting: glyphsToShow), range.length > 0 {
                drawCodeBlockBackground(forGlyphRange: range, at: origin)
            }
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        drawCodeBlockBackground(forGlyphRange: glyphsToShow, at: origin)

        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
    
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        let storageLength = self.textStorage?.length ?? 0
        let storageFullRange = NSRange(location: 0, length: storageLength)
        let safeCharRange = charRange.clamped(to: storageFullRange)
        let isSelection = color == NSColor.selectedTextBackgroundColor ||
           color == NSColor.unemphasizedSelectedTextBackgroundColor

        if !isSelection, safeCharRange.length > 0, previewRange(at: safeCharRange.location) != nil {
            return
        }

        if !isSelection, let visible = privateVisibleCharacterRange(),
           NSIntersectionRange(visible, safeCharRange).length == 0 {
            return
        }

        if isSelection ||
           !isInCodeBlock(characterIndex: safeCharRange.location) {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
    }
    
    private func drawCodeBlockBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let textStorage = self.textStorage,
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        guard let allCodeBlocks = processor?.editor?.note?.codeBlockRangesCache else { return }
        guard let textContainer = self.textContainers.first else { return }
        
        let visibleCharRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let relevantCodeBlocks = allCodeBlocks.filter { codeBlock in
            NSIntersectionRange(codeBlock, visibleCharRange).length > 0
        }
        
        guard !relevantCodeBlocks.isEmpty else { return }
        
        context.saveGState()
        
        let backgroundColor = NotesTextProcessor.getHighlighter().options.style.backgroundColor.cgColor
        let borderColor = NSColor.lightGray.cgColor
        
        for codeBlockRange in relevantCodeBlocks {  // ← теперь только релевантные блоки!
            // The box extends beyond AppKit's selection background. Hide its
            // decoration while selected so the side padding cannot stick out.
            if firstTextView?.selectedRanges.contains(where: {
                NSIntersectionRange($0.rangeValue, codeBlockRange).length > 0
            }) == true {
                continue
            }

            let safeCharRange = NotesTextProcessor.codeBlockBackgroundRange(in: textStorage, range: codeBlockRange)
            if safeCharRange.length == 0 { continue }
            
            let glyphRange = self.glyphRange(forCharacterRange: safeCharRange, actualCharacterRange: nil)
            if glyphRange.length == 0 { continue }
            
            let boundingRect = self.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            if boundingRect.isEmpty { continue }
            
            // Padding left/right
            let horizontalPadding: CGFloat = 5.0
            let inset = max(0, textContainer.lineFragmentPadding - horizontalPadding)
            let paddedRect = NSRect(x: origin.x + inset, y: origin.y + boundingRect.minY,
                                    width: max(0, textContainer.size.width - 2 * inset), height: boundingRect.height)
            
            // Round borders
            let radius: CGFloat = 5.0
            let path = CGPath(roundedRect: paddedRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            
            context.setFillColor(backgroundColor)
            context.addPath(path)
            context.fillPath()
            
            // Border 1px
            context.addPath(path)
            context.setStrokeColor(borderColor)
            context.setLineWidth(1.0)
            context.strokePath()
        }
        
        context.restoreGState()
    }

    public func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange) -> Bool {

        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        if let textStorage = textStorage, characters.location < textStorage.length,
           textStorage.attribute(NotesTextProcessor.collapsedCodeFence, at: characters.location, effectiveRange: nil) as? Bool == true {
            // Keep collapsed fences positive but on whole-point boundaries.
            // A 0.1-point fragment shifts every following line off the pixel
            // grid, leaving selection edge pixels outside partial redraws.
            lineFragmentRect.pointee.size.height = 1
            lineFragmentUsedRect.pointee.size.height = 1
            baselineOffset.pointee = 1
            return true
        }

        // Continuation lines of a multi-line display formula collapse (the image is drawn on its first line)
        if characters.length > 0, let effective = previewRange(at: characters.location)?.range {
            if effective.location < characters.location,
               NSMaxRange(characters) <= NSMaxRange(effective) + 1 {
                lineFragmentRect.pointee.size.height = 1
                lineFragmentUsedRect.pointee.size.height = 1
                baselineOffset.pointee = 1
                return true
            }
        }

        // Get the font for the current range of glyphs
        let currentFont = font(for: glyphRange)
        let fontLineHeight = layoutManager.defaultLineHeight(for: currentFont)
        let standardLineHeight = fontLineHeight * lineHeightMultiple
        
        let attachmentInfo = hasAttachment(in: glyphRange)
        
        var finalLineHeight: CGFloat
        var baselineNudge: CGFloat
        
        if attachmentInfo.hasAttachment && attachmentInfo.maxAttachmentHeight > 0 {
            if attachmentInfo.maxAttachmentHeight > standardLineHeight {
                finalLineHeight = attachmentInfo.maxAttachmentHeight
                baselineNudge = 0
            } else {
                finalLineHeight = standardLineHeight
                let extraSpace = finalLineHeight - fontLineHeight
                baselineNudge = extraSpace * 0.5
            }
        } else {
            finalLineHeight = standardLineHeight
            let extraSpace = finalLineHeight - fontLineHeight
            baselineNudge = extraSpace * 0.5
        }

        var rect = lineFragmentRect.pointee
        let style = textStorage?.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle
        // Null glyphs from the next heading may belong to this line's glyph range.
        // Their fonts must not determine the line's height or baseline.
        rect.size.height = ceil(max(finalLineHeight, fontLineHeight + (style?.lineSpacing ?? 0)))

        // Formula previews make their line taller; text on the line stays vertically centered
        var mathNudge: CGFloat = 0
        let formulaHeight = mathHeight(in: characters)
        if formulaHeight > 0 {
            let needed = ceil(formulaHeight + 6)
            if needed > rect.size.height {
                mathNudge = (needed - rect.size.height) / 2
                rect.size.height = needed
            }
        }

        var usedRect = lineFragmentUsedRect.pointee
        usedRect.size.height = rect.size.height

        lineFragmentRect.pointee = rect
        lineFragmentUsedRect.pointee = usedRect
        baselineOffset.pointee = (attachmentInfo.hasAttachment
            ? baselineOffset.pointee + baselineNudge
            : layoutManager.defaultBaselineOffset(for: currentFont) + baselineNudge) + mathNudge

        return true
    }
    
    func refreshLayoutSoftly() {
        invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0),
                                actualCharacterRange: nil)
                
        textContainers.forEach { container in
            container.textView?.needsDisplay = true
        }
    }
    
    override func setExtraLineFragmentRect(
        _ fragmentRect: NSRect,
        usedRect: NSRect,
        textContainer container: NSTextContainer) {
        
        var fontToUse: NSFont

        if let textStorage = self.textStorage, textStorage.length > 0 {
            let lastIndex = textStorage.length - 1
            let attributes = textStorage.attributes(at: lastIndex, effectiveRange: nil)
            let nsString = textStorage.string as NSString
            let lastCharIsNewline = nsString.character(at: lastIndex) == 0x0A // '\n'

            if !lastCharIsNewline, let font = attributes[.font] as? NSFont {
                fontToUse = font
            } else {
                fontToUse = UserDefaultsManagement.noteFont
            }
        } else {
            fontToUse = UserDefaultsManagement.noteFont
        }
        
        let lineHeight = self.lineHeight(for: fontToUse)
        
        var fragmentRect = fragmentRect
        fragmentRect.size.height = ceil(lineHeight)
        var usedRect = usedRect
        usedRect.size.height = ceil(lineHeight)

        super.setExtraLineFragmentRect(fragmentRect,
            usedRect: usedRect,
            textContainer: container)
    }
}

// MARK: - Math live preview
//
// LaTeX ($$…$$, $…$, \(…\)) outside the line being edited is drawn as a formula.
// The text itself is never changed: the formula's first character becomes a
// control glyph as wide as the rendered image, the rest become null glyphs,
// and the image is drawn on top. Moving the caret onto the line reveals LaTeX.

final class MathRender: NSObject {
    let image: NSImage
    let isBlock: Bool
    let cacheKey: String
    /// Display formulas alone on their line are centered; tables are not
    let centersWhenAlone: Bool

    init(image: NSImage, isBlock: Bool, cacheKey: String, centersWhenAlone: Bool = true) {
        self.image = image
        self.isBlock = isBlock
        self.cacheKey = cacheKey
        self.centersWhenAlone = centersWhenAlone
    }

    /// Size to draw at, scaled down to fit the text container.
    func drawSize(maxWidth: CGFloat) -> CGSize {
        let size = image.size
        guard size.width > maxWidth, maxWidth > 0 else { return size }
        let scale = maxWidth / size.width
        return CGSize(width: maxWidth, height: size.height * scale)
    }
}

enum MathPreview {
    static let key = NSAttributedString.Key("fsMathPreview")

    static var isEnabled: Bool {
        #if canImport(SwiftMath)
        return UserDefaultsManagement.hideMarkdownSyntax
        #else
        return false
        #endif
    }

    private static let cache = NSCache<NSString, MathRender>()
    private static let failed = NSCache<NSString, NSNumber>()

    private static let blockRegex = try! NSRegularExpression(pattern: "\\$\\$([\\s\\S]+?)\\$\\$", options: [])
    private static let bracketRegex = try! NSRegularExpression(pattern: "\\\\\\(([^\\n]+?)\\\\\\)", options: [])
    // Pandoc-style inline: no space after the opening / before the closing $, closing $ not followed by a digit
    private static let inlineRegex = try! NSRegularExpression(pattern: "(?<![\\\\$])\\$(?![\\s$])((?:\\\\.|[^$\\n\\\\])+?)(?<![\\s\\\\])\\$(?![\\d$])", options: [])

    struct Match {
        let range: NSRange
        let latex: String
        let isBlock: Bool
    }

    /// Sorted, non-empty ranges with a running max end: overlap queries in O(log n).
    struct RangeSet {
        private var starts = [Int]()
        private var maxEnds = [Int]()

        init(_ ranges: [NSRange]) {
            var running = Int.min
            for r in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
                running = max(running, NSMaxRange(r))
                starts.append(r.location)
                maxEnds.append(running)
            }
        }

        func intersects(_ range: NSRange) -> Bool {
            guard range.length > 0 else { return false }
            // last range starting before the end of `range`
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] < NSMaxRange(range) { lo = mid + 1 } else { hi = mid }
            }
            return lo > 0 && maxEnds[lo - 1] > range.location
        }
    }

    /// Inline code spans (`code`, ``code``): their content is never math
    /// Matched per line, like the editor's code span highlighting, so a stray backtick
    /// cannot swallow the following lines.
    static func inlineCodeRanges(in string: NSString) -> [NSRange] {
        guard string.range(of: "`").location != NSNotFound else { return [] }
        guard let regex = NotesTextProcessor.codeSpanRegex.regularExpression else { return [] }
        let source = string as String
        var result = [NSRange]()
        var location = 0
        while location < string.length {
            let line = string.lineRange(for: NSRange(location: location, length: 0))
            if string.range(of: "`", options: [], range: line).location != NSNotFound {
                result += regex.matches(in: source, options: [], range: line).map { $0.range }
            }
            location = NSMaxRange(line)
        }
        return result
    }

    static func matches(in string: NSString, excluding excluded: [NSRange]) -> [Match] {
        var result = [Match]()
        let full = NSRange(location: 0, length: string.length)
        var taken = excluded

        for (regex, block) in [(blockRegex, true), (bracketRegex, false), (inlineRegex, false)] {
            // Matches of one regex never overlap each other: test against earlier passes only
            let blocked = RangeSet(taken)
            var found = [Match]()
            for m in regex.matches(in: string as String, options: [], range: full) where m.numberOfRanges > 1 {
                guard !blocked.intersects(m.range) else { continue }
                let latex = string.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !latex.isEmpty else { continue }
                found.append(Match(range: m.range, latex: latex, isBlock: block))
            }
            result += found
            taken += found.map { $0.range }
        }

        return result
    }

    // Last parse, reused while only the selection moves
    private static var parsedSource: String?
    private static var parsedCodeBlocks = [NSRange]()
    private static var parsedTables = [MarkdownTablePreview.Table]()
    private static var parsedMatches = [Match]()

    private static func parse(_ string: NSString, codeBlocks: [NSRange]) -> ([MarkdownTablePreview.Table], [Match]) {
        let source = string as String
        if let last = parsedSource, last == source, parsedCodeBlocks == codeBlocks {
            return (parsedTables, parsedMatches)
        }

        let tables = MarkdownTablePreview.tables(in: string, excluding: codeBlocks)
        let excluded = codeBlocks + tables.map { $0.range } + inlineCodeRanges(in: string)
        let found = matches(in: string, excluding: excluded)

        parsedSource = source
        parsedCodeBlocks = codeBlocks
        parsedTables = tables
        parsedMatches = found
        return (tables, found)
    }

    static func render(latex: String, isBlock: Bool, fontSize: CGFloat, appearance: NSAppearance) -> MathRender? {
        #if canImport(SwiftMath)
        let key = "\(isBlock ? "D" : "T")|\(fontSize)|\(appearance.name.rawValue)|\(latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if failed.object(forKey: key) != nil { return nil }

        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let mathImage = MTMathImage(latex: latex, fontSize: fontSize, textColor: NSColor.textColor, labelMode: isBlock ? .display : .text, textAlignment: .left)
            mathImage.contentInsets = MTEdgeInsets(top: 2, left: 1, bottom: 2, right: 1)
            let (error, result) = mathImage.asImage()
            if error == nil, let result = result, result.size.width > 0, result.size.height > 0 {
                image = result
            }
        }

        guard let image = image else {
            failed.setObject(1, forKey: key)
            return nil
        }

        let render = MathRender(image: image, isBlock: isBlock, cacheKey: key as String)
        cache.setObject(render, forKey: key)
        return render
        #else
        return nil
        #endif
    }

    /// Applies/removes the render attribute: every formula except the ones on the active line.
    /// Returns true when something changed.
    @discardableResult
    static func refresh(in textStorage: NSTextStorage, selection: NSRange?, codeBlocks: [NSRange],
                        fontSize: CGFloat, appearance: NSAppearance) -> Bool {
        let string = textStorage.string as NSString
        let full = NSRange(location: 0, length: string.length)

        var desired = [(NSRange, MathRender)]()

        if isEnabled, string.length > 0 {
            let active = selection.map { sel -> NSRange in
                let safe = NSRange(location: min(sel.location, string.length), length: min(sel.length, string.length - min(sel.location, string.length)))
                return string.paragraphRange(for: safe)
            }

            var previews = [(range: NSRange, make: () -> MathRender?)]()

            let (tables, found) = parse(string, codeBlocks: codeBlocks)
            for table in tables {
                previews.append((table.range, { MarkdownTablePreview.render(table: table, appearance: appearance) }))
            }

            for match in found {
                previews.append((match.range, { render(latex: match.latex, isBlock: match.isBlock, fontSize: fontSize, appearance: appearance) }))
            }

            previews.sort { $0.range.location < $1.range.location }

            for preview in previews {
                if let active = active {
                    let paragraphs = string.paragraphRange(for: preview.range)
                    if NSIntersectionRange(active, paragraphs).length > 0 || active.location == NSMaxRange(paragraphs) && active.length == 0 && active.location == string.length {
                        continue
                    }
                }

                if let render = preview.make() {
                    desired.append((preview.range, render))
                }
            }
        }

        // Diff against what is applied now
        var current = [(NSRange, MathRender)]()
        textStorage.enumerateAttribute(key, in: full, options: []) { value, range, _ in
            if let render = value as? MathRender { current.append((range, render)) }
        }

        let same = current.count == desired.count && zip(current, desired).allSatisfy {
            $0.0 == $1.0 && $0.1.cacheKey == $1.1.cacheKey
        }
        guard !same else { return false }

        textStorage.beginEditing()
        for (range, _) in current {
            textStorage.removeAttribute(key, range: range)
        }
        for (range, render) in desired {
            textStorage.addAttribute(key, value: render, range: range)
        }
        textStorage.endEditing()

        // Attribute edits made while the storage is being processed (e.g. right after a note
        // is loaded) do not always regenerate glyphs: force it for every touched range.
        let touched = (current.map { $0.0 } + desired.map { $0.0 })
        let invalidate = {
            for layoutManager in textStorage.layoutManagers {
                for range in touched where NSMaxRange(range) <= textStorage.length {
                    layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
                    layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                }
                layoutManager.textContainers.forEach { $0.textView?.needsDisplay = true }
            }
        }
        if textStorage.editedMask.isEmpty {
            invalidate()
        } else {
            DispatchQueue.main.async(execute: invalidate)
        }

        return true
    }
}

extension LayoutManager {
    /// Whole preview (formula/table) covering the character, using the longest effective range:
    /// plain `effectiveRange` stops wherever any other attribute (font, color…) changes.
    func previewRange(at index: Int) -> (render: MathRender, range: NSRange)? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        let window = NSRange(location: max(0, index - 20000), length: min(storage.length, index + 20000) - max(0, index - 20000))
        var longest = NSRange()
        guard let render = storage.attribute(MathPreview.key, at: index, longestEffectiveRange: &longest, in: window) as? MathRender else { return nil }
        return (render, longest)
    }

    private var mathMaxWidth: CGFloat {
        guard let container = textContainers.first else { return 0 }
        return max(0, container.size.width - container.lineFragmentPadding * 2)
    }

    /// Glyph properties for concealed syntax + math previews. Returns nil when no math is involved.
    func mathGlyphProperties(glyphs: UnsafePointer<CGGlyph>, properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                             characterIndexes: UnsafePointer<Int>, glyphRange: NSRange) -> [NSLayoutManager.GlyphProperty]? {
        guard let storage = textStorage, glyphRange.length > 0 else { return nil }

        let first = characterIndexes[0]
        let last = characterIndexes[glyphRange.length - 1]
        guard first < storage.length else { return nil }

        var hasMath = false
        storage.enumerateAttribute(MathPreview.key, in: NSRange(location: first, length: min(last, storage.length - 1) - first + 1), options: []) { value, _, stop in
            if value != nil { hasMath = true; stop.pointee = true }
        }
        guard hasMath else { return nil }

        let text = storage.string as NSString
        var modified = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))

        for i in modified.indices {
            let index = characterIndexes[i]
            guard index < storage.length else { continue }

            if let preview = previewRange(at: index) {
                if index == preview.range.location {
                    modified[i].remove(.null)
                    modified[i].insert(.controlCharacter)
                } else {
                    modified[i].insert(.null)
                }
                continue
            }

            // Same rule as NotesTextProcessor.generateConcealedGlyphs
            if let hidden = storage.attribute(NotesTextProcessor.concealedSyntaxHidden, at: index, effectiveRange: nil) as? Bool,
               text.character(at: index) != 0x0A, text.character(at: index) != 0x0D {
                if hidden {
                    modified[i].insert(.null)
                } else {
                    modified[i].remove(.null)
                }
            }
        }

        return modified
    }

    func mathRender(at characterIndex: Int) -> MathRender? {
        guard let preview = previewRange(at: characterIndex), preview.range.location == characterIndex else { return nil }
        return preview.render
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if mathRender(at: charIndex) != nil {
            return .whitespace
        }
        return action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let render = mathRender(at: charIndex) else {
            return NSRect(origin: glyphPosition, size: .zero)
        }
        let size = render.drawSize(maxWidth: mathMaxWidth)
        return NSRect(x: glyphPosition.x, y: 0, width: size.width, height: size.height)
    }

    /// Tallest formula in the given character range (for line height).
    func mathHeight(in characters: NSRange) -> CGFloat {
        guard let storage = textStorage, characters.length > 0,
              characters.location < storage.length else { return 0 }
        let range = NSRange(location: characters.location, length: min(characters.length, storage.length - characters.location))
        var height: CGFloat = 0
        let maxWidth = mathMaxWidth
        storage.enumerateAttribute(MathPreview.key, in: range, options: []) { value, _, _ in
            if let render = value as? MathRender {
                height = max(height, render.drawSize(maxWidth: maxWidth).height)
            }
        }
        return height
    }

    func drawMath(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage, let container = textContainers.first else { return }

        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard chars.length > 0, chars.location < storage.length else { return }
        let safe = NSRange(location: chars.location, length: min(chars.length, storage.length - chars.location))
        let text = storage.string as NSString
        let maxWidth = mathMaxWidth

        var drawn = Set<Int>()
        storage.enumerateAttribute(MathPreview.key, in: safe, options: []) { value, range, _ in
            guard let render = value as? MathRender, !drawn.contains(range.location) else { return }

            // Draw only from the formula's first character
            guard let effective = self.previewRange(at: range.location)?.range,
                  NSLocationInRange(effective.location, safe) else { return }
            drawn.insert(effective.location)

            let glyphIndex = self.glyphIndexForCharacter(at: effective.location)
            let lineRect = self.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let glyphLocation = self.location(forGlyphAt: glyphIndex)
            let size = render.drawSize(maxWidth: maxWidth)

            var x = origin.x + lineRect.minX + glyphLocation.x

            // A display formula alone on its line is centered
            if render.isBlock && render.centersWhenAlone {
                let paragraph = text.paragraphRange(for: effective)
                let content = text.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
                if content == text.substring(with: effective).trimmingCharacters(in: .whitespacesAndNewlines) {
                    x = origin.x + container.lineFragmentPadding + max(0, (maxWidth - size.width) / 2)
                }
            }

            let y = origin.y + lineRect.minY + max(0, (lineRect.height - size.height) / 2)
            render.image.draw(in: NSRect(x: x, y: y, width: size.width, height: size.height),
                              from: .zero, operation: .sourceOver, fraction: 1,
                              respectFlipped: true, hints: nil)
        }
    }
}

// MARK: - Markdown table live preview

enum MarkdownTablePreview {
    enum Alignment { case left, center, right }

    struct Table {
        let range: NSRange          // header line start … last row end (without trailing newline)
        let header: [String]
        let alignments: [Alignment]
        let rows: [[String]]
        let source: String
    }

    private static let separatorRegex = try! NSRegularExpression(
        pattern: "^\\s*\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?\\s*$", options: [])

    private static let cache = NSCache<NSString, MathRender>()

    static func splitRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }

        var cells = [String]()
        var current = ""
        var escaped = false
        for ch in trimmed {
            if escaped {
                current.append(ch == "|" ? "|" : "\\")
                if ch != "|" { current.append(ch) }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func tables(in string: NSString, excluding excluded: [NSRange]) -> [Table] {
        var lines = [(range: NSRange, text: String)]()
        var location = 0
        while location < string.length {
            var end = 0, contentsEnd = 0
            string.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let range = NSRange(location: location, length: contentsEnd - location)
            lines.append((range, string.substring(with: range)))
            location = end
        }

        var result = [Table]()
        var i = 0
        while i + 1 < lines.count {
            let header = lines[i]
            let separator = lines[i + 1]

            guard header.text.contains("|"),
                  separator.text.contains("|") || separator.text.contains("-"),
                  separatorRegex.firstMatch(in: separator.text, options: [], range: NSRange(location: 0, length: (separator.text as NSString).length)) != nil,
                  !excluded.contains(where: { NSIntersectionRange($0, header.range).length > 0 || NSLocationInRange(header.range.location, $0) })
            else {
                i += 1
                continue
            }

            let headerCells = splitRow(header.text)
            let alignments: [Alignment] = splitRow(separator.text).map { cell in
                let c = cell.trimmingCharacters(in: .whitespaces)
                if c.hasPrefix(":") && c.hasSuffix(":") { return .center }
                if c.hasSuffix(":") { return .right }
                return .left
            }

            guard headerCells.count > 0, alignments.count == headerCells.count else {
                i += 1
                continue
            }

            var rows = [[String]]()
            var last = i + 1
            var j = i + 2
            while j < lines.count {
                let text = lines[j].text
                if text.trimmingCharacters(in: .whitespaces).isEmpty || !text.contains("|") { break }
                if excluded.contains(where: { NSIntersectionRange($0, lines[j].range).length > 0 }) { break }
                rows.append(splitRow(text))
                last = j
                j += 1
            }

            let start = header.range.location
            let range = NSRange(location: start, length: NSMaxRange(lines[last].range) - start)
            result.append(Table(range: range, header: headerCells, alignments: alignments, rows: rows,
                                source: string.substring(with: range)))
            i = last + 1
        }

        return result
    }

    /// Strip the most common inline markdown so cells read cleanly.
    static func plain(_ cell: String) -> String {
        var s = cell
        s = s.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        for marker in ["**", "__", "~~", "`"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }
        s = s.replacingOccurrences(of: "(?<![\\w*])\\*(?!\\s)([^*]+?)\\*", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: .regularExpression)
        return s
    }

    static func render(table: Table, appearance: NSAppearance) -> MathRender? {
        let font = UserDefaultsManagement.noteFont
        let key = "TABLE|\(font.fontName)|\(font.pointSize)|\(appearance.name.rawValue)|\(table.source)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let columns = table.header.count
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let padX: CGFloat = 8, padY: CGFloat = 4

        func cells(_ row: [String]) -> [String] {
            (0..<columns).map { $0 < row.count ? plain(row[$0]) : "" }
        }

        let header = cells(table.header)
        let body = table.rows.map(cells)

        func attributed(_ text: String, bold: Bool, alignment: Alignment) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment == .center ? .center : (alignment == .right ? .right : .left)
            style.lineBreakMode = .byClipping
            return NSAttributedString(string: text, attributes: [
                .font: bold ? boldFont : font,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: style
            ])
        }

        // Column widths / row heights
        var widths = [CGFloat](repeating: 20, count: columns)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        for (r, row) in ([header] + body).enumerated() {
            for (c, text) in row.enumerated() {
                let size = attributed(text, bold: r == 0, alignment: .left).size()
                widths[c] = max(widths[c], ceil(size.width))
            }
        }
        let rowHeight = lineHeight + padY * 2
        let totalWidth = widths.reduce(0) { $0 + $1 + padX * 2 } + 1
        let totalHeight = rowHeight * CGFloat(body.count + 1) + 1

        let alignments = table.alignments
        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: true) { _ in
            let grid = NSColor.separatorColor
            let headerFill = NSColor.textColor.withAlphaComponent(0.06)

            headerFill.setFill()
            NSRect(x: 0.5, y: 0.5, width: totalWidth - 1, height: rowHeight).fill()

            for (r, row) in ([header] + body).enumerated() {
                var x: CGFloat = 0.5
                let y = 0.5 + CGFloat(r) * rowHeight
                for (c, text) in row.enumerated() {
                    let cellRect = NSRect(x: x + padX, y: y + padY, width: widths[c], height: lineHeight)
                    attributed(text, bold: r == 0, alignment: alignments[c]).draw(with: cellRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                    x += widths[c] + padX * 2
                }
            }

            grid.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            for r in 0...(body.count + 1) {
                let y = 0.5 + CGFloat(r) * rowHeight
                path.move(to: NSPoint(x: 0.5, y: y))
                path.line(to: NSPoint(x: totalWidth - 0.5, y: y))
            }
            var x: CGFloat = 0.5
            path.move(to: NSPoint(x: x, y: 0.5))
            path.line(to: NSPoint(x: x, y: totalHeight - 0.5))
            for w in widths {
                x += w + padX * 2
                path.move(to: NSPoint(x: x, y: 0.5))
                path.line(to: NSPoint(x: x, y: totalHeight - 0.5))
            }
            path.stroke()
            return true
        }

        let render = MathRender(image: image, isBlock: true, cacheKey: key as String, centersWhenAlone: false)
        cache.setObject(render, forKey: key)
        return render
    }
}
