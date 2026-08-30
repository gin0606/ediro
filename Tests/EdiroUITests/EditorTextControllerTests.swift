import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

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

@Test func 打鍵の直後にはハイライトを掛け直さない() {
  let state = makeState(text: "普通の本文")
  let controller = EditorTextController(state: state, highlightDelay: .seconds(10))
  let storage = controller.textView.textStorage!

  controller.textView.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
  let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
  #expect(
    font.map { Double($0.pointSize) } == Preferences.default.fontSize,
    "打鍵と同時に全文を敷き直している")
}

@Test func 打鍵が止まるとハイライトが掛かる() async {
  let state = makeState(text: "普通の本文")
  let controller = EditorTextController(state: state, highlightDelay: .milliseconds(10))
  let storage = controller.textView.textStorage!

  controller.textView.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
  #expect(
    await waitUntil(
      {
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        return font.map { Double($0.pointSize) } ?? 0 > Preferences.default.fontSize
      }, timeout: .seconds(2)), "待っても見出しが大きくならない")
}

@Test func 変換中はハイライトを掛け直さない() {
  let state = makeState(text: "本文")
  let controller = EditorTextController(state: state, highlightDelay: .zero)
  let textView = controller.textView
  textView.setSelectedRange(NSRange(location: 0, length: 0))
  textView.setMarkedText(
    "へんかん", selectedRange: NSRange(location: 4, length: 0),
    replacementRange: NSRange(location: 0, length: 0))
  try? #require(textView.hasMarkedText())

  // 変換中に敷き直すと、AppKit が marked text に付けた属性を消してしまう
  let before = textView.textStorage!.attributes(at: 0, effectiveRange: nil)
  controller.highlight()
  let after = textView.textStorage!.attributes(at: 0, effectiveRange: nil)
  #expect(before.keys.map(\.rawValue).sorted() == after.keys.map(\.rawValue).sorted())
}

@Test func コピーは書式なしテキストだけをクリップボードに載せる() {
  let state = makeState(text: "**太字**と# 見出し")
  let controller = EditorTextController(state: state)
  controller.textView.selectAll(nil)

  let pasteboard = NSPasteboard(name: .init("ediro.test.\(UUID().uuidString)"))
  pasteboard.clearContents()
  controller.textView.writeSelection(
    to: pasteboard, types: controller.textView.writablePasteboardTypes)

  let written = pasteboard.types ?? []
  #expect(!written.contains(.rtf), "書式付きデータが載っている: \(written)")
  #expect(pasteboard.string(forType: .string) == "**太字**と# 見出し")
}

private func insertNewline(_ controller: EditorTextController) {
  _ = controller.textView(
    controller.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
}

@Test func 改行すると前の行のインデントを引き継ぐ() {
  let state = makeState()
  let controller = EditorTextController(state: state)
  controller.textView.string = "    ネストした行"
  controller.textView.setSelectedRange(NSRange(location: 12, length: 0))

  insertNewline(controller)
  #expect(controller.textView.string == "    ネストした行\n    ")
}

@Test func インデントのない行では余計な空白を足さない() {
  let state = makeState()
  let controller = EditorTextController(state: state)
  controller.textView.string = "ふつうの行"
  controller.textView.setSelectedRange(NSRange(location: 5, length: 0))

  // 既定の改行に委ねるので、この呼び出しでは文字列が変わらない
  insertNewline(controller)
  #expect(controller.textView.string == "ふつうの行")
}

@Test func 行頭で改行してもインデントは深くならない() {
  let state = makeState()
  let controller = EditorTextController(state: state)
  controller.textView.string = "    インデント行"
  controller.textView.setSelectedRange(NSRange(location: 0, length: 0))

  // 既定の改行に委ねる。自前で足すと、空行に空白が残ったうえ深さが倍になる
  insertNewline(controller)
  #expect(controller.textView.string == "    インデント行")
}

@Test func インデントの内側で改行しても深さを保つ() {
  let state = makeState()
  let controller = EditorTextController(state: state)
  controller.textView.string = "    インデント行"
  controller.textView.setSelectedRange(NSRange(location: 2, length: 0))

  insertNewline(controller)
  #expect(controller.textView.string == "  \n    インデント行")
}

@Test func 行の途中で改行しても深さを保つ() {
  let state = makeState()
  let controller = EditorTextController(state: state)
  controller.textView.string = "  あいうえお"
  controller.textView.setSelectedRange(NSRange(location: 4, length: 0))

  insertNewline(controller)
  #expect(controller.textView.string == "  あい\n  うえお")
}

@Test func タブ幅の設定が本文の描画に効く() {
  func width(tabSize: Int) -> Double {
    let state = makeState(text: "a\tb")
    state.preferences.tabSize = tabSize
    let controller = EditorTextController(state: state)
    guard let storage = controller.textView.textStorage else { return 0 }
    return Double(storage.size().width)
  }
  #expect(width(tabSize: 8) > width(tabSize: 2))
}
