import AppKit
import ObjectiveC
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったコントローラもテストの間は生かしておく。
private var retainedControllers: [EditorTextController] = []

/// 本文と選択から始めて、コマンドを順に送る操作の筋書き。
nonisolated struct CommandScenario: CustomTestStringConvertible, Sendable {
  enum Step: Sendable {
    /// `doCommand(by:)` で送るセレクタ。
    case command(String)
    /// 打鍵と同じ `insertText(_:replacementRange:)`。
    case type(String)
    case select(NSRange)
  }

  let text: String
  let selection: NSRange
  let steps: [Step]
  let expectedText: String
  let expectedSelection: NSRange

  init(
    _ text: String, _ location: Int, _ length: Int, _ steps: Step...,
    then expectedText: String, _ expectedLocation: Int, _ expectedLength: Int
  ) {
    self.text = text
    self.selection = NSRange(location: location, length: length)
    self.steps = steps
    self.expectedText = expectedText
    self.expectedSelection = NSRange(location: expectedLocation, length: expectedLength)
  }

  var testDescription: String {
    let names = steps.map { step -> String in
      switch step {
      case .command(let name): name
      case .type(let text): "type(\(text.debugDescription))"
      case .select(let range): "select(\(range))"
      }
    }
    return "\(text.debugDescription) \(selection) \(names.joined(separator: " "))"
  }
}

nonisolated extension CommandScenario.Step: ExpressibleByStringLiteral {
  init(stringLiteral value: String) { self = .command(value) }
}

extension CommandScenario {
  @MainActor func run(on view: EditorView) {
    view.select([selection], primary: 0)
    for step in steps {
      switch step {
      case .command(let name): view.doCommand(by: NSSelectorFromString(name))
      case .type(let text):
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
      case .select(let range): view.select([range], primary: 0)
      }
    }
  }
}

extension AppKitTests {
  struct KeyBindingCommandTests {
    private func makeEditor(text: String, width: CGFloat = 400) -> EditorView {
      let controller = EditorTextController(state: makeState(text: text))
      controller.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 300)
      controller.editorView.setFrameSize(controller.scrollView.contentSize)
      retainedControllers.append(controller)
      return controller.editorView
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    private func ranges(_ view: EditorView) -> [NSRange] {
      view.session.selections.map { view.nsRange(of: $0.range) }
    }

    // MARK: - 単一の選択

    // 各行は、本文と選択 (位置, 長さ)、送るコマンド、then: の後に操作後の本文と選択を書く。
    // 値は置き換え前のエディタだった NSTextView の結果に合わせてある。ただし文字の区切りは
    // エンジンの書記素に合わせ、NSTextView と区切りが違う文字の行はそう断ってある。

    nonisolated static let transposeScenarios: [CommandScenario] = [
      .init("abcd", 2, 0, "transpose:", then: "acbd", 3, 0),
      .init("abcd", 0, 0, "transpose:", then: "abcd", 0, 0),
      .init("abcd", 4, 0, "transpose:", then: "abdc", 4, 0),
      .init("abcd", 1, 2, "transpose:", then: "abcd", 1, 2),
      .init("abcd", 2, 0, "transpose:", "transpose:", then: "acdb", 4, 0),
      .init("aaaa", 1, 0, "transpose:", then: "aaaa", 2, 0),
      .init("a", 1, 0, "transpose:", then: "a", 1, 0),
      .init("ab\ncd", 3, 0, "transpose:", then: "abc\nd", 4, 0),
      .init("ab\ncd", 2, 0, "transpose:", then: "ba\ncd", 2, 0),
      .init("ab\n\ncd", 3, 0, "transpose:", then: "a\nb\ncd", 3, 0),
      .init("a\ncd", 1, 0, "transpose:", then: "a\ncd", 1, 0),
      .init("\ncd", 1, 0, "transpose:", then: "c\nd", 2, 0),
      .init("a👍\u{1F3FD}b", 1, 0, "transpose:", then: "👍\u{1F3FD}ab", 5, 0),
      .init("a👍\u{1F3FD}b", 5, 0, "transpose:", then: "ab👍\u{1F3FD}", 6, 0),
      .init("ae\u{301}b", 3, 0, "transpose:", then: "abe\u{301}", 4, 0),
      .init("ok 👍", 5, 0, "transpose:", then: "ok 👍", 5, 0),
      .init("ae\u{301}", 3, 0, "transpose:", then: "ae\u{301}", 3, 0),
      .init("👍b", 3, 0, "transpose:", then: "b👍", 3, 0),
      // 合成文字の途中のキャレットは、その文字の前にあるものとして扱う。
      .init("xa\u{301}b", 2, 0, "transpose:", then: "a\u{301}xb", 3, 0),
      .init("ab\u{C}cd", 2, 0, "transpose:", then: "ba\u{C}cd", 2, 0),
      .init("ab\u{2028}cd", 2, 0, "transpose:", then: "ba\u{2028}cd", 2, 0),
      .init("ab\u{2029}cd", 2, 0, "transpose:", then: "ba\u{2029}cd", 2, 0),
      .init("ab\u{B}cd", 2, 0, "transpose:", then: "a\u{B}bcd", 3, 0),
      // 文字はエンジンの書記素で区切る。ทำ は NSString では 2 文字だが、エンジンでは 1 文字。
      .init("ทำx", 2, 0, "transpose:", then: "xทำ", 3, 0),
      .init("aทำ", 3, 0, "transpose:", then: "aทำ", 3, 0),
      .init("xทำb", 2, 0, "transpose:", then: "ทำxb", 3, 0),
      .init("x\u{0D4E}\u{0D15}", 1, 0, "transpose:", then: "\u{0D4E}\u{0D15}x", 3, 0),
      .init("ทำx", 3, 0, "transpose:", then: "xทำ", 3, 0),
      // x と ZWJ は、NSString では続く y と 1 文字だが、エンジンでは y と別の文字。
      .init("ax\u{200D}y", 3, 0, "transpose:", then: "ayx\u{200D}", 4, 0),
    ]

    nonisolated static let killScenarios: [CommandScenario] = [
      .init(
        "one two\nthree four\nfive", 2, 0, "deleteToEndOfParagraph:", "deleteToEndOfParagraph:",
        "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:",
        then: "on\nfivee two\nthree four", 23, 0),
      .init(
        "one two\nthree four\nfive", 2, 0, "deleteToEndOfParagraph:", "moveRight:",
        "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:",
        then: "on\n\nfivethree four", 18, 0),
      .init(
        "one two\nthree four\nfive", 2, 0, "deleteToEndOfParagraph:", "moveRight:", "moveLeft:",
        "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:",
        then: "onthree four\nfive\n", 18, 0),
      .init(
        "one two\nthree four\nfive", 2, 0, "deleteToEndOfParagraph:", "setMark:", "copy:",
        "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:",
        then: "onthree four\nfivee two\n", 23, 0),
      .init(
        "one two\nthree four\nfive", 0, 0, "deleteToEndOfParagraph:", .type("X"),
        "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:",
        then: "Xthree four\nfive\n", 17, 0),
      .init(
        "ab cd\nef gh\nij", 1, 0, "deleteToEndOfParagraph:", "scrollLineDown:",
        "centerSelectionInVisibleArea:", "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:",
        then: "aef gh\nijb cd\n", 14, 0),
      // 文字を消すだけの編集を挟んでも続き、選択を置き直すと元の位置でも続かない。
      .init(
        "one two\nthree", 2, 0, "deleteToEndOfParagraph:", "deleteBackward:",
        "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:", then: "othreee two\n", 12, 0),
      // リストのマーカーや字下げの 1 段を消す Backspace も、文字を消すだけの編集。
      .init(
        "    xy\nz", 4, 0, "deleteToEndOfParagraph:", "deleteBackward:", "deleteToEndOfParagraph:",
        "moveToEndOfDocument:", "yank:", then: "zxy\n", 4, 0),
      .init(
        "- xy\nz", 2, 0, "deleteToEndOfParagraph:", "deleteBackward:", "deleteToEndOfParagraph:",
        "moveToEndOfDocument:", "yank:", then: "zxy\n", 4, 0),
      .init(
        "one two\nthree", 2, 0, "deleteToEndOfParagraph:", "deleteWordBackward:",
        "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:", then: "threee two\n", 11, 0),
      .init(
        "one two\nthree", 4, 0, "deleteToEndOfParagraph:",
        "deleteBackwardByDecomposingPreviousCharacter:", "deleteToEndOfParagraph:",
        "moveToEndOfDocument:", "yank:", then: "onethreetwo\n", 12, 0),
      .init(
        "on\u{E9} two\nthree", 3, 0, "deleteToEndOfParagraph:",
        "deleteBackwardByDecomposingPreviousCharacter:", "deleteToEndOfParagraph:",
        "moveToEndOfDocument:", "yank:", then: "onethree two\n", 13, 0),
      .init(
        "one two\nthree", 2, 0, "deleteToEndOfParagraph:", .select(NSRange(location: 2, length: 0)),
        "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:", then: "onthree\n", 8, 0),
      .init(
        "one two\nthree", 2, 0, "deleteToEndOfParagraph:", "moveToEndOfParagraph:",
        "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:", then: "onthree\n", 8, 0),
      .init(
        "ab cd\nef gh\nij", 1, 0, "deleteToEndOfLine:", "deleteToEndOfLine:",
        "moveToEndOfDocument:", "yank:", then: "aef gh\nij\nb cd", 14, 0),
      .init(
        "ab cd\nef gh\nij", 1, 0, "deleteToEndOfParagraph:", "deleteToEndOfLine:",
        "moveToEndOfDocument:", "yank:", then: "aef gh\nij\n", 10, 0),
      .init(
        "ab cd\nef gh\nij", 4, 0, "deleteToBeginningOfParagraph:", "deleteToEndOfParagraph:",
        "moveToEndOfDocument:", "yank:", then: "\nef gh\nijd", 10, 0),
      .init(
        "ab cd\nef gh\nij", 4, 0, "setMark:", .select(NSRange(location: 1, length: 0)),
        "deleteToMark:", "deleteToEndOfLine:", "moveToEndOfDocument:", "yank:",
        then: "a\nef gh\nijdb c", 14, 0),
      .init(
        "ab cd\nef gh\nij", 4, 0, "setMark:", .select(NSRange(location: 1, length: 0)),
        "deleteToMark:", "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:",
        then: "a\nef gh\nijd", 11, 0),
      .init(
        "one two\nthree four\nfive", 6, 0, "deleteToBeginningOfLine:", "moveToEndOfDocument:",
        "yank:", then: "o\nthree four\nfiveone tw", 23, 0),
      .init(
        "one two\nthree four\nfive", 10, 0, "deleteToBeginningOfParagraph:", "moveToEndOfDocument:",
        "yank:", then: "one two\nree four\nfiveth", 23, 0),
      .init(
        "one two\nthree four\nfive", 0, 3, "deleteToEndOfParagraph:", "moveToEndOfDocument:",
        "yank:", then: " two\nthree four\nfiveone", 23, 0),
      .init(
        "one two\nthree four\nfive", 4, 0, "deleteToEndOfParagraph:", "moveToEndOfDocument:",
        "yank:", "yank:", then: "one \nthree four\nfivetwotwo", 26, 0),
      .init(
        "one two\nthree four\nfive", 4, 0, "deleteToEndOfParagraph:",
        .select(NSRange(location: 0, length: 3)), "yank:", then: "two \nthree four\nfive", 3, 0),
      .init(
        "abc def\nghi jkl\nmno", 8, 0, "deleteToBeginningOfLine:",
        then: "abc def\nghi jkl\nmno", 8, 0),
      .init(
        "abc def\nghi jkl\nmno", 8, 0, "deleteToBeginningOfParagraph:",
        then: "abc def\nghi jkl\nmno", 8, 0),
      .init("abc def\nghi jkl\nmno", 7, 0, "deleteToEndOfLine:", then: "abc defghi jkl\nmno", 7, 0),
      .init(
        "abc def\nghi jkl\nmno", 19, 0, "deleteToEndOfParagraph:",
        then: "abc def\nghi jkl\nmno", 19, 0),
    ]

    nonisolated static let lineBreakScenarios: [CommandScenario] = [
      // 改ページは行を終え、U+2028 は段落を終えない。
      .init(
        "ab\u{C}cd", 0, 0, "deleteToEndOfLine:", "moveToEndOfDocument:", "yank:",
        then: "\u{C}cdab", 5, 0),
      .init("ab\u{C}\ncd", 3, 0, "deleteToEndOfLine:", then: "ab\u{C}cd", 3, 0),
      // 段落の末尾で改ページなどの直後にあるキャレットは、その文字で終わる行に属する。
      .init("ab\u{C}\ncd", 3, 0, "deleteToBeginningOfLine:", then: "\ncd", 0, 0),
      .init("ab\u{2028}\ncd", 3, 0, "deleteToBeginningOfLine:", then: "\ncd", 0, 0),
      .init("ab\u{2028}\ncd", 3, 0, "moveToBeginningOfLine:", then: "ab\u{2028}\ncd", 0, 0),
      .init("ab\u{2028}\ncd", 3, 0, "moveToEndOfLine:", then: "ab\u{2028}\ncd", 3, 0),
      .init("ab\u{C}\ncd", 3, 0, "selectLine:", then: "ab\u{C}\ncd", 0, 2),
      .init("ab\u{2028}\ncd", 3, 0, "selectLine:", then: "ab\u{2028}\ncd", 0, 2),
      .init(
        "a\u{2028}\u{2028}b", 4, 0, "deleteToBeginningOfLine:", then: "a\u{2028}\u{2028}", 3, 0),
      .init("a\u{2028}\u{2028}b", 4, 0, "selectLine:", then: "a\u{2028}\u{2028}b", 3, 1),
      // 文書の末尾の改ページは行の一部になる。U+2028 はならない。
      .init("ab\u{C}", 0, 0, "moveToEndOfLine:", then: "ab\u{C}", 3, 0),
      .init("ab\u{C}", 3, 0, "selectLine:", then: "ab\u{C}", 0, 3),
      .init("ab\u{C}", 2, 0, "selectLine:", then: "ab\u{C}", 0, 3),
      .init("ab\u{2028}", 3, 0, "selectLine:", then: "ab\u{2028}", 0, 2),
      .init("ab\u{2028}", 0, 0, "moveToEndOfLine:", then: "ab\u{2028}", 2, 0),
      .init(
        "ab\u{2028}cd", 0, 0, "deleteToEndOfParagraph:", "moveToEndOfDocument:", "yank:",
        then: "ab\u{2028}cd", 5, 0),
      .init("ab\u{2028}cd", 4, 0, "deleteToBeginningOfParagraph:", then: "d", 0, 0),
    ]

    nonisolated static let markScenarios: [CommandScenario] = [
      // 文字の途中の印は、エンジンの書記素の前に寄せる。ทำ は NSString では 2 文字。
      .init(
        "ทำ ab", 1, 0, "setMark:", "moveToEndOfDocument:", "selectToMark:",
        then: "ทำ ab", 0, 5),
      .init(
        "ab ทำ", 1, 3, "setMark:", "moveToBeginningOfDocument:", "selectToMark:",
        then: "ab ทำ", 0, 3),
      .init(
        "one two", 4, 0, "setMark:", "moveToEndOfDocument:", "selectToMark:",
        then: "one two", 4, 3),
      .init(
        "one two", 4, 2, "setMark:", "moveToBeginningOfDocument:", "selectToMark:",
        then: "one two", 0, 6),
      .init(
        "one two", 4, 2, "setMark:", "moveToBeginningOfDocument:", "swapWithMark:",
        then: "one two", 4, 2),
      .init(
        "one two", 4, 2, "setMark:", "moveToBeginningOfDocument:", "swapWithMark:", "swapWithMark:",
        then: "one two", 0, 0),
      .init(
        "one two", 1, 0, "setMark:", .select(NSRange(location: 3, length: 2)), "swapWithMark:",
        "selectToMark:", then: "one two", 1, 4),
      .init(
        "one two", 1, 0, "setMark:", .select(NSRange(location: 3, length: 2)), "deleteToMark:",
        then: "owo", 1, 0),
      .init(
        "one two", 4, 0, "setMark:", "moveToEndOfDocument:", "deleteToMark:",
        "moveToBeginningOfDocument:", "yank:", then: "twoone ", 3, 0),
      .init(
        "ab cd\nef gh\nij", 4, 0, "setMark:", .select(NSRange(location: 1, length: 0)),
        "deleteToMark:", "deleteToBeginningOfParagraph:", "moveToEndOfDocument:", "yank:",
        then: "d\nef gh\nijab c", 14, 0),
      .init(
        "one two", 4, 0, "setMark:", "moveToBeginningOfDocument:", .type("XX"), "selectToMark:",
        then: "XXone two", 2, 2),
      .init(
        "one two", 4, 0, "setMark:", .select(NSRange(location: 0, length: 7)), .type("X"),
        "selectToMark:", then: "X", 1, 0),
      .init("one two", 4, 0, "selectToMark:", then: "one two", 4, 0),
      .init("one two", 4, 0, "swapWithMark:", then: "one two", 4, 0),
      .init("one two", 4, 0, "deleteToMark:", then: "one two", 4, 0),
      // 印が無ければ選択を消す。消した位置に印を付け直す。
      .init(
        "one two", 1, 2, "deleteToMark:", "moveToEndOfDocument:", "yank:", then: "o twone", 7, 0),
      .init("one two", 4, 3, "deleteToMark:", "selectToMark:", then: "one ", 4, 0),
      .init(
        "one two three four", 8, 0, "setMark:", .select(NSRange(location: 2, length: 0)),
        "deleteToMark:", "deleteToMark:", then: "onthree four", 2, 0),
      .init(
        "one two three four", 8, 0, "setMark:", .select(NSRange(location: 2, length: 0)),
        "deleteToMark:", "moveRight:", "selectToMark:", then: "onthree four", 2, 1),
    ]

    nonisolated static let selectionScenarios: [CommandScenario] = [
      .init("one two three", 5, 0, "selectWord:", then: "one two three", 4, 3),
      .init("one two three", 3, 0, "selectWord:", then: "one two three", 0, 3),
      .init("one two three", 4, 0, "selectWord:", then: "one two three", 3, 1),
      .init("one two three", 0, 0, "selectWord:", then: "one two three", 0, 3),
      .init("one two three", 13, 0, "selectWord:", then: "one two three", 8, 5),
      .init("one two three", 5, 4, "selectWord:", then: "one two three", 4, 9),
      .init("one two three", 4, 3, "selectWord:", then: "one two three", 4, 3),
      .init("one two three", 3, 1, "selectWord:", then: "one two three", 3, 1),
      .init("one  two", 4, 0, "selectWord:", then: "one  two", 3, 2),
      .init("a, b", 2, 0, "selectWord:", then: "a, b", 1, 1),
      .init("foo.bar baz", 3, 0, "selectWord:", then: "foo.bar baz", 0, 7),
      .init("one two\nthree", 8, 0, "selectWord:", then: "one two\nthree", 8, 5),
      .init("ab\n\ncd", 3, 0, "selectWord:", then: "ab\n\ncd", 3, 1),
      .init("", 0, 0, "selectWord:", then: "", 0, 0),
      .init("ab\n", 3, 0, "selectWord:", then: "ab\n", 2, 1),
      .init("ab\n\n", 4, 0, "selectWord:", then: "ab\n\n", 3, 1),
      .init("ab\u{C}cd", 3, 0, "selectWord:", then: "ab\u{C}cd", 3, 2),
      .init("ab\u{2028}cd", 3, 0, "selectWord:", then: "ab\u{2028}cd", 3, 2),
      .init("ab\u{2029}cd", 3, 0, "selectWord:", then: "ab\u{2029}cd", 3, 2),
      .init(
        "one two\nthree four\nfive", 10, 0, "selectLine:",
        then: "one two\nthree four\nfive", 8, 11),
      .init(
        "one two\nthree four\nfive", 7, 0, "selectLine:", then: "one two\nthree four\nfive", 0, 8),
      .init(
        "one two\nthree four\nfive", 2, 8, "selectLine:", then: "one two\nthree four\nfive", 0, 8),
      .init("ab\ncd", 3, 2, "selectLine:", then: "ab\ncd", 3, 2),
      .init("ab\n\ncd", 3, 0, "selectLine:", then: "ab\n\ncd", 3, 0),
      .init("\n\n", 0, 0, "selectLine:", then: "\n\n", 0, 1),
      .init("\nfoo", 0, 0, "selectLine:", then: "\nfoo", 0, 0),
      .init("\n", 0, 0, "selectLine:", then: "\n", 0, 0),
      .init("\n\nfoo", 0, 0, "selectLine:", then: "\n\nfoo", 0, 1),
      .init("\n\n\n", 0, 0, "selectLine:", then: "\n\n\n", 0, 1),
      .init("\u{2029}\u{2029}", 0, 0, "selectLine:", then: "\u{2029}\u{2029}", 0, 1),
      .init("one two\n", 8, 0, "selectLine:", then: "one two\n", 8, 0),
      .init("", 0, 0, "selectLine:", then: "", 0, 0),
      .init("ab\u{C}cd", 1, 0, "selectLine:", then: "ab\u{C}cd", 0, 2),
      .init("ab\u{2028}cd", 1, 0, "selectLine:", then: "ab\u{2028}cd", 0, 2),
      .init("ab\u{2029}cd", 1, 0, "selectLine:", then: "ab\u{2029}cd", 0, 3),
      .init("ab\u{85}cd", 1, 0, "selectLine:", then: "ab\u{85}cd", 0, 2),
      .init("ab\u{B}\ncd", 0, 0, "moveToEndOfLine:", then: "ab\u{B}\ncd", 3, 0),
      .init("ab\u{B}\ncd", 0, 0, "deleteToEndOfLine:", then: "\ncd", 0, 0),
      .init("ab\u{B}cd", 3, 0, "selectWord:", then: "ab\u{B}cd", 2, 1),
      .init(
        "one two\nthree four\nfive", 10, 0, "selectParagraph:",
        then: "one two\nthree four\nfive", 8, 11),
      .init(
        "one two\nthree four\nfive", 20, 0, "selectParagraph:",
        then: "one two\nthree four\nfive", 19, 4),
      .init(
        "one two\nthree four\nfive", 2, 8, "selectParagraph:",
        then: "one two\nthree four\nfive", 0, 19),
      .init("one two\nthree", 7, 0, "selectParagraph:", then: "one two\nthree", 0, 8),
      .init("ab\ncd\nef", 2, 1, "selectParagraph:", then: "ab\ncd\nef", 0, 3),
      .init("one two\n\nfive", 8, 0, "selectParagraph:", then: "one two\n\nfive", 8, 1),
      .init("one two\n", 8, 0, "selectParagraph:", then: "one two\n", 8, 0),
    ]

    nonisolated static let editingScenarios: [CommandScenario] = [
      // スクロールは本文と選択を変えない。
      .init(
        "ab\ncd", 1, 0, "centerSelectionInVisibleArea:", "scrollLineDown:", "scrollLineUp:",
        then: "ab\ncd", 1, 0),
      // 文字の入力と削除
      .init("ab", 1, 0, "insertSingleQuoteIgnoringSubstitution:", then: "a'b", 2, 0),
      .init("ab", 0, 1, "insertDoubleQuoteIgnoringSubstitution:", then: "\"b", 1, 0),
      .init("ab", 1, 0, "insertContainerBreak:", then: "a\u{C}b", 2, 0),
      .init("ab", 1, 0, "insertBacktab:", then: "ab", 1, 0),
      .init("ab", 0, 1, "delete:", then: "b", 0, 0),
      .init("ab", 1, 0, "delete:", then: "ab", 1, 0),
      .init("a\u{E9}", 2, 0, "deleteBackwardByDecomposingPreviousCharacter:", then: "ae", 2, 0),
      .init("ae\u{301}", 3, 0, "deleteBackwardByDecomposingPreviousCharacter:", then: "ae", 2, 0),
      .init(
        "a\u{1EC7}", 2, 0, "deleteBackwardByDecomposingPreviousCharacter:",
        then: "ae\u{323}", 3, 0),
      .init(
        "a\u{D55C}", 2, 0, "deleteBackwardByDecomposingPreviousCharacter:",
        then: "a\u{1112}\u{1161}", 3, 0),
      .init(
        "a\u{1100}\u{1161}\u{11AB}", 4, 0, "deleteBackwardByDecomposingPreviousCharacter:",
        then: "a\u{1100}\u{1161}", 3, 0),
      .init("aが", 2, 0, "deleteBackwardByDecomposingPreviousCharacter:", then: "aか", 2, 0),
      .init(
        "a👍\u{1F3FD}", 5, 0, "deleteBackwardByDecomposingPreviousCharacter:", then: "a👍", 3, 0),
      .init(
        "a\u{E9}", 2, 0, "deleteBackwardByDecomposingPreviousCharacter:",
        "deleteBackwardByDecomposingPreviousCharacter:", then: "a", 1, 0),
      .init("ab", 0, 1, "deleteBackwardByDecomposingPreviousCharacter:", then: "b", 0, 0),
      .init("ab", 0, 0, "deleteBackwardByDecomposingPreviousCharacter:", then: "ab", 0, 0),
      .init("a\nb", 2, 0, "deleteBackwardByDecomposingPreviousCharacter:", then: "ab", 1, 0),
      // 文字の途中のキャレットでは、Backspace と同じく、そのキャレットを含む文字を分解する。
      // NSTextView は前の文字を分解するので、結果が違う。
      .init("ae\u{301}b", 2, 0, "deleteBackwardByDecomposingPreviousCharacter:", then: "aeb", 2, 0),
      // 文字はエンジンの書記素で区切る。éำ と ทำ は NSString では 2 文字だが、エンジンでは 1 文字。
      .init(
        "a\u{E9}\u{E33}", 3, 0, "deleteBackwardByDecomposingPreviousCharacter:",
        then: "ae\u{301}", 3, 0),
      .init("aทำ", 2, 0, "deleteBackwardByDecomposingPreviousCharacter:", then: "aท", 2, 0),
    ]

    /// 選択を単語の境界まで広げて変換し、変換した範囲を選ぶ。
    nonisolated static let wordTransformScenarios: [CommandScenario] = [
      .init("hello world foo", 2, 0, "uppercaseWord:", then: "HELLO world foo", 0, 5),
      .init("hello world foo", 5, 0, "uppercaseWord:", then: "HELLO world foo", 0, 5),
      .init("hello world foo", 6, 0, "uppercaseWord:", then: "hello world foo", 5, 1),
      .init("hello  world foo", 6, 0, "uppercaseWord:", then: "hello  world foo", 5, 2),
      .init("hello world foo", 15, 0, "uppercaseWord:", then: "hello world FOO", 12, 3),
      .init("hello world foo", 0, 0, "uppercaseWord:", then: "HELLO world foo", 0, 5),
      .init("hello world foo", 2, 5, "uppercaseWord:", then: "HELLO WORLD foo", 0, 11),
      .init("hello world foo", 2, 5, "capitalizeWord:", then: "Hello World foo", 0, 11),
      .init(
        "hello WORLD o'neil foo-bar 3rd ÉCOLE straße", 0, 42, "capitalizeWord:",
        then: "Hello World O'neil Foo-Bar 3Rd École Straße", 0, 43),
      .init(
        "hello WORLD o'neil foo-bar 3rd ÉCOLE straße", 0, 42, "uppercaseWord:",
        then: "HELLO WORLD O'NEIL FOO-BAR 3RD ÉCOLE STRASSE", 0, 44),
      .init("HELLO World", 0, 11, "lowercaseWord:", then: "hello world", 0, 11),
      .init("hello WORLD", 8, 0, "capitalizeWord:", then: "hello World", 6, 5),
      .init("hello WORLD", 8, 0, "lowercaseWord:", then: "hello world", 6, 5),
      .init("a\nb", 0, 3, "uppercaseWord:", then: "A\nB", 0, 3),
      .init("", 0, 0, "uppercaseWord:", then: "", 0, 0),
      .init(
        "abc 123 ｱｲｳ ﾃﾞｽ", 0, 15, "convertToFullWidth:",
        then: "ａｂｃ　１２３　アイウ　デス", 0, 14),
      .init(
        "ＡＢＣ　１２３ アイウ デス", 0, 14, "convertToHalfWidth:", then: "ABC 123 ｱｲｳ ﾃﾞｽ", 0, 15),
      .init("abc def", 1, 4, "convertToFullWidth:", then: "ａｂｃ　ｄｅｆ", 0, 7),
      .init(
        "日本語の文章です", 0, 8, "convertToSimplifiedChinese:", then: "日本语の文章です", 0, 8),
    ]

    private func check(_ scenario: CommandScenario) {
      let view = makeEditor(text: scenario.text)
      scenario.run(on: view)
      #expect(view.text == scenario.expectedText)
      #expect(ranges(view) == [scenario.expectedSelection])
    }

    @Test(arguments: transposeScenarios)
    func 入れ替えは表の本文と選択になる(scenario: CommandScenario) { check(scenario) }

    @Test(arguments: killScenarios)
    func 行や段落の消去とyankは表の本文と選択になる(scenario: CommandScenario) { check(scenario) }

    @Test(arguments: lineBreakScenarios)
    func 改ページや行区切りの前後の操作は表の本文と選択になる(scenario: CommandScenario) {
      check(scenario)
    }

    @Test(arguments: markScenarios)
    func 印の操作は表の本文と選択になる(scenario: CommandScenario) { check(scenario) }

    @Test(arguments: selectionScenarios)
    func 単語と行と段落の選択は表の選択になる(scenario: CommandScenario) { check(scenario) }

    @Test(arguments: editingScenarios)
    func 文字の入力と削除は表の本文と選択になる(scenario: CommandScenario) { check(scenario) }

    @Test(arguments: wordTransformScenarios)
    func 単語の変換は表の本文と選択になる(scenario: CommandScenario) { check(scenario) }

    // MARK: - 応答するセレクタ

    /// キーバインドから届くセレクタのうち、EditorView が自分で処理しなければならず、ほかの
    /// テストでは動かしていないもの。実装が消えたり名前を誤ったりすると、キーを押しても何も
    /// 起きなくなる。
    nonisolated static let ownSelectors = [
      "deleteWordForward:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:",
      "insertParagraphSeparator:", "insertTabIgnoringFieldEditor:",
      "moveBackward:", "moveBackwardAndModifySelection:", "moveForward:",
      "moveForwardAndModifySelection:", "moveLeftAndModifySelection:", "moveRightAndModifySelection:",
      "moveUpAndModifySelection:", "moveDownAndModifySelection:",
      "moveWordBackward:", "moveWordBackwardAndModifySelection:", "moveWordForward:",
      "moveWordForwardAndModifySelection:", "moveWordLeft:", "moveWordRightAndModifySelection:",
      "moveParagraphBackwardAndModifySelection:", "moveParagraphForwardAndModifySelection:",
      "moveToBeginningOfParagraphAndModifySelection:", "moveToEndOfParagraphAndModifySelection:",
      "moveToEndOfLineAndModifySelection:", "moveToLeftEndOfLineAndModifySelection:",
      "moveToRightEndOfLineAndModifySelection:", "moveToBeginningOfDocumentAndModifySelection:",
      "moveToEndOfDocumentAndModifySelection:",
      "pageUp:", "pageDown:", "pageUpAndModifySelection:", "pageDownAndModifySelection:",
      "scrollPageUp:", "scrollPageDown:", "scrollToBeginningOfDocument:", "scrollToEndOfDocument:",
    ]

    /// その型が自分で実装しているか。NSView から継承しただけの応答は数えない。
    private static func implements(_ type: AnyClass, _ selector: Selector) -> Bool {
      guard let own = class_getInstanceMethod(type, selector).map(method_getImplementation) else {
        return false
      }
      return own != class_getInstanceMethod(NSView.self, selector).map(method_getImplementation)
    }

    @Test(arguments: ownSelectors)
    func キーバインドのセレクタをEditorViewが自分で実装する(selector: String) {
      #expect(Self.implements(EditorView.self, NSSelectorFromString(selector)))
    }

    // MARK: - 複数の選択

    @Test func 入れ替えはキャレットごとに行い範囲の選択は変えない() {
      let view = makeEditor(text: "abcd\nefgh\nij")
      view.select([caret(2), caret(9), NSRange(location: 10, length: 1)], primary: 0)
      view.transpose(nil)
      #expect(view.text == "acbd\nefhg\nij")
      #expect(ranges(view) == [caret(3), caret(9), NSRange(location: 10, length: 1)])
      view.undo(nil)
      #expect(view.text == "abcd\nefgh\nij")
    }

    @Test func 接する入れ替えでもキャレットはそれぞれ進む() {
      let view = makeEditor(text: "abcd\naaaa")
      view.select([caret(1), caret(3), caret(6)], primary: 2)
      view.transpose(nil)
      #expect(view.text == "badc\naaaa")
      #expect(ranges(view) == [caret(2), caret(4), caret(7)])
      #expect(view.session.primaryIndex == 2)
      view.undo(nil)
      #expect(ranges(view) == [caret(1), caret(3), caret(6)])
      view.redo(nil)
      #expect(view.text == "badc\naaaa")
      #expect(ranges(view) == [caret(2), caret(4), caret(7)])
      #expect(view.session.primaryIndex == 2)
    }

    @Test func ほかの選択に掛かる入れ替えは行わない() {
      let view = makeEditor(text: "abcd\nxy")
      view.select([NSRange(location: 1, length: 2), caret(4), caret(7)], primary: 1)
      view.transpose(nil)
      #expect(view.text == "abcd\nyx")
      #expect(ranges(view) == [NSRange(location: 1, length: 2), caret(4), caret(7)])
    }

    @Test func 重なる入れ替えは前のキャレットだけを行う() {
      let view = makeEditor(text: "abcd")
      view.select([caret(1), caret(2)], primary: 1)
      view.transpose(nil)
      #expect(view.text == "bacd")
    }

    @Test func 続けて消した文字はキャレットごとに繋がり各キャレットに貼れる() {
      let view = makeEditor(text: "one two\nthree four\nfive six")
      view.select([caret(4), caret(14)], primary: 0)
      view.deleteToEndOfParagraph(nil)
      view.deleteToEndOfParagraph(nil)
      #expect(view.text == "one three five six")
      view.select([caret(0), caret(18)], primary: 0)
      view.yank(nil)
      #expect(view.text == "two\none three five sixfour\n")
      #expect(ranges(view) == [caret(4), caret(27)])
    }

    @Test func キャレットが一つにまとまっても続けて消した文字はキャレットごとに残る() {
      let view = makeEditor(text: "a\nb\nc\nend")
      view.select([caret(0), caret(2), caret(4)], primary: 0)
      view.deleteToEndOfParagraph(nil)
      view.deleteToEndOfParagraph(nil)
      #expect(view.text == "end")
      #expect(ranges(view) == [caret(0)])
      view.yank(nil)
      #expect(view.text == "a\nb\nc\nend")
    }

    @Test func 消してまとまったキャレットの分は本文の順に繋がり続けて消すと後ろに繋がる() {
      let joined = makeEditor(text: "abcdef\nxyz")
      joined.select([caret(3), caret(6)], primary: 0)
      joined.deleteToBeginningOfLine(nil)
      #expect(joined.text == "\nxyz")
      joined.moveToEndOfDocument(nil)
      joined.yank(nil)
      #expect(joined.text == "\nxyzabcdef")

      let continued = makeEditor(text: "ab\ncd")
      continued.select([caret(0), caret(1)], primary: 0)
      continued.deleteToEndOfParagraph(nil)
      continued.deleteToEndOfParagraph(nil)
      continued.moveToEndOfDocument(nil)
      continued.yank(nil)
      #expect(continued.text == "cdab\n")
    }

    @Test func 間の消去でキャレットがまとまっても続けて消した文字は残る() {
      let view = makeEditor(text: "a1\n2b\nc")
      view.select([caret(1), caret(3)], primary: 0)
      view.deleteToEndOfParagraph(nil)
      #expect(view.text == "a\n\nc")
      view.deleteBackward(nil)
      #expect(ranges(view) == [caret(0)])
      view.deleteToEndOfParagraph(nil)
      view.moveToEndOfDocument(nil)
      view.yank(nil)
      #expect(view.text == "c12b\n")
    }

    @Test func 何も消さなかったキャレットの分のyankは選択を残す() {
      let view = makeEditor(text: "abc\nxyz")
      view.select([caret(0), caret(7)], primary: 0)
      view.deleteToEndOfParagraph(nil)
      #expect(view.text == "\nxyz")
      view.select([caret(0), NSRange(location: 2, length: 2)], primary: 0)
      view.yank(nil)
      #expect(view.text == "abc\nxyz")
      #expect(ranges(view) == [caret(3), NSRange(location: 5, length: 2)])
    }

    @Test func 消した範囲とキャレットの数が違えば改行で繋いで各キャレットに貼る() {
      let view = makeEditor(text: "ab\ncd\n")
      view.select([caret(1), caret(4)], primary: 0)
      view.deleteToEndOfLine(nil)
      view.select([caret(4)], primary: 0)
      view.yank(nil)
      #expect(view.text == "a\nc\nb\nd")
      view.select([caret(0), caret(7)], primary: 0)
      view.deleteToBeginningOfParagraph(nil)
      #expect(view.text == "a\nc\nb\n")
    }

    @Test func 取り消しとやり直しと変換を挟むと続けて消したことにならない() {
      let undone = makeEditor(text: "abc\ndef")
      undone.select([caret(1)], primary: 0)
      undone.deleteToEndOfParagraph(nil)
      undone.undo(nil)
      undone.deleteToEndOfParagraph(nil)
      undone.moveToEndOfDocument(nil)
      undone.yank(nil)
      #expect(undone.text == "a\ndefbc")

      let redone = makeEditor(text: "abc\ndef")
      redone.select([caret(1)], primary: 0)
      redone.deleteToEndOfParagraph(nil)
      redone.undo(nil)
      redone.redo(nil)
      redone.deleteToEndOfParagraph(nil)
      redone.moveToEndOfDocument(nil)
      redone.yank(nil)
      #expect(redone.text == "adef\n")

      // 変換を始めて、確定せずに全て消す。本文は変わらない。
      let composed = makeEditor(text: "abc\ndef")
      composed.select([caret(1)], primary: 0)
      composed.deleteToEndOfParagraph(nil)
      composed.setMarkedText("x", selectedRange: caret(1), replacementRange: caret(NSNotFound))
      composed.setMarkedText("", selectedRange: caret(0), replacementRange: caret(NSNotFound))
      #expect(composed.text == "a\ndef")
      composed.deleteToEndOfParagraph(nil)
      composed.moveToEndOfDocument(nil)
      composed.yank(nil)
      #expect(composed.text == "adef\n")
    }

    @Test func 範囲が重なる選択の消去は本文の順に一度だけkill_bufferに入れ印はまとまったキャレットに付ける() {
      let view = makeEditor(text: "one two three")
      view.select([caret(1), caret(2)], primary: 0)
      view.setMark(nil)
      view.select([caret(6), caret(7)], primary: 0)
      view.deleteToMark(nil)
      #expect(view.text == "o three")
      #expect(ranges(view) == [caret(1)])
      view.select([caret(3)], primary: 0)
      view.selectToMark(nil)
      #expect(ranges(view) == [NSRange(location: 1, length: 2)])
      view.select([caret(0)], primary: 0)
      view.yank(nil)
      #expect(view.text == "ne twoo three")
    }

    @Test func 前の選択より手前から消す範囲もkill_bufferに入れる() {
      let view = makeEditor(text: "abcdef")
      view.select([NSRange(location: 1, length: 1), caret(4)], primary: 0)
      view.deleteToBeginningOfParagraph(nil)
      #expect(view.text == "ef")
      view.select([caret(2)], primary: 0)
      view.yank(nil)
      #expect(view.text == "efabcd")
    }

    @Test func 本文を外から差し替えると印は消える() {
      let state = makeState(text: "one two")
      let controller = EditorTextController(state: state)
      retainedControllers.append(controller)
      let view = controller.editorView
      view.select([caret(4)], primary: 0)
      view.setMark(nil)
      state.text = "three four five"
      controller.syncFromState()
      view.select([NSRange(location: 0, length: 2)], primary: 0)
      view.selectToMark(nil)
      #expect(ranges(view) == [NSRange(location: 0, length: 2)])
      view.deleteToMark(nil)
      #expect(view.text == "ree four five")
    }

    @Test func 後ろ向きに続けて消した文字は前に繋がる() {
      let view = makeEditor(text: "one two")
      view.select([caret(5)], primary: 0)
      view.setMark(nil)
      view.select([caret(7)], primary: 0)
      view.deleteToMark(nil)
      view.deleteToBeginningOfParagraph(nil)
      #expect(view.text == "")
      view.yank(nil)
      #expect(view.text == "one two")
    }

    @Test func 変換中は編集のコマンドが本文を変えずkill_bufferにも入れない() {
      let view = makeEditor(text: "abcd\nef")
      view.select([caret(2)], primary: 0)
      view.setMark(nil)
      view.setMarkedText("x", selectedRange: caret(1), replacementRange: caret(NSNotFound))
      view.transpose(nil)
      view.deleteToEndOfParagraph(nil)
      view.deleteToMark(nil)
      view.deleteBackwardByDecomposingPreviousCharacter(nil)
      view.yank(nil)
      #expect(view.text == "abxcd\nef")
      #expect(view.hasMarkedText())
      view.unmarkText()
      view.yank(nil)
      #expect(view.text == "abxcd\nef")
    }

    @Test func 入れ替えと消去は一回ずつ取り消せる() {
      let transposed = makeEditor(text: "abcd")
      transposed.select([caret(1)], primary: 0)
      transposed.transpose(nil)
      transposed.transpose(nil)
      #expect(transposed.text == "bcad")
      transposed.undo(nil)
      #expect(transposed.text == "bacd")

      let killed = makeEditor(text: "one two\nthree")
      killed.select([caret(5)], primary: 0)
      killed.deleteBackward(nil)
      killed.deleteToEndOfParagraph(nil)
      killed.deleteToEndOfParagraph(nil)
      #expect(killed.text == "one three")
      killed.undo(nil)
      #expect(killed.text == "one \nthree")
      killed.undo(nil)
      #expect(killed.text == "one wo\nthree")
      // 消した文字は、取り消しても kill buffer に残る。
      killed.moveToEndOfDocument(nil)
      killed.yank(nil)
      #expect(killed.text == "one wo\nthreewo\n")
    }

    @Test func 何も消していなければyankは何も入れない() {
      let view = makeEditor(text: "ab")
      view.select([caret(1)], primary: 0)
      view.yank(nil)
      #expect(view.text == "ab")
      #expect(!view.document.canUndo)
    }

    @Test func 印はキャレットごとに付き選択と組にして使う() {
      let view = makeEditor(text: "one two\nthree four")
      view.select([caret(4), caret(14)], primary: 1)
      view.setMark(nil)
      view.select([caret(7), caret(18)], primary: 1)
      view.selectToMark(nil)
      #expect(ranges(view) == [NSRange(location: 4, length: 3), NSRange(location: 14, length: 4)])
      #expect(view.session.primaryIndex == 1)

      view.select([caret(0), caret(8)], primary: 0)
      view.swapWithMark(nil)
      #expect(ranges(view) == [caret(4), caret(14)])
      view.selectToMark(nil)
      #expect(ranges(view) == [NSRange(location: 0, length: 4), NSRange(location: 8, length: 6)])

      view.select([caret(4), caret(14)], primary: 0)
      view.setMark(nil)
      view.select([caret(7), caret(18)], primary: 0)
      view.deleteToMark(nil)
      #expect(view.text == "one \nthree ")
      view.undo(nil)
      #expect(view.text == "one two\nthree four")
      #expect(ranges(view) == [caret(7), caret(18)])
      view.redo(nil)
      #expect(view.text == "one \nthree ")
      // 印と選択の数が違えば何もしない。
      view.select([caret(0)], primary: 0)
      view.selectToMark(nil)
      #expect(ranges(view) == [caret(0)])
    }

    @Test func 印へ移って選択がまとまると印は消える() {
      let view = makeEditor(text: "one two")
      view.select([caret(1), caret(2)], primary: 0)
      view.setMark(nil)
      // 本文が縮み、二つの印がどちらも本文の末尾に寄る。
      view.select([NSRange(location: 0, length: 7)], primary: 0)
      view.type("x")
      view.select([caret(0), caret(1)], primary: 0)
      view.swapWithMark(nil)
      #expect(ranges(view) == [caret(1)])
      // 印が無ければ、選択を消す。
      view.select([NSRange(location: 0, length: 1)], primary: 0)
      view.deleteToMark(nil)
      #expect(view.text == "")
    }

    @Test func 単語と行と段落の選択は選択ごとに広げる() {
      let view = makeEditor(text: "one two\nthree four\nfive")
      view.select([caret(1), caret(10), NSRange(location: 20, length: 1)], primary: 2)
      view.selectWord(nil)
      #expect(
        ranges(view) == [
          NSRange(location: 0, length: 3), NSRange(location: 8, length: 5),
          NSRange(location: 19, length: 4),
        ])
      #expect(view.session.primaryIndex == 2)

      view.select([caret(1), caret(20)], primary: 0)
      view.selectLine(nil)
      #expect(ranges(view) == [NSRange(location: 0, length: 8), NSRange(location: 19, length: 4)])

      view.select([caret(1), caret(10)], primary: 0)
      view.selectParagraph(nil)
      // 接する範囲の選択は一つにならない。
      #expect(ranges(view) == [NSRange(location: 0, length: 8), NSRange(location: 8, length: 11)])
    }

    @Test func 行の選択は折り返した表示上の行を選ぶ() throws {
      let text = String(repeating: "word ", count: 40) + "\nnext"
      let view = makeEditor(text: text, width: 200)
      let lines = view.layout.lineFrames()
      try #require(lines.count > 3)
      let first = view.layout.lineRange(containing: 0)
      try #require(first.length < 200)
      view.select([caret(first.length + 2)], primary: 0)
      view.selectLine(nil)
      let second = view.layout.lineRange(containing: first.length)
      #expect(ranges(view) == [second])
      // 段落の最後の行は改行まで含む。
      view.select([caret(199)], primary: 0)
      view.selectLine(nil)
      let last = try #require(ranges(view).first)
      #expect(NSMaxRange(last) == 201)
      #expect(last.location > 0)
    }

    @Test(arguments: [false, true])
    func 折り返し行末から選んで編集し一度で取り消せる(replacing: Bool) throws {
      let text = String(repeating: "word ", count: 40) + "\nnext"
      let view = makeEditor(text: text, width: 200)
      let first = try #require(view.layout.visualLines().first).range
      try #require(first.length > 0 && first.length < 200)
      view.moveToEndOfLine(nil)
      #expect(view.selectedRange() == caret(NSMaxRange(first)))
      // 折り返し位置のキャレットは次の行の先頭と同じ位置にあるが、行末へ移った後は前の行に属する。
      view.selectLine(nil)
      #expect(view.selectedRange() == first)
      if replacing {
        view.insertText("X", replacementRange: caret(NSNotFound))
      } else {
        view.deleteBackward(nil)
      }
      let rest = (text as NSString).substring(from: NSMaxRange(first))
      #expect(view.text == (replacing ? "X" : "") + rest)
      #expect(view.selectedRange() == caret(replacing ? 1 : 0))
      view.undo(nil)
      #expect(view.text == text)
    }

    /// 行末へ移った直後のキャレットは前の行に属する。同じ位置を選び直したり別の位置へ動いたり
    /// すると、その位置を先頭とする行に属する。
    @Test(arguments: [
      ("select", 1), ("moveRight:", 1), ("moveToBeginningOfDocument:", 0), ("moveToEndOfLine:", 0),
    ])
    func 行末側の選択は次の選択や移動に従う(operation: String, line: Int) throws {
      let view = makeEditor(text: String(repeating: "word ", count: 40), width: 200)
      let lines = view.layout.visualLines()
      try #require(lines.count > 2)
      view.moveToEndOfLine(nil)
      try #require(view.selectedRange() == caret(NSMaxRange(lines[0].range)))
      if operation == "select" {
        view.select([view.selectedRange()], primary: 0)
      } else {
        view.doCommand(by: NSSelectorFromString(operation))
      }
      view.selectLine(nil)
      #expect(view.selectedRange() == lines[line].range)
    }

    @Test func 折り返し行末の選択は複数のキャレットそれぞれの行を選ぶ() throws {
      let view = makeEditor(text: String(repeating: "word ", count: 40), width: 200)
      let lines = view.layout.visualLines()
      try #require(lines.count > 4)
      view.select([caret(1), caret(lines[2].range.location + 1)], primary: 1)
      view.moveToEndOfLine(nil)
      view.selectLine(nil)
      #expect(ranges(view) == [lines[0].range, lines[2].range])
      #expect(view.session.primaryIndex == 1)
    }

    /// 行末側にあることは行の選択にだけ効き、行末までの削除は次の行の先頭にあるキャレットと
    /// 同じく次の行を消す。
    @Test(arguments: ["word ", "😀", "a\u{301}"])
    func 折り返し行末の状態は既存の削除範囲を変えない(unit: String) throws {
      let text = String(repeating: unit, count: 40)
      let view = makeEditor(text: text, width: 200)
      let lines = view.layout.visualLines()
      try #require(lines.count > 1)
      view.moveToEndOfLine(nil)
      try #require(view.selectedRange() == caret(lines[1].range.location))
      view.deleteToEndOfLine(nil)
      #expect(view.text == (text as NSString).replacingCharacters(in: lines[1].range, with: ""))
      #expect(view.selectedRange() == caret(lines[1].range.location))
      view.undo(nil)
      #expect(view.text == text)
    }

    @Test func 引用符と改ページと削除はキャレットごとに行う() {
      let view = makeEditor(text: "ab\ncd")
      view.select([caret(1), NSRange(location: 3, length: 1)], primary: 0)
      view.insertSingleQuoteIgnoringSubstitution(nil)
      view.insertDoubleQuoteIgnoringSubstitution(nil)
      view.insertContainerBreak(nil)
      view.insertBacktab(nil)
      #expect(view.text == "a'\"\u{0C}b\n'\"\u{0C}d")
      view.select(
        [NSRange(location: 0, length: 2), caret(6), NSRange(location: 8, length: 1)], primary: 0)
      view.delete(nil)
      #expect(view.text == "\"\u{0C}b\n'\"d")
      #expect(ranges(view) == [caret(0), caret(4), caret(6)])
    }

    @Test func 分解して消すのはキャレットごとに行う() {
      let view = makeEditor(text: "\u{E9}\n\u{D55C}\nx")
      view.select([caret(1), caret(3), caret(5)], primary: 0)
      view.deleteBackwardByDecomposingPreviousCharacter(nil)
      #expect(view.text == "e\n\u{1112}\u{1161}\n")
      #expect(ranges(view) == [caret(1), caret(4), caret(5)])
      view.undo(nil)
      #expect(view.text == "\u{E9}\n\u{D55C}\nx")
    }

    @Test func Deleteの項目は範囲を選んでいるときだけ使える() {
      let view = makeEditor(text: "ab")
      let item = NSMenuItem(
        title: "Delete", action: #selector(EditorView.delete(_:)), keyEquivalent: "")
      view.select([caret(1)], primary: 0)
      #expect(!view.validateUserInterfaceItem(item))
      view.select([NSRange(location: 0, length: 1)], primary: 0)
      #expect(view.validateUserInterfaceItem(item))
    }

    // MARK: - スクロール

    private func makeScrollingEditor() -> EditorView {
      let text = (0..<200).map { "line \($0)" }.joined(separator: "\n")
      let view = makeEditor(text: text)
      view.refreshLayout()
      return view
    }

    @Test func 一行ずつのスクロールは選択を変えずに表示を送る() throws {
      let view = makeScrollingEditor()
      let clip = try #require(view.enclosingScrollView?.contentView)
      view.select([caret(3)], primary: 0)
      view.scrollLineDown(nil)
      #expect(clip.bounds.minY == 20)
      view.scrollLineDown(nil)
      #expect(clip.bounds.minY == 40)
      view.scrollLineUp(nil)
      #expect(clip.bounds.minY == 20)
      view.scrollLineUp(nil)
      view.scrollLineUp(nil)
      #expect(clip.bounds.minY == 0)
      #expect(ranges(view) == [caret(3)])
    }

    @Test func 選択を表示領域の中央に置く() throws {
      let view = makeScrollingEditor()
      let clip = try #require(view.enclosingScrollView?.contentView)
      let location = (view.text as NSString).range(of: "line 100").location
      view.select([caret(location)], primary: 0)
      clip.scroll(to: .zero)
      view.centerSelectionInVisibleArea(nil)
      let caretRect = view.layout.caretRect(at: location).offsetBy(
        dx: view.textOrigin.x, dy: view.textOrigin.y)
      #expect(abs(clip.bounds.midY - caretRect.midY) < 1)

      // 表示領域より高い選択は、先頭を上端に置く。
      let start = (view.text as NSString).range(of: "line 50").location
      view.select([NSRange(location: start, length: 400)], primary: 0)
      view.centerSelectionInVisibleArea(nil)
      let top = view.layout.caretRect(at: start).minY + view.textOrigin.y
      #expect(abs(clip.bounds.minY - top) < 1)

      // 複数の選択では、主の選択を中央に置く。
      let other = (view.text as NSString).range(of: "line 10").location
      let primary = (view.text as NSString).range(of: "line 150").location
      view.select([caret(other), caret(primary)], primary: 1)
      clip.scroll(to: .zero)
      view.centerSelectionInVisibleArea(nil)
      let primaryRect = view.layout.caretRect(at: primary).offsetBy(
        dx: view.textOrigin.x, dy: view.textOrigin.y)
      #expect(abs(clip.bounds.midY - primaryRect.midY) < 1)
      #expect(ranges(view) == [caret(other), caret(primary)])

      // 文書の先頭では、上にはみ出さない。
      view.select([caret(3)], primary: 0)
      view.centerSelectionInVisibleArea(nil)
      #expect(clip.bounds.minY == 0)
      #expect(ranges(view) == [caret(3)])
    }
  }
}
