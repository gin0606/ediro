import AppKit
import EdiroCore
import EditorEngine
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったコントローラもテストの間は生かしておく。
private var retainedControllers: [EditorTextController] = []

extension AppKitTests {
  /// Tab と Shift+Tab の字下げ・字上げ。キーと同じくコマンド (`insertTab:` / `insertBacktab:`)
  /// で送る。
  struct IndentationCommandTests {
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

    private func tab(_ view: EditorView) {
      view.doCommand(by: #selector(NSResponder.insertTab(_:)))
    }

    private func backtab(_ view: EditorView) {
      view.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
    }

    private func type(_ text: String, into view: EditorView) {
      view.insertText(text, replacementRange: caret(NSNotFound))
    }

    // MARK: - Tab: 行単位の操作にならない場合

    @Test func リストでない行ではキャレットの位置にスペースをTabSize個入れる() {
      let (view, _) = makeEditor(text: "abc")
      view.select([caret(3)], primary: 0)
      tab(view)
      // 桁はそろえない。3 桁目でも 4 個入れる。
      #expect(view.text == "abc    ")
      #expect(ranges(view) == [caret(7)])

      let (two, _) = makeEditor(text: "ab", tabSize: 2)
      two.select([caret(1)], primary: 0)
      tab(two)
      #expect(two.text == "a  b")
      #expect(ranges(two) == [caret(3)])
    }

    @Test func InsertSpacesがオフならタブ文字を入れる() {
      let (view, _) = makeEditor(text: "ab", insertSpaces: false)
      view.select([caret(1)], primary: 0)
      tab(view)
      #expect(view.text == "a\tb")
      #expect(ranges(view) == [caret(2)])
    }

    @Test func リストでない行の1行の中の選択は1段で置き換える() {
      let (view, _) = makeEditor(text: "abcd")
      view.select([NSRange(location: 1, length: 2)], primary: 0)
      tab(view)
      #expect(view.text == "a    d")
      #expect(ranges(view) == [caret(5)])
    }

    @Test func 設定の変更がTabで入る字下げに伝わる() async {
      let (view, state) = makeEditor(text: "")
      state.preferences.insertSpaces = false
      #expect(await waitUntil { view.indentUnit == IndentUnit(tabSize: 4, insertSpaces: false) })
      tab(view)
      #expect(view.text == "\t")
      state.preferences.insertSpaces = true
      state.preferences.tabSize = 2
      #expect(await waitUntil { view.indentUnit == IndentUnit(tabSize: 2, insertSpaces: true) })
      tab(view)
      #expect(view.text == "\t  ")
    }

    // MARK: - Tab: 行単位の操作

    @Test(arguments: ["- item", "* item", "+ item", "12. item", "- [ ] item", "- [x] item", "  - item"])
    func リスト行ではキャレットの位置によらず行頭に1段足しマーカーは変えない(line: String) {
      let length = (line as NSString).length
      for location in [0, length - 2, length] {
        let (view, _) = makeEditor(text: "前の行\n" + line)
        view.select([caret(4 + location)], primary: 0)
        tab(view)
        #expect(view.text == "前の行\n    " + line)
        // 同じ文字の位置に保つ。行頭のキャレットも行の先頭の文字の前に付いていく。
        #expect(ranges(view) == [caret(8 + location)])
      }
    }

    @Test func リスト行の中の選択は行頭に1段足して同じ文字を選んだままにする() {
      let (view, _) = makeEditor(text: "1. one", insertSpaces: false)
      view.select([NSRange(location: 3, length: 3)], primary: 0)
      tab(view)
      #expect(view.text == "\t1. one")
      #expect(ranges(view) == [NSRange(location: 4, length: 3)])
    }

    @Test func 改行を含む選択は掛かっている各行に足し空行には足さない() {
      let (view, _) = makeEditor(text: "a\nb\n\nc")
      view.select([NSRange(location: 0, length: 6)], primary: 0)
      tab(view)
      #expect(view.text == "    a\n    b\n\n    c")
      #expect(ranges(view) == [NSRange(location: 4, length: 14)])
    }

    @Test func 改行で終わる1行ぶんの選択はその行だけに足す() {
      let (view, _) = makeEditor(text: "ab\ncd")
      view.select([NSRange(location: 0, length: 3)], primary: 0)
      tab(view)
      #expect(view.text == "    ab\ncd")
      #expect(ranges(view) == [NSRange(location: 4, length: 3)])
    }

    @Test func 選択の終わりが行頭にある複数行の選択はその行を含めない() {
      let (view, _) = makeEditor(text: "ab\ncd\nef")
      view.select([NSRange(location: 1, length: 5)], primary: 0)
      tab(view)
      #expect(view.text == "    ab\n    cd\nef")
      #expect(ranges(view) == [NSRange(location: 5, length: 9)])
    }

    @Test func 後ろ向きの選択も向きを保ったまま行に足す() throws {
      let (view, _) = makeEditor(text: "ab\ncd")
      try view.session.setSelections(
        [Selection(anchor: view.position(of: 4), head: view.position(of: 1))], primary: 0)
      tab(view)
      #expect(view.text == "    ab\n    cd")
      let after = view.session.primarySelection
      #expect(view.offset(of: after.anchor) == 12 && view.offset(of: after.head) == 5)
    }

    @Test func コードブロックの中のリストに見える行はリスト行として扱わない() {
      let text = "```\n- a\n```"
      let (view, _) = makeEditor(text: text)
      view.select([caret(7)], primary: 0)
      tab(view)
      #expect(view.text == "```\n- a    \n```")
      #expect(ranges(view) == [caret(11)])

      // 字下げ自体は働く。
      let (lines, _) = makeEditor(text: text)
      lines.select([NSRange(location: 4, length: 4)], primary: 0)
      tab(lines)
      #expect(lines.text == "```\n    - a\n```")
      backtab(lines)
      #expect(lines.text == text)
    }

    @Test func 複数カーソルではカーソルごとに当て同じ行には1回だけ足す() {
      let (view, _) = makeEditor(text: "- ab\nc\n- d")
      view.select([caret(2), caret(3), caret(6), caret(10)], primary: 0)
      tab(view)
      // 1 行目は 2 つのキャレットがあっても 1 段だけ。2 行目はリストでないのでキャレットの位置に入れる。
      #expect(view.text == "    - ab\nc    \n    - d")
      #expect(ranges(view) == [caret(6), caret(7), caret(14), caret(22)])
      view.undo(nil)
      #expect(view.text == "- ab\nc\n- d")
      #expect(ranges(view) == [caret(2), caret(3), caret(6), caret(10)])
    }

    @Test func 行単位の操作の行にあるキャレットは行の字下げだけにする() {
      let (view, _) = makeEditor(text: "ab\ncd")
      view.select([NSRange(location: 0, length: 4), caret(5)], primary: 0)
      tab(view)
      #expect(view.text == "    ab\n    cd")
      #expect(ranges(view) == [NSRange(location: 4, length: 8), caret(13)])
    }

    @Test func 行単位の操作と混ざってもリストでない行の選択は1段で置き換える() {
      let (view, _) = makeEditor(text: "- a\nbcd")
      view.select([caret(3), NSRange(location: 5, length: 1)], primary: 0)
      tab(view)
      #expect(view.text == "    - a\nb    d")
      #expect(ranges(view) == [caret(7), caret(13)])
    }

    @Test func コードブロックの前後のリスト行には行頭に1段足す() {
      let (view, _) = makeEditor(text: "- a\n```\nx\n```\n- b")
      view.select([caret(1), caret(15)], primary: 0)
      tab(view)
      #expect(view.text == "    - a\n```\nx\n```\n    - b")
    }

    // CR と CRLF は、エディタの本文 (Document) が LF に揃えるので本文に残らない。
    @Test(arguments: ["\u{2029}", "\u{2028}", "\u{0C}", "\u{85}"])
    func 改行以外の行の区切りも表示と同じく行を分ける(separator: String) {
      let length = (separator as NSString).length
      // 区切りを跨ぐ選択は、選択を消さずに両方の行に足す。
      let (lines, _) = makeEditor(text: "ab" + separator + "cd")
      lines.select([NSRange(location: 1, length: 2 + length)], primary: 0)
      tab(lines)
      #expect(lines.text == "    ab" + separator + "    cd")
      // 後ろの行のリスト行には、その行の行頭に足す。
      let (list, _) = makeEditor(text: "- a" + separator + "- b")
      list.select([caret(5 + length)], primary: 0)
      tab(list)
      #expect(list.text == "- a" + separator + "    - b")
      // 後ろの行の字上げは、その行から消す。
      let (outdented, _) = makeEditor(text: "  a" + separator + "  b")
      outdented.select([caret(5 + length)], primary: 0)
      backtab(outdented)
      #expect(outdented.text == "  a" + separator + "b")
      #expect(ranges(outdented) == [caret(3 + length)])
    }

    @Test func 段落の末尾の改ページなどの直後はキャレットを描く位置と同じく空の行にある() {
      for separator in ["\u{0C}", "\u{2028}", "\u{85}"] {
        let (list, _) = makeEditor(text: "- a" + separator)
        #expect(list.caretFrame(at: 4).minY > list.caretFrame(at: 3).minY)
        list.select([caret(4)], primary: 0)
        tab(list)
        #expect(list.text == "- a" + separator + "    ")
        #expect(ranges(list) == [caret(8)])

        let (beforeBreak, _) = makeEditor(text: "  a" + separator + "\nb")
        beforeBreak.select([caret(4)], primary: 0)
        backtab(beforeBreak)
        #expect(beforeBreak.text == "  a" + separator + "\nb")

        // 区切りの文字で終わる選択は改行を含むので、リストでない行も行単位で字下げする。
        let (line, _) = makeEditor(text: "ab" + separator + "\ncd")
        line.select([NSRange(location: 0, length: 3)], primary: 0)
        tab(line)
        #expect(line.text == "    ab" + separator + "\ncd")
        #expect(ranges(line) == [NSRange(location: 4, length: 3)])

        let (all, _) = makeEditor(text: "ab" + separator)
        all.selectAll(nil)
        tab(all)
        #expect(all.text == "    ab" + separator)

        // その位置を跨ぐ選択は、前後の行に足し、間の空の行には足さない。
        let (lines, _) = makeEditor(text: "a" + separator + "\nb")
        lines.select([NSRange(location: 0, length: 4)], primary: 0)
        tab(lines)
        #expect(lines.text == "    a" + separator + "\n    b")
        #expect(ranges(lines) == [NSRange(location: 4, length: 8)])
      }
    }

    @Test func ほかのカーソルが字下げした行の行頭で終わる選択は足した字下げまで広がらない() {
      let (view, _) = makeEditor(text: "ab\n- c")
      view.select([NSRange(location: 0, length: 3), caret(6)], primary: 0)
      tab(view)
      #expect(view.text == "    ab\n    - c")
      #expect(ranges(view) == [NSRange(location: 4, length: 3), caret(14)])
    }

    @Test func OptionTabは設定によらずタブ文字を入れる() {
      let (view, _) = makeEditor(text: "- a")
      view.select([caret(3)], primary: 0)
      view.doCommand(by: #selector(NSResponder.insertTabIgnoringFieldEditor(_:)))
      #expect(view.text == "- a\t")
      #expect(ranges(view) == [caret(4)])
    }

    // MARK: - Shift+Tab

    @Test(arguments: [
      ("    ab", "ab"), ("      ab", "  ab"), ("  ab", "ab"), ("\tab", "ab"), ("\t\tab", "\tab"),
      ("  \tab", "\tab"), ("\t  ab", "  ab"), (" \t ab", "\t ab"), ("ab", "ab"), ("", ""),
    ])
    func 字上げは行頭のタブ文字1つかスペース最大TabSize個を消す(line: String, expected: String) {
      for insertSpaces in [true, false] {
        let (view, _) = makeEditor(text: line, insertSpaces: insertSpaces)
        let length = (line as NSString).length
        view.select([caret(length)], primary: 0)
        backtab(view)
        #expect(view.text == expected)
        #expect(ranges(view) == [caret((expected as NSString).length)])
      }
    }

    @Test func 字上げはTabSizeの設定に従う() {
      let (view, _) = makeEditor(text: "    ab", tabSize: 2)
      view.select([caret(6)], primary: 0)
      backtab(view)
      #expect(view.text == "  ab")
    }

    @Test func 字上げはマーカーを変えずカーソルを同じ文字の位置に保つ() {
      let (view, _) = makeEditor(text: "        - [ ] a")
      view.select([NSRange(location: 10, length: 3)], primary: 0)
      backtab(view)
      #expect(view.text == "    - [ ] a")
      #expect(ranges(view) == [NSRange(location: 6, length: 3)])
      // 消した空白の中のキャレットは行頭に移る。
      view.select([caret(2)], primary: 0)
      backtab(view)
      #expect(view.text == "- [ ] a")
      #expect(ranges(view) == [caret(0)])
    }

    @Test func 改行を含む選択は掛かっている各行から消し字下げのない行はそのまま() {
      let (view, _) = makeEditor(text: "    a\nb\n\t\tc\n    d")
      view.select([NSRange(location: 2, length: 10)], primary: 0)
      backtab(view)
      // 選択の終わり (4 行目の行頭) の行は含めない。
      #expect(view.text == "a\nb\n\tc\n    d")
      #expect(ranges(view) == [NSRange(location: 0, length: 7)])
    }

    @Test func 改行で終わる1行ぶんの選択はその行だけから消す() {
      let (view, _) = makeEditor(text: "    ab\n    cd")
      view.select([NSRange(location: 0, length: 7)], primary: 0)
      backtab(view)
      #expect(view.text == "ab\n    cd")
      #expect(ranges(view) == [NSRange(location: 0, length: 3)])
    }

    @Test func 字上げは複数カーソルの同じ行に1回だけ当てる() {
      let (view, _) = makeEditor(text: "        ab\n\tcd\nef")
      view.select([caret(9), caret(10), caret(13), caret(16)], primary: 0)
      backtab(view)
      #expect(view.text == "    ab\ncd\nef")
      #expect(ranges(view) == [caret(5), caret(6), caret(8), caret(11)])
      view.undo(nil)
      #expect(view.text == "        ab\n\tcd\nef")
      #expect(ranges(view) == [caret(9), caret(10), caret(13), caret(16)])
    }

    // MARK: - Undo

    @Test func 行単位の字下げと字上げはそれだけで1回の取り消しになる() {
      let (view, _) = makeEditor(text: "- a")
      view.select([caret(3)], primary: 0)
      type("b", into: view)
      tab(view)
      type("c", into: view)
      #expect(view.text == "    - abc")
      view.undo(nil)
      #expect(view.text == "    - ab")
      view.undo(nil)
      #expect(view.text == "- ab")
      #expect(ranges(view) == [caret(4)])
      view.undo(nil)
      #expect(view.text == "- a")

      let (outdented, _) = makeEditor(text: "    - a")
      outdented.select([caret(7)], primary: 0)
      type("b", into: outdented)
      backtab(outdented)
      #expect(outdented.text == "- ab")
      outdented.undo(nil)
      #expect(outdented.text == "    - ab")
      #expect(ranges(outdented) == [caret(8)])

      let (lines, _) = makeEditor(text: "    a\n    b")
      lines.selectAll(nil)
      backtab(lines)
      #expect(lines.text == "a\nb")
      tab(lines)
      #expect(lines.text == "    a\n    b")
      lines.undo(nil)
      #expect(lines.text == "a\nb")
      lines.undo(nil)
      #expect(lines.text == "    a\n    b")
      #expect(!lines.document.canUndo)
    }

    @Test func リストでない行のTabは打鍵とまとめて取り消す() {
      let (view, _) = makeEditor(text: "")
      type("a", into: view)
      tab(view)
      type("b", into: view)
      #expect(view.text == "a    b")
      view.undo(nil)
      #expect(view.text == "")
    }

    // MARK: - 日本語入力

    @Test func 変換中のTabとShiftTabは本文を変えない() {
      let (view, state) = makeEditor(text: "    - a")
      view.select([caret(7)], primary: 0)
      view.setMarkedText("か", selectedRange: caret(1), replacementRange: caret(NSNotFound))
      for command in [#selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:))] {
        view.doCommand(by: command)
        #expect(view.text == "    - aか")
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 7, length: 1))
      }
      #expect(state.text == "    - a")
    }
  }
}
