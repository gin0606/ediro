import AppKit
import EdiroCore
import EditorEngine
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったコントローラもテストの間は生かしておく。
private var retainedControllers: [EditorTextController] = []

extension AppKitTests {
  /// リストの中の Enter。キーと同じくコマンド (`insertNewline:`) で送る。
  struct ListNewlineCommandTests {
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

    private func length(_ text: String) -> Int { (text as NSString).length }

    private func enter(_ view: EditorView) {
      view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    /// `text` の末尾にキャレットを置いて Enter を押したエディタ。
    private func enterAtEnd(of text: String, insertSpaces: Bool = true) -> EditorView {
      let (view, _) = makeEditor(text: text, insertSpaces: insertSpaces)
      view.select([caret(length(text))], primary: 0)
      enter(view)
      return view
    }

    private func type(_ text: String, into view: EditorView) {
      view.insertText(text, replacementRange: caret(NSNotFound))
    }

    // MARK: - 本文のある項目: 項目を続ける

    @Test(arguments: [
      ("- a", "- a\n- "), ("* a", "* a\n* "), ("+ a", "+ a\n+ "), ("1. a", "1. a\n2. "),
      ("9. a", "9. a\n10. "), ("- [ ] a", "- [ ] a\n- [ ] "), ("- [x] a", "- [x] a\n- [ ] "),
      ("3. [x] a", "3. [x] a\n4. [ ] "), ("  - a", "  - a\n  - "),
      ("\t7.\t[x]  a", "\t7.\t[x]  a\n\t8.\t[ ]  "), ("前の行\n-   a", "前の行\n-   a\n-   "),
    ])
    func 本文のある項目の行末では同じ字下げで次のマーカーを入れる(text: String, expected: String) {
      let view = enterAtEnd(of: text)
      #expect(view.text == expected)
      #expect(ranges(view) == [caret(length(expected))])
    }

    @Test func 本文の途中ではキャレットより後ろの本文が新しい項目に移る() {
      let (view, _) = makeEditor(text: "  1. abc")
      view.select([caret(6)], primary: 0)
      enter(view)
      #expect(view.text == "  1. a\n  2. bc")
      #expect(ranges(view) == [caret(12)])

      // 本文の開始位置では、本文ごと新しい項目に移る。
      let (start, _) = makeEditor(text: "- [ ] abc")
      start.select([caret(6)], primary: 0)
      enter(start)
      #expect(start.text == "- [ ] \n- [ ] abc")
      #expect(ranges(start) == [caret(13)])
    }

    @Test func 選択があれば選択を消してから選択の始まりで項目を続ける() {
      let (view, _) = makeEditor(text: "- abcd")
      view.select([NSRange(location: 3, length: 2)], primary: 0)
      enter(view)
      #expect(view.text == "- a\n- d")
      #expect(ranges(view) == [caret(6)])

      // 行を跨ぐ選択は、選択を消した後の行で決める。
      let (lines, _) = makeEditor(text: "- ab\ncd")
      lines.select([NSRange(location: 3, length: 3)], primary: 0)
      enter(lines)
      #expect(lines.text == "- a\n- d")
    }

    @Test func Enterの4つのコマンドはどれも項目を続ける() {
      for command in [
        #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
        #selector(NSResponder.insertLineBreak(_:)),
        #selector(NSResponder.insertParagraphSeparator(_:)),
      ] {
        let (view, _) = makeEditor(text: "1. a\n    - ")
        view.select([caret(4)], primary: 0)
        view.doCommand(by: command)
        #expect(view.text == "1. a\n2. \n    - ", "\(command)")
        view.select([caret(15)], primary: 0)
        view.doCommand(by: command)
        #expect(view.text == "1. a\n2. \n3. ", "\(command)")
      }
    }

    // MARK: - 空の項目: 1 段戻る

    @Test(arguments: ["- ", "* ", "1. ", "- [ ] ", "2. [x] ", "-   "])
    func 字下げのない空の項目はマーカーを消して空行にする(item: String) {
      let view = enterAtEnd(of: "- a\n" + item)
      #expect(view.text == "- a\n")
      #expect(ranges(view) == [caret(4)])
    }

    @Test func 字下げのある空の項目は改行せずに1段字上げする() {
      let view = enterAtEnd(of: "- a\n        - ")
      #expect(view.text == "- a\n    - ")
      #expect(ranges(view) == [caret(10)])

      // 字上げは Shift+Tab と同じく行頭のタブ文字 1 つかスペース最大 Tab Size 個。
      let tab = enterAtEnd(of: "- a\n\t\t- ", insertSpaces: false)
      #expect(tab.text == "- a\n\t- ")
      let partial = enterAtEnd(of: "- a\n  - ")
      #expect(partial.text == "- a\n- ")
    }

    @Test func 戻った先の深さに同じ深さのリスト行があればそのマーカーに合わせる() {
      // 例: 2 行目と 3 行目は 1 段字下げ。
      let view = enterAtEnd(of: "1. 親\n    - 子\n    - ")
      #expect(view.text == "1. 親\n    - 子\n2. ")
      #expect(ranges(view) == [caret(length(view.text))])

      #expect(enterAtEnd(of: "* a\n    1. b\n    1. ").text == "* a\n    1. b\n* ")
      // 空行と、戻った先より深い行は飛ばす。空白だけの行も、見た目が空行と変わらないので飛ばす。
      #expect(
        enterAtEnd(of: "3. a\n\n    - b\n        - c\n\n    - ").text
          == "3. a\n\n    - b\n        - c\n\n4. ")
      for blank in ["  ", "    ", "\t\t"] {
        #expect(
          enterAtEnd(of: "1. a\n    1. b\n" + blank + "\n        - ").text
            == "1. a\n    1. b\n" + blank + "\n    2. ")
      }
      // 字下げの幅はタブ文字を Tab Size 桁と数える。
      #expect(
        enterAtEnd(of: "- a\n    1. b\n\t\t* ", insertSpaces: false).text
          == "- a\n    1. b\n\t2. ")
    }

    @Test func 戻った先の深さの行がリスト行でなければ元のマーカーのまま() {
      #expect(enterAtEnd(of: "段落\n    * ").text == "段落\n* ")
      #expect(enterAtEnd(of: "- a\n    b\n        9. ").text == "- a\n    b\n    9. ")
      // コードブロックの中の行 (フェンスの行を含む) はリスト行として扱わない。
      #expect(enterAtEnd(of: "```\n- a\n```\n    * ").text == "```\n- a\n```\n* ")
    }

    @Test func 戻った先より浅い行に先に当たるか文書の先頭に達したら元のマーカーのまま() {
      #expect(enterAtEnd(of: "- a\n        * ").text == "- a\n    * ")
      #expect(enterAtEnd(of: "1. a\n    - b\n            - ").text == "1. a\n    - b\n        - ")
      #expect(enterAtEnd(of: "    5. ").text == "5. ")
    }

    @Test func チェックボックスは元の項目に付いていれば未チェックで残す() {
      #expect(enterAtEnd(of: "- a\n    - [x] ").text == "- a\n- [ ] ")
      #expect(enterAtEnd(of: "1. a\n    - [ ] ").text == "1. a\n2. [ ] ")
      #expect(enterAtEnd(of: "1. [x] a\n    - ").text == "1. [x] a\n2. ")
    }

    @Test func 選択を消すと空の項目になるなら1段戻る() {
      let (view, _) = makeEditor(text: "- a\n    - bc\nde")
      view.select([NSRange(location: 10, length: 5)], primary: 0)
      enter(view)
      #expect(view.text == "- a\n- ")
      #expect(ranges(view) == [caret(6)])
    }

    // MARK: - 空白だけの行: 1 段戻る

    @Test(arguments: [("    ", ""), ("      ", "  "), ("  ", ""), ("\t\t", "\t"), (" \t", "\t")])
    func 空白だけの行の行末では改行せずに行頭から1段消す(line: String, expected: String) {
      let view = enterAtEnd(of: "a\n" + line)
      #expect(view.text == "a\n" + expected)
      #expect(ranges(view) == [caret(2 + length(expected))])
    }

    // MARK: - 今までどおりの改行

    @Test func キャレットが本文の開始位置より前のリスト行ではふつうに改行する() {
      for (location, expected) in [
        (0, "\n    - a"), (2, "  \n    - a"), (4, "    \n    - a"), (5, "    -\n     a"),
      ] {
        let (view, _) = makeEditor(text: "    - a")
        view.select([caret(location)], primary: 0)
        enter(view)
        #expect(view.text == expected, "\(location)")
      }
      // 空の項目も同じ。
      let (empty, _) = makeEditor(text: "  -  ")
      empty.select([caret(4)], primary: 0)
      enter(empty)
      #expect(empty.text == "  - \n   ")
    }

    @Test func リストでない行と空行と行末でない空白だけの行ではふつうに改行する() {
      #expect(enterAtEnd(of: "  本文").text == "  本文\n  ")
      #expect(enterAtEnd(of: "- a\n").text == "- a\n\n")
      #expect(enterAtEnd(of: "-a").text == "-a\n")
      let (blank, _) = makeEditor(text: "    ")
      blank.select([caret(2)], primary: 0)
      enter(blank)
      #expect(blank.text == "  \n    ")
    }

    @Test func コードブロックの中ではふつうに改行する() {
      #expect(enterAtEnd(of: "```\n  - a").text == "```\n  - a\n  ")
      #expect(enterAtEnd(of: "```\n  - ").text == "```\n  - \n  ")
      #expect(enterAtEnd(of: "```\n    ").text == "```\n    \n    ")
      // コードブロックの後のリスト行では項目を続ける。
      #expect(enterAtEnd(of: "```\nx\n```\n- a").text == "```\nx\n```\n- a\n- ")
    }

    // CR と CRLF は、エディタの本文 (Document) が LF に揃えるので本文に残らない。
    @Test(arguments: ["\u{2029}", "\u{2028}", "\u{0C}", "\u{85}"])
    func 改行以外の行の区切りも表示と同じく行を分ける(separator: String) {
      #expect(enterAtEnd(of: "- a" + separator + "    - ").text == "- a" + separator + "- ")
      #expect(enterAtEnd(of: "  a" + separator + "1. b").text == "  a" + separator + "1. b\n2. ")
      // ふつうの改行で引き継ぐ空白も、区切りの後の行頭から数える。
      #expect(enterAtEnd(of: "  a" + separator + "b").text == "  a" + separator + "b\n")
      #expect(enterAtEnd(of: "a" + separator + "  b").text == "a" + separator + "  b\n  ")
    }

    // MARK: - 複数カーソル

    @Test func 複数カーソルではカーソルごとに当てる() {
      let (view, _) = makeEditor(text: "- a\n1. b\nc")
      view.select([caret(3), caret(8), caret(10)], primary: 0)
      enter(view)
      #expect(view.text == "- a\n- \n1. b\n2. \nc\n")
      #expect(ranges(view) == [caret(6), caret(15), caret(18)])
    }

    @Test func 項目を続けるカーソルと1段戻るカーソルが混ざってもそれぞれに当てる() {
      let (view, _) = makeEditor(text: "- a\n    - \n  ")
      view.select([caret(3), caret(10), caret(13)], primary: 0)
      enter(view)
      #expect(view.text == "- a\n- \n- \n")
      #expect(ranges(view) == [caret(6), caret(9), caret(10)])
      view.undo(nil)
      #expect(view.text == "- a\n    - \n  ")
      #expect(ranges(view) == [caret(3), caret(10), caret(13)])
    }

    @Test func 同じ行の1段戻る操作は1回だけ当てほかのカーソルもその行に移す() {
      let (view, _) = makeEditor(text: "- a\n        - ")
      view.select([caret(4), caret(8), caret(14)], primary: 0)
      enter(view)
      #expect(view.text == "- a\n    - ")
      #expect(ranges(view).allSatisfy { $0 == caret(10) })
    }

    @Test(arguments: [
      // 行への操作の行に一部だけ掛かる選択。
      ("ab\n    ", [NSRange(location: 1, length: 4), NSRange(location: 7, length: 0)],
       "a\n  \n    ", [2, 9]),
      // 行への操作の行の手前で終わり、その行の文字を残る行として見た選択。
      ("abc\n    ", [NSRange(location: 0, length: 4), NSRange(location: 8, length: 0)],
       "\n    \n    ", [1, 10]),
      ("- foo\n    - ", [NSRange(location: 5, length: 1), NSRange(location: 12, length: 0)],
       "- foo\n    - \n    ", [6, 17]),
      // 行への操作の行の行末から先へ伸びる選択。
      ("- a\n    - [x] y\nz", [NSRange(location: 14, length: 1), NSRange(location: 15, length: 1)],
       "- a\n    - [x] \n    \n    z", [19, 24]),
    ])
    func ほかの選択が行への操作の行を見て決めたならどの選択もふつうに改行する(
      text: String, selections: [NSRange], expected: String, carets: [Int]
    ) {
      let (view, _) = makeEditor(text: text)
      view.select(selections, primary: 0)
      enter(view)
      #expect(view.text == expected)
      #expect(ranges(view) == carets.map(caret))
    }

    @Test func 行への操作と別の行だけを見た選択はそれぞれに当てる() {
      let (view, _) = makeEditor(text: "- a\nb\n    - ")
      view.select([NSRange(location: 3, length: 2), caret(12)], primary: 0)
      enter(view)
      #expect(view.text == "- a\n- \n- ")
      #expect(ranges(view) == [caret(6), caret(9)])

      // 同じ行を見た、改行を入れる選択どうしは重ならないのでそれぞれに当てる。
      let (same, _) = makeEditor(text: "- ab\n    - ")
      same.select([caret(3), caret(4), caret(11)], primary: 0)
      enter(same)
      #expect(same.text == "- a\n- b\n- \n- ")
      #expect(ranges(same) == [caret(6), caret(10), caret(13)])
    }

    // MARK: - Undo

    @Test func 項目を続けるEnterは打鍵とまとめて取り消す() {
      let (view, _) = makeEditor(text: "- a")
      view.select([caret(3)], primary: 0)
      type("b", into: view)
      enter(view)
      type("c", into: view)
      #expect(view.text == "- ab\n- c")
      view.undo(nil)
      #expect(view.text == "- a")
      #expect(ranges(view) == [caret(3)])
    }

    @Test func 改行しないEnterはそれだけで1回の取り消しになる() {
      let (view, _) = makeEditor(text: "- a")
      view.select([caret(3)], primary: 0)
      enter(view)
      view.doCommand(by: #selector(NSResponder.insertTab(_:)))
      #expect(view.text == "- a\n    - ")
      enter(view)
      #expect(view.text == "- a\n- ")
      enter(view)
      #expect(view.text == "- a\n")
      type("b", into: view)
      #expect(view.text == "- a\nb")
      view.undo(nil)
      #expect(view.text == "- a\n")
      view.undo(nil)
      #expect(view.text == "- a\n- ")
      #expect(ranges(view) == [caret(6)])
      view.undo(nil)
      #expect(view.text == "- a\n    - ")
      #expect(ranges(view) == [caret(10)])
      view.undo(nil)
      #expect(view.text == "- a\n- ")
      view.undo(nil)
      #expect(view.text == "- a")

      let (blank, _) = makeEditor(text: "    a")
      blank.select([caret(5)], primary: 0)
      enter(blank)
      enter(blank)
      #expect(blank.text == "    a\n")
      blank.undo(nil)
      #expect(blank.text == "    a\n    ")
      #expect(ranges(blank) == [caret(10)])
      blank.undo(nil)
      #expect(blank.text == "    a")
      #expect(!blank.document.canUndo)
    }

    // MARK: - 日本語入力

    @Test func 変換中のEnterは本文を変えない() {
      for text in ["- a", "    - ", "    "] {
        let (view, _) = makeEditor(text: text)
        let end = length(text)
        view.select([caret(end)], primary: 0)
        view.setMarkedText("か", selectedRange: caret(1), replacementRange: caret(NSNotFound))
        for command in [
          #selector(NSResponder.insertNewline(_:)),
          #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
          #selector(NSResponder.insertLineBreak(_:)),
          #selector(NSResponder.insertParagraphSeparator(_:)),
        ] {
          view.doCommand(by: command)
          #expect(view.text == text + "か")
          #expect(view.hasMarkedText())
          #expect(view.markedRange() == NSRange(location: end, length: 1))
        }
      }
    }
  }
}
