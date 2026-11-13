import AppKit
import EditorEngine
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったウィンドウとコントローラもテストの間は生かしておく。
private var retainedEditors: [(NSWindow, EditorTextController)] = []

extension AppKitTests {
  /// 選択中に記号を打つと選択を囲む。文字はキーと同じく文字入力の経路 (`insertText`) で入れる。
  struct SurroundSelectionTests {
    private func makeEditor(text: String) -> (NSWindow, EditorView) {
      let controller = EditorTextController(state: makeState(text: text))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = controller.scrollView
      controller.editorView.setFrameSize(controller.scrollView.contentSize)
      window.makeFirstResponder(controller.editorView)
      window.orderFront(nil)
      retainedEditors.append((window, controller))
      return (window, controller.editorView)
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    private func ranges(_ view: EditorView) -> [NSRange] {
      view.session.selections.map { view.nsRange(of: $0.range) }
    }

    private func type(_ text: String, into view: EditorView) {
      view.insertText(text, replacementRange: caret(NSNotFound))
    }

    /// 一文字ずつ打鍵の経路で入れ、打鍵ごとにメインアクターを明け渡す。自動置換はその間に
    /// メインキューで行われる。
    private func typeSlowly(_ text: String, into view: EditorView) async {
      for character in text {
        type(String(character), into: view)
        try? await Task.sleep(for: .milliseconds(100))
      }
    }

    /// `text` の `selected` を選んで `symbol` を打ったエディタ。
    private func surround(_ text: String, selecting selected: NSRange, with symbol: String)
      -> (NSWindow, EditorView)
    {
      let (window, view) = makeEditor(text: text)
      view.select([selected], primary: 0)
      type(symbol, into: view)
      return (window, view)
    }

    // MARK: - 囲む

    @Test(arguments: [
      ("`", "`"), ("*", "*"), ("_", "_"), ("~", "~"), ("(", ")"), ("[", "]"), ("{", "}"),
      ("\"", "\""), ("'", "'"),
    ])
    func 選択中に記号を打つと選択を囲み中身を選んだまま保つ(open: String, close: String) {
      let (window, view) = surround("ab cd ef", selecting: NSRange(location: 3, length: 2), with: open)
      defer { window.close() }
      #expect(view.text == "ab \(open)cd\(close) ef")
      #expect(ranges(view) == [NSRange(location: 4, length: 2)])
    }

    @Test func 続けて打つと二重に囲む() {
      let (window, view) = surround("太字", selecting: NSRange(location: 0, length: 2), with: "*")
      defer { window.close() }
      type("*", into: view)
      #expect(view.text == "**太字**")
      #expect(ranges(view) == [NSRange(location: 2, length: 2)])
      type("(", into: view)
      #expect(view.text == "**(太字)**")
      #expect(ranges(view) == [NSRange(location: 3, length: 2)])
    }

    @Test func 後ろ向きの選択は向きを保つ() throws {
      let (window, view) = makeEditor(text: "ab cd")
      defer { window.close() }
      let snapshot = view.document.snapshot
      try view.session.setSelections([
        Selection(anchor: try snapshot.position(at: 5), head: try snapshot.position(at: 3))
      ])
      type("[", into: view)
      #expect(view.text == "ab [cd]")
      let selection = view.session.primarySelection
      #expect(view.offset(of: selection.anchor) == 6)
      #expect(view.offset(of: selection.head) == 4)
    }

    @Test func 複数の選択はそれぞれ囲みキャレットには文字を入れる() {
      let (window, view) = makeEditor(text: "one two\nthree")
      defer { window.close() }
      view.select(
        [NSRange(location: 0, length: 3), caret(7), NSRange(location: 8, length: 5)], primary: 1)
      type("(", into: view)
      #expect(view.text == "(one) two(\n(three)")
      #expect(ranges(view) == [NSRange(location: 1, length: 3), caret(10), NSRange(location: 12, length: 5)])
      #expect(view.session.primaryIndex == 1)
    }

    @Test func 隣り合う選択はそれぞれ囲む() {
      let (window, view) = makeEditor(text: "ab")
      defer { window.close() }
      view.select([NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)], primary: 0)
      #expect(ranges(view).count == 2)
      type("(", into: view)
      #expect(view.text == "(a)(b)")
      #expect(ranges(view) == [NSRange(location: 1, length: 1), NSRange(location: 4, length: 1)])
    }

    // MARK: - 対象外

    @Test func 選択がなければ記号だけを入れ閉じ記号を補完しない() {
      let (window, view) = makeEditor(text: "ab")
      defer { window.close() }
      view.select([caret(1), caret(2)], primary: 0)
      type("x", into: view)
      type("(", into: view)
      #expect(view.text == "ax(bx(")
      #expect(ranges(view) == [caret(3), caret(6)])
      // 今までどおり打鍵のまとまりに入る。
      view.undo(nil)
      #expect(view.text == "ab")
    }

    @Test(arguments: ["x", "<", "（", "＊", "**", "「"])
    func 囲む記号1文字でなければ選択を置き換える(text: String) {
      let (window, view) = surround("ab cd", selecting: NSRange(location: 3, length: 2), with: text)
      defer { window.close() }
      #expect(view.text == "ab \(text)")
      #expect(ranges(view) == [caret(3 + (text as NSString).length)])
    }

    @Test(arguments: ["(", "（"])
    func 変換の確定で入る文字は選択を囲まない(text: String) {
      let (window, view) = makeEditor(text: "ab cd")
      defer { window.close() }
      view.select([NSRange(location: 3, length: 2)], primary: 0)
      view.setMarkedText(text, selectedRange: caret(1), replacementRange: caret(NSNotFound))
      #expect(view.hasMarkedText())
      type(text, into: view)
      #expect(!view.hasMarkedText())
      #expect(view.text == "ab \(text)")
      #expect(ranges(view) == [caret(4)])
    }

    @Test func 入力メソッドが置換範囲を指定した入力は選択を囲まない() {
      let (window, view) = makeEditor(text: "ab cd")
      defer { window.close() }
      view.select([NSRange(location: 3, length: 2)], primary: 0)
      view.insertText("*", replacementRange: NSRange(location: 3, length: 2))
      #expect(view.text == "ab *")
    }

    @Test func 貼り付けた記号は選択を置き換える() {
      let pasteboard = NSPasteboard(name: NSPasteboard.Name("ediro.test.surround"))
      defer { pasteboard.releaseGlobally() }
      pasteboard.clearContents()
      pasteboard.setString("*", forType: .string)
      let (window, view) = makeEditor(text: "ab cd")
      defer { window.close() }
      view.select([NSRange(location: 3, length: 2)], primary: 0)
      view.paste(from: pasteboard)
      #expect(view.text == "ab *")
    }

    // MARK: - Undo

    @Test func 囲む操作はそれだけで1回の取り消しになる() {
      let (window, view) = makeEditor(text: "ab")
      defer { window.close() }
      view.select([caret(2)], primary: 0)
      type("c", into: view)
      view.select([NSRange(location: 0, length: 3)], primary: 0)
      type("*", into: view)
      type("*", into: view)
      // 囲んだ後の打鍵も、囲む操作とまとまらない。
      type("d", into: view)
      type("e", into: view)
      #expect(view.text == "**de**")
      view.undo(nil)
      #expect(view.text == "**abc**")
      #expect(ranges(view) == [NSRange(location: 2, length: 3)])
      view.undo(nil)
      #expect(view.text == "*abc*")
      #expect(ranges(view) == [NSRange(location: 1, length: 3)])
      view.undo(nil)
      #expect(view.text == "abc")
      #expect(ranges(view) == [NSRange(location: 0, length: 3)])
      view.undo(nil)
      #expect(view.text == "ab")
    }

    @Test func 囲む操作の取り消しの名前は打鍵と同じ() {
      let (window, view) = makeEditor(text: "ab")
      defer { window.close() }
      view.select([NSRange(location: 0, length: 1)], primary: 0)
      type("x", into: view)
      let typing = view.undoManager?.undoActionName
      #expect(typing?.isEmpty == false)
      view.select([NSRange(location: 0, length: 2)], primary: 0)
      type("*", into: view)
      #expect(view.text == "*xb*")
      #expect(view.undoManager?.undoActionName == typing)
      view.select([caret(0), NSRange(location: 1, length: 2)], primary: 0)
      type("*", into: view)
      #expect(view.text == "***xb**")
      #expect(view.undoManager?.undoActionName == typing)
    }

    @Test func キャレットと選択が混じる囲む操作も1回で取り消す() {
      let (window, view) = makeEditor(text: "a b")
      defer { window.close() }
      view.select([caret(1)], primary: 0)
      type("x", into: view)
      view.select([caret(2), NSRange(location: 3, length: 1)], primary: 0)
      type("_", into: view)
      #expect(view.text == "ax_ _b_")
      view.undo(nil)
      #expect(view.text == "ax b")
      #expect(ranges(view) == [caret(2), NSRange(location: 3, length: 1)])
      view.redo(nil)
      #expect(view.text == "ax_ _b_")
      #expect(ranges(view) == [caret(3), NSRange(location: 5, length: 1)])
    }

    // MARK: - 自動置換

    @Test(arguments: ["\"", "'"])
    func 囲んだ引用符は自動置換せず続けて打っても置き換えない(quote: String) async {
      // 引用符の形はユーザーの引用符の設定と言語で変わるので、英語の本文に使う形を求める。
      let quotes = NSSpellChecker.shared.userQuotesArray(forLanguage: "en")
      let opening = quote == "\"" ? quotes[0] : quotes[2]
      let (window, view) = makeEditor(text: "say hi now")
      defer { window.close() }
      view.isAutomaticQuoteSubstitutionEnabled = true
      view.select([NSRange(location: 4, length: 2)], primary: 0)
      await typeSlowly(quote, into: view)
      // 別の位置に打った引用符が置き換わるまで待ち、囲んだ引用符が置き換わらないことを確かめる。
      view.select([caret(0)], primary: 0)
      await typeSlowly("\(quote)a ", into: view)
      #expect(await waitUntil({ view.text.hasPrefix(opening) }, timeout: .seconds(2)))
      #expect(view.text == "\(opening)a say \(quote)hi\(quote) now")
      // 選択した中身を打鍵で置き換え、閉じ記号の前に打ち続ける。その後、末尾に打った引用符が
      // 置き換わるまで待ち、囲んだ引用符が置き換わらないことを確かめる。
      view.select([NSRange(location: 8, length: 2)], primary: 0)
      await typeSlowly("it is ", into: view)
      view.select([caret((view.text as NSString).length)], primary: 0)
      await typeSlowly(" \(quote)b", into: view)
      #expect(await waitUntil({ view.text.hasSuffix("\(opening)b") }, timeout: .seconds(2)))
      #expect(view.text == "\(opening)a say \(quote)it is \(quote) now \(opening)b")
    }

    @Test func キャレットに入れた引用符は自動置換し囲んだ引用符はしない() async {
      let quotes = NSSpellChecker.shared.userQuotesArray(forLanguage: "en")
      let (window, view) = makeEditor(text: "one two")
      defer { window.close() }
      view.isAutomaticQuoteSubstitutionEnabled = true
      view.select([caret(0), NSRange(location: 4, length: 3)], primary: 0)
      await typeSlowly("\"", into: view)
      #expect(
        await waitUntil({ view.text == "\(quotes[0])one \"two\"" }, timeout: .seconds(2)))
      // 置き換えた後も、囲んだ引用符は残る。
      try? await Task.sleep(for: .milliseconds(300))
      #expect(view.text == "\(quotes[0])one \"two\"")
    }
  }
}
