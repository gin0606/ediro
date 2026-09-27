import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

extension AppKitTests {
  struct EditorTextControllerTests {
    @Test func 長文の下部を編集しても後続行の表示と選択位置を保つ() async throws {
      let prefix = String(repeating: "# Heading\n本文と**太字**です。\n", count: 500)
      let state = makeState(text: prefix + "編集する本文\n後続の本文\n最後の行")
      let controller = EditorTextController(state: state)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = controller.scrollView
      defer { window.orderOut(nil) }
      let textView = controller.textView
      window.makeFirstResponder(textView)
      window.orderFront(nil)
      window.displayIfNeeded()
      let location = (prefix as NSString).length
      textView.setSelectedRange(NSRange(location: location, length: 0))
      textView.scrollRangeToVisible(textView.selectedRange())
      func followingLineIsVisible() -> Bool {
        window.displayIfNeeded()
        let following = (textView.string as NSString).range(of: "後続の本文")
        let screenRect = textView.firstRect(forCharacterRange: following, actualRange: nil)
        let rect = textView.convert(window.convertFromScreen(screenRect), from: nil)
        return rect.height > 0 && rect.intersects(textView.visibleRect)
      }
      #expect(await waitUntil({ followingLineIsVisible() }, timeout: .seconds(2)))
      try #require(controller.scrollView.contentView.bounds.minY > 0)

      for input in ["追記", "\n", "# "] {
        textView.insertText(input, replacementRange: textView.selectedRange())
        let selected = textView.selectedRange()
        let scrollOrigin = controller.scrollView.contentView.bounds.origin
        controller.highlight()
        #expect(await waitUntil({ followingLineIsVisible() }, timeout: .seconds(2)))

        #expect(textView.selectedRange() == selected)
        #expect(abs(controller.scrollView.contentView.bounds.minY - scrollOrigin.y) < 40)
        #expect(state.text == textView.string)
      }
      #expect(textView.string == prefix + "追記\n# 編集する本文\n後続の本文\n最後の行")
    }

    @Test func 実行待ちの更新をまとめて次の打鍵も更新する() {
      var pending: [@MainActor () -> Void] = []
      let controller = EditorTextController(
        state: makeState(text: "本文"), enqueueHighlight: { pending.append($0) })
      pending.removeAll()
      let view = controller.textView
      let storage = view.textStorage!
      view.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
      view.insertText("追記", replacementRange: NSRange(location: storage.length, length: 0))
      #expect(pending.count == 1)
      #expect(
        (storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize
          == CGFloat(Preferences.default.fontSize))
      pending.removeFirst()()
      #expect(
        (storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize
          ?? 0 > Preferences.default.fontSize)
      view.insertText("次", replacementRange: NSRange(location: storage.length, length: 0))
      #expect(pending.count == 1)
      pending.removeFirst()()
      let expected = NSTextStorage(string: view.string)
      MarkdownAttributer(theme: .fallback, preferences: .default).apply(to: expected)
      #expect(storage.isEqual(to: expected))
    }

    @Test func 直接ハイライトした後に残った古い予約は新しい予約を妨げない() {
      var pending: [@MainActor () -> Void] = []
      let controller = EditorTextController(
        state: makeState(text: "本文"), enqueueHighlight: { pending.append($0) })
      pending.removeAll()
      let view = controller.textView
      let storage = view.textStorage!
      view.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
      controller.highlight()
      view.insertText("\n# 次", replacementRange: NSRange(location: storage.length, length: 0))
      #expect(pending.count == 2)
      while !pending.isEmpty { pending.removeFirst()() }
      let expected = NSTextStorage(string: view.string)
      MarkdownAttributer(theme: .fallback, preferences: .default).apply(to: expected)
      #expect(storage.isEqual(to: expected))
    }

    @Test func 本文を変えずに外観を変えた直後の入力も新しい設定で表示する() {
      let state = makeState(text: "本文")
      let controller = EditorTextController(state: state, enqueueHighlight: { _ in })
      let view = controller.textView
      view.setSelectedRange(NSRange(location: 2, length: 0))
      state.preferences.fontSize = 24
      state.preferences.themeID = "light"
      controller.syncFromState()
      view.insertText("a", replacementRange: NSRange(location: 2, length: 0))
      let expected = NSTextStorage(string: view.string)
      MarkdownAttributer(theme: state.theme, preferences: state.preferences).apply(to: expected)
      let range = NSRange(location: 2, length: 1)
      #expect(
        view.textStorage!.attributedSubstring(from: range)
          .isEqual(to: expected.attributedSubstring(from: range)))
    }

    @Test(arguments: ["> 引用", "# 見出し", "## 見出し", "**太字**", "*斜体*", "`code`", "[link](url)"])
    func 入力直後の属性が構文と一致する(text: String) {
      let state = makeState(text: text)
      let controller = EditorTextController(state: state, enqueueHighlight: { _ in })
      let view = controller.textView
      for location in [0, 2, (text as NSString).length] {
        state.text = text
        controller.syncFromState()
        controller.highlight()
        view.setSelectedRange(NSRange(location: location, length: 0))
        view.insertText("a", replacementRange: view.selectedRange())
        let expected = NSTextStorage(string: view.string)
        MarkdownAttributer(theme: state.theme, preferences: state.preferences).apply(to: expected)
        let actual = view.textStorage!.attributedSubstring(
          from: NSRange(location: location, length: 1))
        #expect(
          actual.isEqual(
            to: expected.attributedSubstring(from: NSRange(location: location, length: 1))))
        controller.highlight()
        #expect(view.textStorage!.isEqual(to: expected))
      }
    }

    @Test func 改行と記号削除と選択置換で引用色を解除する() {
      let state = makeState(text: "> 引用")
      let controller = EditorTextController(state: state, enqueueHighlight: { _ in })
      let view = controller.textView
      func expectBodyInput() {
        let location = view.selectedRange().location
        view.insertText("a", replacementRange: view.selectedRange())
        #expect(
          view.textStorage!.attribute(.foregroundColor, at: location, effectiveRange: nil)
            as? NSColor
            == state.theme.editorForeground.nsColor)
      }
      view.setSelectedRange(NSRange(location: 4, length: 0))
      view.insertNewline(nil)
      expectBodyInput()
      state.text = "> 引用"
      controller.syncFromState()
      controller.highlight()
      view.setSelectedRange(NSRange(location: 0, length: 1))
      view.deleteBackward(nil)
      expectBodyInput()
      state.text = "> 引用"
      controller.syncFromState()
      controller.highlight()
      view.selectAll(nil)
      expectBodyInput()
      #expect(view.string == "a")
    }

    @Test func 変換中の属性と選択を保ち確定後に設定を反映する() throws {
      let state = makeState(text: "> ")
      let controller = EditorTextController(state: state)
      let view = controller.textView
      view.setSelectedRange(NSRange(location: 2, length: 0))
      let replacement = NSRange(location: NSNotFound, length: 0)
      let marked = NSAttributedString(string: "にほんご", attributes: [.underlineStyle: 2])
      view.setMarkedText(
        marked, selectedRange: NSRange(location: 1, length: 2), replacementRange: replacement)
      try #require(view.hasMarkedText())
      let before = NSAttributedString(attributedString: view.textStorage!)
      let selected = view.selectedRange()
      let markedRange = view.markedRange()
      let typing = view.typingAttributes
      state.preferences.fontSize = 24
      state.preferences.themeID = "light"
      controller.syncFromState()
      controller.highlight()
      #expect(view.textStorage!.isEqual(to: before))
      #expect(view.selectedRange() == selected)
      #expect(view.markedRange() == markedRange)
      #expect(NSDictionary(dictionary: view.typingAttributes).isEqual(to: typing))
      view.insertText("日本語", replacementRange: replacement)
      controller.highlight()
      let location = (view.string as NSString).length
      view.insertText("a", replacementRange: NSRange(location: location, length: 0))
      let expected = NSTextStorage(string: view.string)
      MarkdownAttributer(theme: state.theme, preferences: state.preferences).apply(to: expected)
      #expect(
        view.textStorage!.attributedSubstring(from: NSRange(location: location, length: 1))
          .isEqual(to: expected.attributedSubstring(from: NSRange(location: location, length: 1))))
      #expect(view.string == "> 日本語a")
    }

    @Test func 文字を置換しない変換確定でも保留中の装飾を反映する() {
      var pending: [@MainActor () -> Void] = []
      let state = makeState(text: "> ")
      let controller = EditorTextController(state: state, enqueueHighlight: { pending.append($0) })
      pending.removeAll()
      let view = controller.textView
      view.setSelectedRange(NSRange(location: 2, length: 0))
      view.setMarkedText(
        "にほんご", selectedRange: NSRange(location: 4, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      while !pending.isEmpty { pending.removeFirst()() }
      state.preferences.fontSize = 24
      controller.syncFromState()
      view.unmarkText()
      while !pending.isEmpty { pending.removeFirst()() }
      #expect(!view.hasMarkedText())
      #expect((view.typingAttributes[.font] as? NSFont)?.pointSize == 24)
      #expect(
        (view.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize == 24
      )
    }

    @Test func ハイライト後もUndoRedoで本文と選択を復元する() throws {
      let controller = EditorTextController(state: makeState(text: "> 引用"))
      let view = controller.textView
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = controller.scrollView
      window.makeFirstResponder(view)
      defer { window.orderOut(nil) }
      view.setSelectedRange(NSRange(location: 4, length: 0))
      let undo = try #require(view.undoManager)
      undo.beginUndoGrouping()
      view.insertText("追記", replacementRange: view.selectedRange())
      undo.endUndoGrouping()
      controller.highlight()
      undo.undo()
      controller.highlight()
      #expect(view.string == "> 引用")
      #expect(view.selectedRange() == NSRange(location: 4, length: 0))
      undo.redo()
      controller.highlight()
      #expect(view.string == "> 引用追記")
      #expect(view.selectedRange() == NSRange(location: 6, length: 0))
    }

    private func bodyFontSize(_ controller: EditorTextController) -> Double? {
      let font =
        controller.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
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
      let controller = EditorTextController(state: state)
      let storage = controller.textView.textStorage!

      controller.textView.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
      let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
      #expect(
        font.map { Double($0.pointSize) } == Preferences.default.fontSize,
        "打鍵と同時に全文を敷き直している")
    }

    @Test func 次の実行機会にハイライトが掛かる() async {
      let state = makeState(text: "普通の本文")
      let controller = EditorTextController(state: state)
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
      let controller = EditorTextController(state: state)
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

    @Test func 変換確定直後の同期で次の未確定文字を消さない() throws {
      let state = makeState()
      let controller = EditorTextController(state: state)
      let textView = controller.textView
      let currentInput = NSRange(location: NSNotFound, length: 0)
      textView.setMarkedText(
        "にゅうりょく", selectedRange: NSRange(location: 6, length: 0),
        replacementRange: currentInput)
      textView.setMarkedText(
        "入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: currentInput)
      textView.insertText("入力", replacementRange: currentInput)
      #expect(state.text == "入力")

      textView.setMarkedText(
        "。", selectedRange: NSRange(location: 1, length: 0), replacementRange: currentInput)
      try #require(textView.hasMarkedText())
      let marked = textView.markedRange()
      let selected = textView.selectedRange()

      controller.syncFromState()

      #expect(textView.string == "入力。")
      #expect(textView.markedRange() == marked)
      #expect(textView.selectedRange() == selected)
      textView.insertText("。", replacementRange: currentInput)
      #expect(state.text == "入力。")
    }

    @Test func 最初の未確定文字も同期で消さない() {
      let controller = EditorTextController(state: makeState())
      let textView = controller.textView
      textView.setMarkedText(
        "にほんご", selectedRange: NSRange(location: 4, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))

      controller.syncFromState()

      #expect(textView.string == "にほんご")
      #expect(textView.hasMarkedText())
    }

    @Test func 変換中の改行命令には自動インデントを適用しない() {
      let controller = EditorTextController(state: makeState(text: "  "))
      let textView = controller.textView
      textView.setSelectedRange(NSRange(location: 2, length: 0))
      textView.setMarkedText(
        "入力", selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))

      let handled = controller.textView(
        textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

      #expect(!handled)
      #expect(textView.string == "  入力")
      #expect(textView.hasMarkedText())
    }
  }
}
