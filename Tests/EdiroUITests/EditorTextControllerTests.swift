import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

private func makeState(text: String = "") -> AppState {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "ediro-controller-tests/\(UUID().uuidString)")
  let state = AppState(
    documentStore: DocumentStore(fileURL: directory.appending(path: "draft.md")),
    defaults: UserDefaults(suiteName: "ediro.controller.\(UUID().uuidString)")!)
  state.text = text
  return state
}

/// 状態の購読はメインアクターの次の実行まで反映されないので、条件が立つまで待つ。
private func waitUntil(
  _ condition: () -> Bool, timeout: Duration = .milliseconds(500)
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}

private func bodyFontSize(_ controller: EditorTextController) -> Double? {
  let font = controller.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
  return font.map { Double($0.pointSize) }
}

@Test func フォントサイズの変更がエディタに伝わる() async throws {
  let state = makeState(text: "本文です")
  let controller = EditorTextController(state: state)
  #expect(bodyFontSize(controller) == Preferences.default.fontSize)

  state.preferences.fontSize = 30
  #expect(await waitUntil { bodyFontSize(controller) == 30 })
}

@Test func テーマの変更がエディタの配色に伝わる() async throws {
  let state = makeState(text: "本文です")
  state.preferences.themeID = "dark"
  let controller = EditorTextController(state: state)
  #expect(controller.textView.backgroundColor.brightnessComponent < 0.5)

  state.preferences.themeID = "light"
  #expect(await waitUntil { controller.textView.backgroundColor.brightnessComponent > 0.5 })
}

@Test func タブ幅の変更がエディタに伝わる() async throws {
  let state = makeState(text: "本文です")
  let controller = EditorTextController(state: state)
  let before = controller.textView.defaultParagraphStyle?.defaultTabInterval

  state.preferences.tabSize = 8
  #expect(
    await waitUntil {
      controller.textView.defaultParagraphStyle?.defaultTabInterval != before
    })
}

@Test func 外側から差し替えた本文がエディタに伝わる() async throws {
  let state = makeState(text: "はじめの本文")
  let controller = EditorTextController(state: state)

  state.text = "差し替えた本文"
  #expect(await waitUntil { controller.textView.string == "差し替えた本文" })
}

@Test func エディタへの入力が状態に伝わる() {
  let state = makeState(text: "")
  let controller = EditorTextController(state: state)

  controller.textView.string = "打ち込んだ"
  controller.textDidChange(Notification(name: NSText.didChangeNotification))
  #expect(state.text == "打ち込んだ")
  #expect(state.metrics.characters == 5)
}
