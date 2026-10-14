import AppKit
import EdiroCore
import EditorEngine
import EditorMarkdown
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったコントローラもテストの間は生かしておく。本文の変更を
/// 状態へ流すのはコントローラなので、先に解放されると何も反映されない。
private var retainedControllers: [EditorTextController] = []

extension AppKitTests {
  struct EditorTextControllerTests {
    /// 幅を持たせたエディタ。折り返しや上下移動はレイアウトの幅に依存する。
    private func makeEditor(text: String = "", width: CGFloat = 400) -> (
      EditorTextController, EditorView, AppState
    ) {
      let state = makeState(text: text)
      let controller = EditorTextController(state: state)
      controller.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 300)
      controller.editorView.setFrameSize(controller.scrollView.contentSize)
      retainedControllers.append(controller)
      return (controller, controller.editorView, state)
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    private func carets(_ view: EditorView) -> [NSRange] {
      view.session.selections.map { view.nsRange(of: $0.range) }
    }

    /// 本文全体を初めから装飾した結果と、エディタの表示が一致する。
    private func expectHighlighted(
      _ view: EditorView, _ state: AppState, sourceLocation: SourceLocation = #_sourceLocation
    ) {
      // TextKit 2 に載せた NSTextStorage は、和文などのフォールバックの書体を属性に書き込まない。
      // 比べる側も同じく載せておく。
      let document = Document(id: "expected", text: view.text, lineTokenizer: MarkdownTokenizer())
      let expected = EditorLayout()
      expected.replaceAll(with: view.text)
      MarkdownAttributer(theme: state.theme, preferences: state.preferences)
        .applyAll(of: document, to: expected.storage)
      #expect(view.layout.storage.isEqual(to: expected.storage), sourceLocation: sourceLocation)
    }

    @Test func 長文の下部を編集しても表示位置と選択位置を保つ() async throws {
      let prefix = String(repeating: "# Heading\n本文と**太字**です。\n", count: 500)
      let (controller, view, state) = makeEditor(text: prefix + "編集する本文\n後続の本文\n最後の行")
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = controller.scrollView
      defer { window.orderOut(nil) }
      window.makeFirstResponder(view)
      window.orderFront(nil)
      let location = (prefix as NSString).length
      view.select([caret(location)], primary: 0)
      try #require(controller.scrollView.contentView.bounds.minY > 0)

      for input in ["追記", "\n", "# "] {
        let scrollOrigin = controller.scrollView.contentView.bounds.origin
        view.insertText(input, replacementRange: caret(NSNotFound))
        #expect(abs(controller.scrollView.contentView.bounds.minY - scrollOrigin.y) < 40)
        #expect(state.text == view.text)
      }
      #expect(view.selectedRange() == caret(location + 5))
      #expect(view.text == prefix + "追記\n# 編集する本文\n後続の本文\n最後の行")
    }

    @Test(arguments: ["> 引用", "# 見出し", "## 見出し", "**太字**", "*斜体*", "`code`", "[link](url)"])
    func 入力の直後から装飾が構文と一致する(text: String) {
      for location in [0, 2, (text as NSString).length] {
        let (_, view, state) = makeEditor(text: text)
        view.select([caret(location)], primary: 0)
        view.insertText("a", replacementRange: caret(NSNotFound))
        expectHighlighted(view, state)
      }
    }

    @Test func 先頭でフェンスを開いた直後から文書の末尾までコードの装飾になる() {
      let (_, view, state) = makeEditor(text: "``\n# 見出し\n**太字**\n")
      view.select([caret(2)], primary: 0)
      view.insertText("`", replacementRange: caret(NSNotFound))
      expectHighlighted(view, state)
      let color = view.layout.storage.attribute(.foregroundColor, at: 4, effectiveRange: nil)
      #expect(color as? NSColor == SyntaxPalette(theme: state.theme).style(for: .codeBlock).color.nsColor)
      view.deleteBackward(nil)
      expectHighlighted(view, state)
    }

    @Test func トークンが変わらない編集では編集した行の外の属性を当て直さない() {
      let prefix = String(repeating: "# 見出し\n本文と**太字**です。\n", count: 500)
      let (_, view, state) = makeEditor(text: prefix + "編集する本文\n後続の本文")
      let recorder = MarkdownAttributerTests.EditRecorder()
      view.layout.storage.delegate = recorder

      for (location, input) in [((prefix as NSString).length + 2, "a"), (3, "b"), (0, "# ")] {
        view.select([caret(location)], primary: 0)
        recorder.ranges = []
        view.insertText(input, replacementRange: caret(NSNotFound))
        let line = (view.text as NSString).lineRange(for: caret(location))
        let edited = recorder.ranges
        #expect(!edited.isEmpty)
        #expect(edited.allSatisfy { NSIntersectionRange($0, line) == $0 }, "\(edited) \(line)")
        expectHighlighted(view, state)
      }
    }

    @Test func 改行と記号削除と選択置換の直後から装飾が構文と一致する() {
      let (_, view, state) = makeEditor(text: "> 引用")
      view.select([caret(4)], primary: 0)
      view.insertNewline(nil)
      view.insertText("a", replacementRange: caret(NSNotFound))
      expectHighlighted(view, state)
      view.select([NSRange(location: 0, length: 1)], primary: 0)
      view.deleteBackward(nil)
      expectHighlighted(view, state)
      view.selectAll(nil)
      view.insertText("a", replacementRange: caret(NSNotFound))
      expectHighlighted(view, state)
      #expect(view.text == "a")
    }

    @Test func 外観を変えた直後の入力も新しい設定で表示する() {
      let (controller, view, state) = makeEditor(text: "本文")
      view.select([caret(2)], primary: 0)
      state.preferences.fontSize = 24
      state.preferences.themeID = "light"
      controller.syncFromState()
      view.insertText("a", replacementRange: caret(NSNotFound))
      expectHighlighted(view, state)
    }

    @Test func 変換中の文字は下書きに含めず確定したら反映する() throws {
      let (_, view, state) = makeEditor(text: "> ")
      view.select([caret(2)], primary: 0)
      view.setMarkedText(
        "にほんご", selectedRange: NSRange(location: 1, length: 2), replacementRange: caret(NSNotFound))
      try #require(view.hasMarkedText())
      #expect(view.text == "> にほんご")
      #expect(view.markedRange() == NSRange(location: 2, length: 4))
      #expect(view.selectedRange() == NSRange(location: 3, length: 2))
      #expect(state.text == "> ")
      view.insertText("日本語", replacementRange: caret(NSNotFound))
      #expect(!view.hasMarkedText())
      #expect(state.text == "> 日本語")
      #expect(view.selectedRange() == caret(5))
      expectHighlighted(view, state)
    }

    @Test func 未確定の文字を全て消すと変換を終える() {
      let (_, view, state) = makeEditor(text: "本文")
      view.select([caret(2)], primary: 0)
      view.setMarkedText("か", selectedRange: caret(1), replacementRange: caret(NSNotFound))
      view.setMarkedText("", selectedRange: caret(0), replacementRange: caret(NSNotFound))
      #expect(!view.hasMarkedText())
      #expect(view.text == "本文" && state.text == "本文")
      #expect(!view.document.canUndo)
    }

    @Test func 変換確定直後の同期で次の未確定文字を消さない() throws {
      let (controller, view, state) = makeEditor()
      let currentInput = caret(NSNotFound)
      view.setMarkedText("にゅうりょく", selectedRange: caret(6), replacementRange: currentInput)
      view.setMarkedText("入力", selectedRange: caret(2), replacementRange: currentInput)
      view.insertText("入力", replacementRange: currentInput)
      #expect(state.text == "入力")

      view.setMarkedText("。", selectedRange: caret(1), replacementRange: currentInput)
      try #require(view.hasMarkedText())
      let marked = view.markedRange()
      let selected = view.selectedRange()
      controller.syncFromState()

      #expect(view.text == "入力。")
      #expect(view.markedRange() == marked)
      #expect(view.selectedRange() == selected)
      view.insertText("。", replacementRange: currentInput)
      #expect(state.text == "入力。")
    }

    @Test func 最初の未確定文字も同期で消さない() {
      let (controller, view, _) = makeEditor()
      view.setMarkedText("にほんご", selectedRange: caret(4), replacementRange: caret(NSNotFound))
      controller.syncFromState()
      #expect(view.text == "にほんご")
      #expect(view.hasMarkedText())
    }

    @Test func 変換中の改行命令では本文を変えない() {
      let (_, view, _) = makeEditor(text: "  ")
      view.select([caret(2)], primary: 0)
      view.setMarkedText("入力", selectedRange: caret(2), replacementRange: caret(NSNotFound))
      view.insertNewline(nil)
      #expect(view.text == "  入力")
      #expect(view.hasMarkedText())
    }

    @Test func IMEが直前の文字の置き換えを指示しても全てのキャレットに当てる() {
      let (_, view, _) = makeEditor(text: "ab\nab")
      view.select([caret(2), caret(5)], primary: 1)
      // 主のキャレットの直前の 1 文字を置き換える指示。
      view.setMarkedText("X", selectedRange: caret(1), replacementRange: NSRange(location: 4, length: 1))
      #expect(view.text == "aX\naX")
      view.unmarkText()
      view.insertText("Y", replacementRange: NSRange(location: 4, length: 1))
      #expect(view.text == "aY\naY")
    }

    @Test func 取り消しとやり直しで本文と選択を戻す() {
      let (_, view, state) = makeEditor(text: "> 引用")
      view.select([caret(4)], primary: 0)
      view.insertText("追記", replacementRange: caret(NSNotFound))
      view.undo(nil)
      #expect(view.text == "> 引用" && state.text == "> 引用")
      #expect(view.selectedRange() == caret(4))
      expectHighlighted(view, state)
      view.redo(nil)
      #expect(view.text == "> 引用追記")
      #expect(view.selectedRange() == caret(6))
    }

    @Test func キャレットを動かすと続けて打った文字は別に取り消す() {
      let (_, view, _) = makeEditor(text: "ab")
      view.insertText("1", replacementRange: caret(NSNotFound))
      view.insertText("2", replacementRange: caret(NSNotFound))
      view.moveToEndOfDocument(nil)
      view.insertText("3", replacementRange: caret(NSNotFound))
      view.undo(nil)
      #expect(view.text == "12ab")
      view.undo(nil)
      #expect(view.text == "ab")
    }

    private func bodyFontSize(_ controller: EditorTextController) -> Double? {
      let font =
        controller.editorView.layout.storage.attribute(.font, at: 0, effectiveRange: nil)
        as? NSFont
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
      #expect(controller.editorView.backgroundColor.brightnessComponent < 0.5)

      state.preferences.themeID = "light"
      #expect(await waitUntil { controller.editorView.backgroundColor.brightnessComponent > 0.5 })
    }

    @Test func タブ幅の設定が本文の描画に効く() async throws {
      let (_, view, state) = makeEditor(text: "\tb")
      func tabEnd() -> CGFloat { view.layout.caretRect(at: 1).minX }
      let before = tabEnd()
      state.preferences.tabSize = 8
      #expect(await waitUntil { tabEnd() > before })
    }

    @Test func 外側から差し替えた本文がエディタに伝わる() async throws {
      let (_, view, state) = makeEditor(text: "はじめの本文")
      view.select([caret(4)], primary: 0)
      state.text = "差し替えた本文"
      #expect(await waitUntil { view.text == "差し替えた本文" })
      #expect(view.selectedRange() == caret(4))
      #expect(!view.document.canUndo)
    }

    @Test func 外側から差し替えた本文も装飾し打鍵で装飾が変わる() async throws {
      let (_, view, state) = makeEditor(text: "# 見出し")
      let text = "本文と**太字**\n``\n# 見出し\n> 引用"
      state.text = text
      #expect(await waitUntil { view.text == text })
      expectHighlighted(view, state)
      view.select([caret((text as NSString).range(of: "``").location + 2)], primary: 0)
      view.insertText("`", replacementRange: caret(NSNotFound))
      expectHighlighted(view, state)
    }

    @Test func エディタへの入力が状態に伝わる() {
      let (_, view, state) = makeEditor()
      view.insertText("打ち込んだ", replacementRange: caret(NSNotFound))
      #expect(state.text == "打ち込んだ")
      #expect(state.metrics.characters == 5)
    }

    @Test func コピーは書式なしテキストだけをクリップボードに載せる() {
      let (_, view, _) = makeEditor(text: "**太字**と# 見出し")
      view.selectAll(nil)
      let pasteboard = NSPasteboard(name: .init("ediro.test.\(UUID().uuidString)"))
      view.writeSelection(to: pasteboard)
      let written = pasteboard.types ?? []
      #expect(!written.contains(.rtf), "書式付きデータが載っている: \(written)")
      #expect(pasteboard.string(forType: .string) == "**太字**と# 見出し")
    }

    @Test func 改行すると前の行のインデントを引き継ぐ() {
      let (_, view, _) = makeEditor(text: "    ネストした行")
      view.select([caret(10)], primary: 0)
      view.insertNewline(nil)
      #expect(view.text == "    ネストした行\n    ")
    }

    @Test func インデントのない行では余計な空白を足さない() {
      let (_, view, _) = makeEditor(text: "ふつうの行")
      view.select([caret(5)], primary: 0)
      view.insertNewline(nil)
      #expect(view.text == "ふつうの行\n")
    }

    @Test func 行頭で改行してもインデントは深くならない() {
      let (_, view, _) = makeEditor(text: "    インデント行")
      view.select([caret(0)], primary: 0)
      view.insertNewline(nil)
      #expect(view.text == "\n    インデント行")
    }

    @Test func インデントの内側で改行しても深さを保つ() {
      let (_, view, _) = makeEditor(text: "    インデント行")
      view.select([caret(2)], primary: 0)
      view.insertNewline(nil)
      #expect(view.text == "  \n    インデント行")
    }

    @Test func 行の途中で改行しても深さを保つ() {
      let (_, view, _) = makeEditor(text: "  あいうえお")
      view.select([caret(4)], primary: 0)
      view.insertNewline(nil)
      #expect(view.text == "  あい\n  うえお")
    }

    // MARK: - 移動

    @Test func 単語と行の単位で動いて選択を広げる() {
      let (_, view, _) = makeEditor(text: "one two three\nnext")
      view.select([caret(5)], primary: 0)
      view.moveWordRight(nil)
      #expect(view.selectedRange() == caret(7))
      view.moveWordLeftAndModifySelection(nil)
      #expect(view.selectedRange() == NSRange(location: 4, length: 3))
      view.moveToEndOfLine(nil)
      #expect(view.selectedRange() == caret(13))
      view.moveToBeginningOfLineAndModifySelection(nil)
      #expect(view.selectedRange() == NSRange(location: 0, length: 13))
      view.moveDown(nil)
      #expect(view.selectedRange().location > 13)
      view.deleteWordBackward(nil)
      #expect(view.text.hasPrefix("one two three\n"))
    }

    @Test func 行と段落の端への移動は端にいてもその行に留まる() {
      let (_, view, _) = makeEditor(text: "abc def\nghi jkl\nmno")
      for move in [view.moveToBeginningOfLine, view.moveToBeginningOfParagraph, view.moveToLeftEndOfLine] {
        view.select([caret(8)], primary: 0)
        move(nil)
        #expect(view.selectedRange() == caret(8))
      }
      for move in [view.moveToEndOfLine, view.moveToEndOfParagraph, view.moveToRightEndOfLine] {
        view.select([caret(15)], primary: 0)
        move(nil)
        #expect(view.selectedRange() == caret(15))
      }
    }

    @Test func 置換範囲が本文の外にはみ出すキャレットは広げずに打つ() {
      let (_, view, _) = makeEditor(text: "abc\nxyzw")
      view.select([caret(0), caret(6)], primary: 1)
      view.insertText("Q", replacementRange: NSRange(location: 4, length: 2))
      #expect(view.text == "Qabc\nQzw")
      let (_, emoji, _) = makeEditor(text: "x😀\nabc\ntail")
      emoji.select([caret(3), caret(6)], primary: 1)
      emoji.insertText("é", replacementRange: NSRange(location: 5, length: 1))
      #expect(emoji.text == "x😀é\naéc\ntail")
    }

    @Test func 選択が一つならEscを次の応答者に渡さない() {
      final class Receiver: NSResponder {
        var cancelled = false
        override func cancelOperation(_ sender: Any?) { cancelled = true }
      }
      let (_, view, _) = makeEditor(text: "hel")
      view.select([caret(3)], primary: 0)
      let receiver = Receiver()
      view.nextResponder = receiver
      view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
      #expect(!receiver.cancelled)
      #expect(view.text == "hel")
    }

    @Test func 変換中の切り取りはクリップボードも本文も変えない() {
      let (_, view, _) = makeEditor(text: "abc")
      view.select([caret(3)], primary: 0)
      view.setMarkedText("かな", selectedRange: NSRange(location: 0, length: 2), replacementRange: caret(NSNotFound))
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString("kept", forType: .string)
      view.cut(nil)
      #expect(NSPasteboard.general.string(forType: .string) == "kept")
      #expect(view.text == "abcかな" && view.hasMarkedText())
    }

    @Test func 上下の移動で横位置を保つ() {
      let (_, view, _) = makeEditor(text: "abcdef\nab\nabcdef")
      view.select([caret(5)], primary: 0)
      view.moveDown(nil)
      #expect(view.selectedRange() == caret(9))
      view.moveDown(nil)
      #expect(view.selectedRange() == caret(15))
      view.moveUp(nil)
      view.moveUp(nil)
      #expect(view.selectedRange() == caret(5))
    }

    // MARK: - 複数カーソル

    @Test func 複数のキャレットに同時に打ち込んで一度に取り消す() {
      let (_, view, state) = makeEditor(text: "a\nb\nc")
      view.select([caret(1), caret(3), caret(5)], primary: 0)
      view.insertText("!", replacementRange: caret(NSNotFound))
      #expect(view.text == "a!\nb!\nc!" && state.text == "a!\nb!\nc!")
      view.undo(nil)
      #expect(view.text == "a\nb\nc")
      #expect(carets(view) == [caret(1), caret(3), caret(5)])
    }

    @Test func 複数のキャレットで変換して確定する() throws {
      let (_, view, state) = makeEditor(text: "a\nb")
      view.select([caret(1), caret(3)], primary: 1)
      view.setMarkedText("にほん", selectedRange: caret(3), replacementRange: caret(NSNotFound))
      #expect(view.text == "aにほん\nbにほん")
      #expect(view.markedRange() == NSRange(location: 6, length: 3))
      #expect(state.text == "a\nb")
      view.insertText("日本", replacementRange: caret(NSNotFound))
      #expect(view.text == "a日本\nb日本" && state.text == "a日本\nb日本")
      #expect(carets(view) == [caret(3), caret(7)])
    }

    @Test func 複数のキャレットでの改行はそれぞれの行のインデントを引き継ぐ() {
      let (_, view, _) = makeEditor(text: "a\n  b")
      view.select([caret(1), caret(5)], primary: 0)
      view.insertNewline(nil)
      #expect(view.text == "a\n\n  b\n  ")
    }

    @Test func 行数がキャレットの数と同じなら一行ずつ貼り付ける() {
      let (_, view, _) = makeEditor(text: "a\nb\nc")
      let pasteboard = NSPasteboard(name: .init("ediro.test.\(UUID().uuidString)"))
      pasteboard.clearContents()
      pasteboard.setString("1\n2", forType: .string)
      view.select([caret(1), caret(3)], primary: 0)
      view.paste(from: pasteboard)
      #expect(view.text == "a1\nb2\nc")
      view.select([caret(0), caret(3), caret(6)], primary: 0)
      view.paste(from: pasteboard)
      #expect(view.text == "1\n2a1\n1\n2b2\n1\n2c")
      // CRLF で区切った行も一行ずつ配る。
      let (_, crlf, _) = makeEditor(text: "a\nb")
      pasteboard.clearContents()
      pasteboard.setString("1\r\n2", forType: .string)
      crlf.select([caret(1), caret(3)], primary: 0)
      crlf.paste(from: pasteboard)
      #expect(crlf.text == "a1\nb2")
    }

    @Test func 複数の選択はコピーすると改行で繋ぐ() {
      let (_, view, _) = makeEditor(text: "one two")
      view.select([NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)], primary: 0)
      let pasteboard = NSPasteboard(name: .init("ediro.test.\(UUID().uuidString)"))
      view.writeSelection(to: pasteboard)
      #expect(pasteboard.string(forType: .string) == "one\ntwo")
    }

    @Test func 次の一致を選択に加える() {
      let (_, view, _) = makeEditor(text: "foo bar foo foo")
      view.select([caret(1)], primary: 0)
      view.addNextOccurrence(nil)
      #expect(carets(view) == [NSRange(location: 0, length: 3)])
      view.addNextOccurrence(nil)
      #expect(carets(view) == [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)])
      #expect(view.selectedRange() == NSRange(location: 8, length: 3))
      view.addNextOccurrence(nil)
      view.insertText("X", replacementRange: caret(NSNotFound))
      #expect(view.text == "X bar X X")
    }

    @Test func 次の一致は末尾から先頭へ回って探す() {
      let (_, view, _) = makeEditor(text: "aa x aa")
      view.select([NSRange(location: 5, length: 2)], primary: 0)
      view.addNextOccurrence(nil)
      #expect(carets(view) == [NSRange(location: 0, length: 2), NSRange(location: 5, length: 2)])
      #expect(view.selectedRange() == NSRange(location: 0, length: 2))
    }

    @Test func 上下の行にキャレットを足す() {
      let (_, view, _) = makeEditor(text: "abc\nabc\nabc")
      view.select([caret(6)], primary: 0)
      view.addCursorAbove(nil)
      #expect(carets(view) == [caret(2), caret(6)])
      #expect(view.selectedRange() == caret(2))
      view.addCursorBelow(nil)
      #expect(carets(view) == [caret(2), caret(6), caret(10)])
    }
  }
}
