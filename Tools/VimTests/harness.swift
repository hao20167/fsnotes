let tv = EditTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
tv.allowsUndo = true
tv.undoMgr.groupsByEvent = false
let engine = VimEngine(view: tv)
// Private pasteboard: never touch the user's clipboard
let testPasteboard = NSPasteboard(name: NSPasteboard.Name("fsnotes-vimtest-\(getpid())"))
engine.pasteboard = testPasteboard
func load(_ s: String, _ cursor: Int = 0) { tv.string = s; engine.mode = .normal; engine.reset(); tv.setSelectedRange(NSRange(location: cursor, length: 0)); tv.undoMgr.removeAllActions(); tv.flashed = [] }
func keys(_ s: String) {
  var i = s.startIndex
  while i < s.endIndex {
    var ch = String(s[i]); var code: UInt16 = 0; var flags: NSEvent.ModifierFlags = []
    if ch == "<" , let close = s[i...].firstIndex(of: ">"), s.distance(from: i, to: close) > 1 {
      let name = String(s[s.index(after: i)..<close])
      switch name { case "esc": ch = "\u{1B}"; code = UInt16(kVK_Escape)
                    case "cr": ch = "\r"; code = UInt16(kVK_Return)
                    case "C-r": ch = "r"; flags = .control
                    default: ch = name }
      i = s.index(after: close)
    } else { i = s.index(after: i) }
    if engine.mode == .insert && code != UInt16(kVK_Escape) {
      // Like the app: every key reaches the engine first (it lets typing through)
      let typed = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
      if engine.handle(event: typed) { continue }
      if tv.undoMgr.groupingLevel == 0 { print("WARN typing outside group") ; tv.undoMgr.beginUndoGrouping(); tv.insertText(ch, replacementRange: tv.selectedRange()); tv.undoMgr.endUndoGrouping() } else { tv.insertText(ch, replacementRange: tv.selectedRange()) }; continue }
    let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
    _ = engine.handle(event: ev)
    if tv.undoMgr.groupingLevel > 0 && engine.mode != .insert { print("WARN open undo group after key", ch) }
  }
}
var fails = 0
func check(_ name: String, _ text: String, _ cur: Int, _ k: String, _ expect: String, _ expCursor: Int? = nil) {
  load(text, cur); keys(k)
  let got = tv.string; let c = tv.selectedRange().location
  let ok = got == expect && (expCursor == nil || expCursor == c)
  if !ok { fails += 1 }
  print(ok ? "OK  " : "FAIL", name, ok ? "" : "got=\(got.debugDescription) cur=\(c) expected=\(expect.debugDescription) cur=\(String(describing: expCursor))")
}
func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { fails += 1 }
  print(ok ? "OK  " : "FAIL", name, ok ? "" : detail())
}
