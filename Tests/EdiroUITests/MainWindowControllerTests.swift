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
