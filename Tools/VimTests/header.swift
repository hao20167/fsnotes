import Cocoa
import Carbon.HIToolbox
enum UserDefaultsManagement { static var indentUsing = 1; static var noteFont = NSFont.systemFont(ofSize: 14) }
class EditTextView: NSTextView {
  var undoMgr = UndoManager()
  override var undoManager: UndoManager? { undoMgr }
  func updateVimIndicator() {}
  var flashed = [NSRange]()
  func vimFlash(range: NSRange) { flashed.append(range) }
  var searchInputs = [String?]()   // answers for the next "/" or "?" prompts
  func vimPromptSearch(forward: Bool, completion: @escaping (String?) -> Void) {
    completion(searchInputs.isEmpty ? nil : searchInputs.removeFirst())
  }
}
