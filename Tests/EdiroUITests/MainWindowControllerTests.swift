import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

private func makeState() -> AppState {
  let directory = URL(filePath: NSTemporaryDirectory())
    .appending(path: "ediro-window-tests/\(UUID().uuidString)")
  return AppState(
    documentStore: DocumentStore(fileURL: directory.appending(path: "draft.md")),
    defaults: UserDefaults(suiteName: "ediro.window.\(UUID().uuidString)")!)
}

@Test func ウィンドウには最小サイズが設定される() {
  let controller = MainWindowController(state: makeState())
  #expect(controller.window.contentMinSize.width > 0)
  #expect(controller.window.contentMinSize.height > 0)
}

@Test func 起動時にエディタがキー入力を受け取る() {
  let controller = MainWindowController(state: makeState())
  controller.show()
  #expect(controller.window.firstResponder as? NSTextView != nil)
}

@Test func 階層の奥にあるテキストビューを見つけられる() {
  let leaf = NSTextView(frame: .zero)
  let middle = NSView(frame: .zero)
  let root = NSView(frame: .zero)
  middle.addSubview(leaf)
  root.addSubview(NSView(frame: .zero))
  root.addSubview(middle)

  #expect(firstTextView(in: root) === leaf)
  #expect(firstTextView(in: NSView(frame: .zero)) == nil)
}
