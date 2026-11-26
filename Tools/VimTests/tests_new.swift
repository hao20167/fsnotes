// ---- 2026-11-26: yank flash, system clipboard, search ----
do { load("a\nbc", 2); keys("yy"); expect("yy flashes the yanked line", tv.flashed == [NSRange(location: 2, length: 2)], "\(tv.flashed)") }
do { load("foo bar", 0); keys("yw"); expect("yw flashes word", tv.flashed == [NSRange(location: 0, length: 4)], "\(tv.flashed)") }
do { load("abc", 0); keys("dd"); expect("dd does not flash", tv.flashed.isEmpty) }
do {
  load("a\nb", 0); keys("yy")
  testPasteboard.clearContents(); testPasteboard.setString("EXT", forType: .string)
  keys("p")
  expect("p uses text copied elsewhere (charwise)", tv.string == "aEXT\nb", tv.string.debugDescription)
}
do {
  load("a\nb", 0)
  testPasteboard.clearContents(); testPasteboard.setString("L1\nL2\n", forType: .string)
  keys("p")
  expect("p external text ending in newline is linewise", tv.string == "a\nL1\nL2\nb", tv.string.debugDescription)
}
do {
  load("a\nb", 0)
  testPasteboard.clearContents(); testPasteboard.setString("X\r\n", forType: .string)
  keys("P")
  expect("P external CRLF normalised, linewise above", tv.string == "X\na\nb", tv.string.debugDescription)
}
do {
  load("abc\nd", 0); keys("yy")
  testPasteboard.clearContents(); testPasteboard.setString("Z", forType: .string)
  keys("jyyp")
  expect("own yank after external copy wins", tv.string == "abc\nd\nd", tv.string.debugDescription)
}
do {
  load("abc", 0); keys("yl"); keys("p")
  expect("own yank: p unchanged", tv.string == "aabc", tv.string.debugDescription)
}
do {
  load("xyz", 0)
  testPasteboard.clearContents(); testPasteboard.setString("Q", forType: .string)
  keys("vp")
  expect("visual p uses external text", tv.string == "Qyz", tv.string.debugDescription)
}
do {
  load("foo bar foo baz", 0); tv.searchInputs = ["foo"]; keys("/")
  expect("/foo jumps to next match", tv.selectedRange().location == 8, "\(tv.selectedRange())")
  keys("n"); expect("n wraps to first", tv.selectedRange().location == 0, "\(tv.selectedRange())")
  keys("N"); expect("N goes back (wrap)", tv.selectedRange().location == 8, "\(tv.selectedRange())")
}
do {
  load("a\nfoo\nb\nfoo", 7); tv.searchInputs = ["foo"]; keys("?")
  expect("?foo searches backwards", tv.selectedRange().location == 2, "\(tv.selectedRange())")
  keys("n"); expect("n after ? keeps backwards (wrap)", tv.selectedRange().location == 8, "\(tv.selectedRange())")
}
do { load("Foo foo", 4); tv.searchInputs = ["foo"]; keys("/"); expect("smartcase: lowercase ignores case", tv.selectedRange().location == 0, "\(tv.selectedRange())") }
do { load("foo Foo foo", 0); tv.searchInputs = ["Foo"]; keys("/"); expect("smartcase: capital is exact", tv.selectedRange().location == 4, "\(tv.selectedRange())") }
do { load("a(b) a(c)", 0); tv.searchInputs = ["a("]; keys("/"); expect("invalid regex falls back to literal", tv.selectedRange().location == 5, "\(tv.selectedRange())") }
do { load("x1 y22 z333", 0); tv.searchInputs = ["\\d{3}"]; keys("/"); expect("regex search", tv.selectedRange().location == 8, "\(tv.selectedRange())") }
do { load("abc", 1); tv.searchInputs = ["zzz"]; keys("/x"); expect("not found: stays, next keys still work", tv.string == "ac" && engine.mode == .normal, tv.string) }
do { load("abc", 1); tv.searchInputs = [nil]; keys("/x"); expect("cancelled search: nothing happens", tv.string == "ac", tv.string) }
do { load("foo bar foo", 0); tv.searchInputs = ["foo", ""]; keys("/"); keys("gg/"); expect("empty pattern repeats last search", tv.selectedRange().location == 8, "\(tv.selectedRange())") }
check("d/ deletes up to match", "abc def ghi", 0, "d/", "abc def ghi")   // no input queued: cancelled
do { load("abc def ghi", 0); tv.searchInputs = ["gh"]; keys("d/"); expect("d/gh deletes up to match", tv.string == "ghi", tv.string); keys("u"); expect("d/ one undo", tv.string == "abc def ghi", tv.string) }
do { load("foo bar foo", 1); keys("*"); expect("* next same word", tv.selectedRange().location == 8, "\(tv.selectedRange())") }
do { load("foo foobar foo", 0); keys("*"); expect("* whole word only", tv.selectedRange().location == 11, "\(tv.selectedRange())") }
do { load("foo bar foo", 9); keys("#"); expect("# previous same word", tv.selectedRange().location == 0, "\(tv.selectedRange())") }
do { load("foo bar foo", 0); tv.searchInputs = ["bar"]; keys("/"); expect("search flashes match", tv.flashed.last == NSRange(location: 4, length: 3), "\(tv.flashed)") }
do { load("aXbXc", 0); tv.searchInputs = ["X"]; keys("v/"); keys("d"); expect("visual extends with search", tv.string == "bXc", tv.string) }
do { load("a b a b", 0); tv.searchInputs = ["b"]; keys("/"); keys("2n"); expect("count n", tv.selectedRange().location == 2, "\(tv.selectedRange())") }
do { load("x a x", 0); tv.searchInputs = ["a"]; keys("d/"); keys("."); expect(". after d/ is not a search replay", tv.string == "a x", tv.string) }
// ---- Cmd+Z / Cmd+Shift+Z in insert mode (was: "too many nested undo groups") ----
func pasteLikeFSNotes(_ s: String) { tv.breakUndoCoalescing(); tv.insertText(NSAttributedString(string: s), replacementRange: tv.selectedRange()); tv.breakUndoCoalescing() }
func menuKey(_ ch: String, shift: Bool = false) -> Bool {
  var flags: NSEvent.ModifierFlags = .command; if shift { flags.insert(.shift) }
  // Real path: the shortcut is a menu key equivalent, keyDown never sees it; EditTextView's
  // performKeyEquivalent asks vim to close its group, then the menu runs undo:/redo:
  _ = flags; _ = ch
  engine.prepareForMenuUndo()
  return tv.undoMgr.groupingLevel <= (tv.undoMgr.groupsByEvent ? 1 : 0)
}
do { load("abc", 0); keys("i"); pasteLikeFSNotes("XY"); let ok = menuKey("z"); if ok { tv.undoMgr.undo() }
     expect("Cmd+Z after Cmd+V in insert undoes the paste", ok && tv.string == "abc", "level \(tv.undoMgr.groupingLevel) \(tv.string)") }
do { load("abc", 0); keys("iK"); pasteLikeFSNotes("XY"); let ok = menuKey("z"); if ok { tv.undoMgr.undo() }
     expect("Cmd+Z in insert undoes typing+paste so far", ok && tv.string == "abc", tv.string)
     keys("Q<esc>"); expect("typing after Cmd+Z works, group closed on Esc", tv.string == "Qabc" && tv.undoMgr.groupingLevel == 0, "\(tv.string) level \(tv.undoMgr.groupingLevel)")
     keys("u"); expect("u undoes the text typed after Cmd+Z", tv.string == "abc", tv.string) }
do { load("abc", 0); keys("i"); pasteLikeFSNotes("XY"); _ = menuKey("z"); tv.undoMgr.undo(); let ok = menuKey("z", shift: true); if ok { tv.undoMgr.redo() }
     expect("Cmd+Shift+Z redoes the paste", ok && tv.string == "XYabc", tv.string) }
do { load("abc", 0); keys("A"); pasteLikeFSNotes("XY"); keys("<esc>"); tv.undoMgr.undo(); expect("paste then Esc then undo", tv.string == "abc", tv.string) }
