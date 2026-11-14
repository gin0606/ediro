import AppKit
import EdiroCore
import EditorEngine
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったコントローラもテストの間は生かしておく。
private var retainedControllers: [EditorTextController] = []

extension AppKitTests {
  /// Backspace でリストのマーカーと字下げの 1 段を消す。キーと同じくコマンド (`deleteBackward:`)
  /// で送る。
  struct BackspaceCommandTests {
    private func makeEditor(
      text: String, insertSpaces: Bool = true, tabSize: Int = 4
    ) -> (EditorView, AppState) {
      let state = makeState(text: text)
      state.preferences.insertSpaces = insertSpaces
      state.preferences.tabSize = tabSize
      let controller = EditorTextController(state: state)
      controller.scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
      controller.editorView.setFrameSize(controller.scrollView.contentSize)
      retainedControllers.append(controller)
      return (controller.editorView, state)
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    private func ranges(_ view: EditorView) -> [NSRange] {
      view.session.selections.map { view.nsRange(of: $0.range) }
    }

    private func backspace(_ view: EditorView) {
      view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
    }

    private func type(_ text: String, into view: EditorView) {
      view.insertText(text, replacementRange: caret(NSNotFound))
    }

    /// `text` の `location` にキャレットを置いて Backspace を押したエディタ。
    private func backspace(
      _ text: String, at location: Int, insertSpaces: Bool = true, tabSize: Int = 4
    ) -> EditorView {
      let (view, _) = makeEditor(text: text, insertSpaces: insertSpaces, tabSize: tabSize)
      view.select([caret(location)], primary: 0)
      backspace(view)
      return view
    }

    // MARK: - 本文の開始位置: マーカーを消す

    @Test(arguments: [
      ("- a", 2, "a", 0), ("* a", 2, "a", 0), ("+ a", 2, "a", 0), ("12. a", 4, "a", 0),
      ("-   a", 4, "a", 0), ("  - a", 4, "  a", 2), ("\t1.\ta", 4, "\ta", 1),
      ("前\n    - a", 8, "前\n    a", 6),
      // チェックボックス付きの項目は、チェックボックスと続く空白まで消す。
      ("- [ ] a", 6, "a", 0), ("    - [x]  a", 11, "    a", 4), ("1. [x] a", 7, "a", 0),
    ])
    func 本文の開始位置ではマーカーと続く空白を消して字下げと本文を残す(
      text: String, location: Int, expected: String, after: Int
    ) {
      let view = backspace(text, at: location)
      #expect(view.text == expected)
      #expect(ranges(view) == [caret(after)])
    }

    @Test(arguments: [
      ("- ", 2, "", 0), ("    - ", 6, "    ", 4), ("- [ ] ", 6, "", 0), ("  3.   ", 7, "  ", 2),
      ("- a\n\t- [x] ", 11, "- a\n\t", 5),
    ])
    func 空の項目ではマーカーを消して字下げを残す(
      text: String, location: Int, expected: String, after: Int
    ) {
      let view = backspace(text, at: location)
      #expect(view.text == expected)
      #expect(ranges(view) == [caret(after)])
    }

    @Test func 本文の開始位置より後ろのリスト行ではふつうに1文字消す() {
      #expect(backspace("- ab", at: 3).text == "- b")
      #expect(backspace("- [ ] a", at: 7).text == "- [ ] ")
      // チェックボックスのない項目では `[` から本文なので、`[` の後ろは本文の途中。
      #expect(backspace("- [ ]a", at: 3).text == "-  ]a")
      // マーカーの直後 (空白の前) は、行頭からが空白だけでないのでふつうに消す。
      #expect(backspace("- a", at: 1).text == " a")
      // 本文の中の空白の後ろも、本文の開始位置ではないのでふつうに消す。
      #expect(backspace("- a b", at: 4).text == "- ab")
    }

    // MARK: - 行頭からが空白だけ: 1 段消す

    @Test(arguments: [
      // スペースだけ: Tab Size の倍数の桁まで。
      ("        a", 8, "    a", 4), ("      a", 6, "    a", 4), ("   a", 3, "a", 0),
      ("        a", 6, "      a", 4), ("    ", 4, "", 0), ("        ", 8, "    ", 4),
      // 直前のタブ文字は 1 つ。
      ("\t\ta", 2, "\ta", 1), ("    \ta", 5, "    a", 4),
      // タブ文字とスペースが混じると、直前に続くスペースを最大 Tab Size 個。
      ("\t  a", 3, "\ta", 1), ("\t      a", 7, "\t  a", 3), (" \t a", 3, " \ta", 2),
      // リスト行でも、キャレットがマーカーより前なら字下げを消す。
      ("        - a", 8, "    - a", 4), ("前\n  - a", 4, "前\n- a", 2),
    ])
    func 行頭からが空白だけならキャレットの前の1段を消す(
      text: String, location: Int, expected: String, after: Int
    ) {
      for insertSpaces in [true, false] {
        let view = backspace(text, at: location, insertSpaces: insertSpaces)
        #expect(view.text == expected)
        #expect(ranges(view) == [caret(after)])
      }
    }

    @Test func 消すスペースの数はTabSizeで決まる() {
      #expect(backspace("     a", at: 5, tabSize: 2).text == "    a")
      #expect(backspace("    a", at: 4, tabSize: 2).text == "  a")
      #expect(backspace("      a", at: 6, tabSize: 8).text == "a")
    }

    // MARK: - それ以外: エンジンの Backspace と同じく 1 文字消す

    @Test func 行頭ではふつうに前の行とつなぐ() {
      let view = backspace("a\n    b", at: 2)
      #expect(view.text == "a    b")
      #expect(ranges(view) == [caret(1)])
      #expect(backspace("- a\n- b", at: 4).text == "- a- b")
      #expect(backspace("- a\n\n", at: 5).text == "- a\n")
      // 文書の先頭では何も消さない。
      #expect(backspace("    a", at: 0).text == "    a")
    }

    @Test func 空白でない文字の後ろではふつうに1文字消す() {
      #expect(backspace("ab", at: 2).text == "a")
      #expect(backspace("  a    ", at: 7).text == "  a   ")
      #expect(backspace("\u{3000}\u{3000}a", at: 2).text == "\u{3000}a")
    }

    @Test func 選択があれば選択を消す() {
      let (view, _) = makeEditor(text: "        - a")
      view.select([NSRange(location: 2, length: 4)], primary: 0)
      backspace(view)
      #expect(view.text == "    - a")
      #expect(ranges(view) == [caret(2)])
    }

    @Test func コードブロックの中ではリストに見える行もリスト行として扱わない() {
      #expect(backspace("```\n- a", at: 6).text == "```\n-a")
      #expect(backspace("```\n  - [ ] a", at: 12).text == "```\n  - [ ]a")
      #expect(backspace("```\n    - ", at: 10).text == "```\n    -")
      // 字下げの 1 段はコードブロックの中でも消す。
      #expect(backspace("```\n        x", at: 12).text == "```\n    x")
      // コードブロックの後のリスト行はリスト行。
      #expect(backspace("```\nx\n```\n- a", at: 12).text == "```\nx\n```\na")
    }

    // CR と CRLF は、エディタの本文 (Document) が LF に揃えるので本文に残らない。
    @Test(arguments: ["\u{2029}", "\u{2028}", "\u{0C}", "\u{85}"])
    func 改行以外の行の区切りも表示と同じく行を分ける(separator: String) {
      #expect(backspace("a" + separator + "    b", at: 6).text == "a" + separator + "b")
      #expect(backspace("a" + separator + "- b", at: 4).text == "a" + separator + "b")
      // 区切りの直後の行頭ではふつうに区切りを消す。
      #expect(backspace("a" + separator + "  b", at: 2).text == "a  b")
    }

    // MARK: - 複数カーソル

    @Test func 複数カーソルではカーソルごとに当てる() {
      let (view, _) = makeEditor(text: "- a\n    b\nc\n- [ ] d")
      view.select([caret(2), caret(8), caret(11), caret(18)], primary: 0)
      backspace(view)
      #expect(view.text == "a\nb\n\nd")
      #expect(ranges(view) == [caret(0), caret(2), caret(4), caret(5)])
      view.undo(nil)
      #expect(view.text == "- a\n    b\nc\n- [ ] d")
      #expect(ranges(view) == [caret(2), caret(8), caret(11), caret(18)])
    }

    @Test func 規則に当たらないカーソルと選択はエンジンのBackspaceと同じ範囲を消す() {
      let (view, _) = makeEditor(text: "    a\nbcd\nef\ngh")
      view.select([caret(4), NSRange(location: 7, length: 2), caret(11), caret(13)], primary: 0)
      backspace(view)
      // 選択は選択を、文字の後ろのキャレットは 1 文字を、行頭のキャレットは前の行とつないで消す。
      #expect(view.text == "a\nb\nfgh")
      #expect(ranges(view) == [caret(0), caret(3), caret(4), caret(5)])
    }

    @Test(arguments: [
      // 絵文字、結合文字、書記素クラスタ (マラヤーラム文字・タイ文字) をエンジンの Backspace と
      // 同じく 1 文字として消す。
      ("👍\n    a", [2, 7], "\na", [0, 1]), ("e\u{301}\n- a", [2, 5], "\na", [0, 1]),
      ("    x\n\u{0D4E}\u{0D15}", [4, 8], "x\n", [0, 2]), ("    a\nทำ", [4, 8], "a\n", [0, 2]),
      // 規則に当たらないキャレットが行頭なら、前の行とつなぐ。
      ("    a\n\u{301}b", [4, 6], "a\u{301}b", [0, 1]),
    ])
    func 規則に当たらないキャレットはエンジンのBackspaceと同じ文字を消す(
      text: String, carets: [Int], expected: String, after: [Int]
    ) {
      let (view, _) = makeEditor(text: text)
      view.select(carets.map(caret), primary: 0)
      backspace(view)
      #expect(view.text == expected)
      #expect(ranges(view) == after.map(caret))
    }

    @Test func 文字の途中のキャレットはその文字を消す() {
      // 2 は、スペースと結合文字からなる文字の途中。
      let view = backspace("  \u{301}a", at: 2)
      #expect(view.text == " a")
      #expect(ranges(view) == [caret(1)])

      let (mixed, _) = makeEditor(text: "  \u{301}a\n    b")
      mixed.select([caret(2), caret(9)], primary: 0)
      backspace(mixed)
      #expect(mixed.text == " a\nb")
      #expect(ranges(mixed) == [caret(1), caret(3)])
    }

    @Test func 単語の選択は規則に当たるキャレットと一緒でもスマート削除で消す() {
      let (view, _) = makeEditor(text: "    a\nhello world foo")
      view.select([caret(4), NSRange(location: 12, length: 5)], primary: 0)
      view.inputAssistance.wordSelection = true
      backspace(view)
      #expect(view.text == "a\nhello foo")
      #expect(ranges(view) == [caret(0), caret(7)])
    }

    @Test func 単語でない選択は規則に当たるキャレットと一緒でも選択の範囲だけを消す() {
      let (view, _) = makeEditor(text: "    a\nhello world foo")
      view.select([caret(4), NSRange(location: 12, length: 5)], primary: 0)
      backspace(view)
      #expect(view.text == "a\nhello  foo")
      #expect(ranges(view) == [caret(0), caret(8)])
    }

    @Test func 単語の選択があればスマート削除と同じく削除のまとまりに入れない() {
      // 4 は規則に当たるキャレット。5 は規則に当たらず、比べるためのスマート削除だけの場合。
      for rule in [4, 5] {
        let (view, _) = makeEditor(text: "    a\nhello world foo")
        view.select([caret(rule), NSRange(location: 12, length: 5)], primary: 0)
        view.inputAssistance.wordSelection = true
        backspace(view)
        let afterFirst = view.text
        backspace(view)
        view.undo(nil)
        #expect(view.text == afterFirst, "\(rule)")
      }
    }

    @Test func スマート挿入削除がオフなら単語の選択も選択の範囲だけを消して削除のまとまりに入れる() {
      let (view, _) = makeEditor(text: "    a\nทำ\nhello world")
      view.smartInsertDeleteEnabled = false
      view.select([caret(4), caret(8), NSRange(location: 15, length: 5)], primary: 0)
      view.inputAssistance.wordSelection = true
      backspace(view)
      #expect(view.text == "a\n\nhello ")
      backspace(view)
      view.undo(nil)
      #expect(view.text == "    a\nทำ\nhello world")
    }

    @Test func 単語の選択があっても規則に当たらないキャレットはエンジンのBackspaceと同じ文字を消す() {
      // タイ文字の ทำ は、NSString の合成文字の単位では 2 文字だが、エンジンでは 1 文字。
      // 規則に当たるキャレットがあってもなくても同じ。
      for (rule, expected) in [(4, "a\n\nhello"), (5, "    \n\nhello")] {
        let (view, _) = makeEditor(text: "    a\nทำ\nhello world")
        view.select([caret(rule), caret(8), NSRange(location: 15, length: 5)], primary: 0)
        view.inputAssistance.wordSelection = true
        backspace(view)
        #expect(view.text == expected, "\(rule)")
      }
    }

    @Test func 同じ行の複数のカーソルもそれぞれの前を消す() {
      let (view, _) = makeEditor(text: "        - a")
      view.select([caret(4), caret(8)], primary: 0)
      backspace(view)
      #expect(view.text == "- a")
      // 同じ位置に移ったキャレットは 1 つにまとまる。
      #expect(ranges(view) == [caret(0)])

      let (marker, _) = makeEditor(text: "    - a")
      marker.select([caret(4), caret(6)], primary: 0)
      backspace(marker)
      #expect(marker.text == "a")
      #expect(ranges(marker) == [caret(0)])
    }

    // MARK: - Undo

    @Test func 続けたBackspaceはふつうのBackspaceとまとめて取り消す() {
      let (view, _) = makeEditor(text: "    ab")
      view.select([caret(6)], primary: 0)
      backspace(view)
      backspace(view)
      #expect(view.text == "    ")
      backspace(view)
      #expect(view.text == "")
      view.undo(nil)
      #expect(view.text == "    ab")
      #expect(ranges(view) == [caret(6)])
      #expect(!view.document.canUndo)

      let (item, _) = makeEditor(text: "    - a")
      item.select([caret(6)], primary: 0)
      backspace(item)
      backspace(item)
      #expect(item.text == "a")
      item.undo(nil)
      #expect(item.text == "    - a")
      #expect(ranges(item) == [caret(6)])
    }

    @Test func Backspaceは打鍵とは別に取り消す() {
      let (view, _) = makeEditor(text: "")
      view.select([caret(0)], primary: 0)
      type("- ", into: view)
      backspace(view)
      #expect(view.text == "")
      view.undo(nil)
      #expect(view.text == "- ")
      #expect(ranges(view) == [caret(2)])
      view.undo(nil)
      #expect(view.text == "")
    }

    // MARK: - 日本語入力

    @Test func 変換中のBackspaceは本文を変えない() {
      for (text, location) in [("- ", 2), ("    ", 4), ("    - a", 6)] {
        let (view, state) = makeEditor(text: text)
        view.select([caret(location)], primary: 0)
        // キャレットを未確定の文字の前に置き、規則に当たる位置にする。
        view.setMarkedText("か", selectedRange: caret(0), replacementRange: caret(NSNotFound))
        #expect(ranges(view) == [caret(location)])
        let marked = (text as NSString).replacingCharacters(in: caret(location), with: "か")
        backspace(view)
        #expect(view.text == marked)
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: location, length: 1))
        #expect(state.text == text)
      }
    }
  }
}
