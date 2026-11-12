import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

extension AppKitTests {
  struct AccessibilityTests {
    private func editor(_ text: String, width: CGFloat = 400, height: CGFloat = 300)
      -> (NSWindow, EditorTextController, EditorView)
    {
      editor(state: makeState(text: text), width: width, height: height)
    }

    private func editor(state: AppState, width: CGFloat = 400, height: CGFloat = 300)
      -> (NSWindow, EditorTextController, EditorView)
    {
      let controller = EditorTextController(state: state)
      let window = NSWindow(
        contentRect: NSRect(x: 80, y: 100, width: width, height: height), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = controller.scrollView
      controller.editorView.setFrameSize(controller.scrollView.contentSize)
      window.makeFirstResponder(controller.editorView)
      window.orderFront(nil)
      return (window, controller, controller.editorView)
    }

    /// 本文と、本文の位置や行の番号から引いた値の期待値。値は置き換え前のエディタだった
    /// NSTextView の結果に合わせてある。
    struct TextCase: CustomTestStringConvertible, Sendable {
      let text: String
      /// `accessibilityRange(for:)` の、-1 から本文の長さ + 1 までの位置の結果。
      let characters: [NSRange]
      /// `accessibilityLine(for:)` の、-1 から本文の長さ + 1 までの位置の結果。
      let lines: [Int]
      /// `accessibilityRange(forLine:)` の、-1 から 5 行目までの結果。
      let lineRanges: [NSRange]
      /// 本文の先頭のキャレット、本文全体の選択、本文の末尾のキャレットのそれぞれでの
      /// `accessibilityInsertionPointLineNumber()`。
      let insertionPointLines: [Int]

      var testDescription: String { text.debugDescription }
    }

    nonisolated static let textCases: [TextCase] = {
      func r(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
      }
      // 本文の外の位置と行は、空の範囲と 0 行目になる。
      return [
        TextCase(
          text: "", characters: [r(0, 0), r(0, 0), r(0, 0)], lines: [0, 0, 0],
          lineRanges: Array(repeating: r(0, 0), count: 7),
          // 空の本文には挿入位置の行が無い。
          insertionPointLines: [NSNotFound, NSNotFound, NSNotFound]),
        TextCase(
          text: "abc", characters: [r(0, 0), r(0, 1), r(1, 1), r(2, 1), r(0, 0), r(0, 0)],
          lines: [0, 0, 0, 0, 0, 0],
          lineRanges: [r(0, 0), r(0, 3), r(0, 0), r(0, 0), r(0, 0), r(0, 0), r(0, 0)],
          insertionPointLines: [0, NSNotFound, 0]),
        // 合成文字は文字全体の範囲になる。末尾の改行の後には空の行がある。
        TextCase(
          text: "ab😀e\u{301}\ncd\n",
          characters: [
            r(0, 0), r(0, 1), r(1, 1), r(2, 2), r(2, 2), r(4, 2), r(4, 2), r(6, 1), r(7, 1),
            r(8, 1), r(9, 1), r(0, 0), r(0, 0),
          ],
          lines: [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 2, 0],
          lineRanges: [r(0, 0), r(0, 7), r(7, 3), r(10, 0), r(0, 0), r(0, 0), r(0, 0)],
          insertionPointLines: [0, NSNotFound, 2]),
        TextCase(
          text: "first\nsecond",
          characters: [r(0, 0)] + (0..<12).map { r($0, 1) } + [r(0, 0), r(0, 0)],
          lines: [0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0],
          lineRanges: [r(0, 0), r(0, 6), r(6, 6), r(0, 0), r(0, 0), r(0, 0), r(0, 0)],
          insertionPointLines: [0, NSNotFound, 1]),
        TextCase(
          text: "日本語\n\n末尾",
          characters: [r(0, 0)] + (0..<7).map { r($0, 1) } + [r(0, 0), r(0, 0)],
          lines: [0, 0, 0, 0, 0, 1, 2, 2, 2, 0],
          lineRanges: [r(0, 0), r(0, 4), r(4, 1), r(5, 2), r(0, 0), r(0, 0), r(0, 0)],
          insertionPointLines: [0, NSNotFound, 2]),
      ]
    }()

    @Test(arguments: textCases)
    func textAttributesFollowCharactersAndLines(expected: TextCase) throws {
      let text = expected.text
      let (window, controller, view) = editor(text)
      defer {
        window.close()
        withExtendedLifetime(controller) {}
      }
      #expect(view.isAccessibilityElement())
      #expect(view.accessibilityRole() == .textArea)
      #expect(view.accessibilityValue() as? String == text)
      let length = text.utf16.count
      #expect(view.accessibilityNumberOfCharacters() == length)
      #expect((-1...(length + 1)).map { view.accessibilityRange(for: $0) } == expected.characters)
      #expect((-1...(length + 1)).map { view.accessibilityLine(for: $0) } == expected.lines)
      #expect((-1...5).map { view.accessibilityRange(forLine: $0) } == expected.lineRanges)
      #expect(view.accessibilityString(for: NSRange(location: 0, length: 0)) == "")
      #expect(view.accessibilityString(for: NSRange(location: 0, length: length)) == text)
      #expect(view.accessibilityString(for: NSRange(location: length, length: 0)) == "")
      // 本文からはみ出す範囲は読めない。
      for range in [
        NSRange(location: length, length: 1), NSRange(location: NSNotFound, length: 1),
        NSRange(location: 1, length: Int.max),
      ] {
        #expect(view.accessibilityString(for: range) == nil, "\(range)")
      }
      let selections = [
        NSRange(location: 0, length: 0), NSRange(location: 0, length: length),
        NSRange(location: length, length: 0),
      ]
      for (range, line) in zip(selections, expected.insertionPointLines) {
        view.setAccessibilitySelectedTextRange(range)
        #expect(view.accessibilitySelectedText() == (text as NSString).substring(with: range))
        #expect(view.accessibilitySelectedTextRange() == range)
        #expect(view.accessibilitySelectedTextRanges()?.map(\.rangeValue) == [range])
        #expect(view.accessibilityInsertionPointLineNumber() == line, "\(range)")
      }
    }

    @Test func attributedTextExposesStorageFontsAndThemeColors() throws {
      let state = makeState(text: "plain **bold** and `code`\n")
      let (window, controller, view) = editor(state: state)
      defer {
        window.close()
        withExtendedLifetime(controller) {}
      }
      let full = NSRange(location: 0, length: view.text.utf16.count)
      let actual = try #require(view.accessibilityAttributedString(for: full))
      #expect(actual.string == view.text)
      // 装飾の区切りごとに、書体と色の揃った範囲になる。
      let runs = [
        NSRange(location: 0, length: 6), NSRange(location: 6, length: 8),
        NSRange(location: 14, length: 5), NSRange(location: 19, length: 6),
        NSRange(location: 25, length: 1),
      ]
      let styles = (-1...full.length).map { view.accessibilityStyleRange(for: $0) }
      let empty = NSRange(location: 0, length: 0)
      #expect(styles == [empty] + runs.flatMap { Array(repeating: $0, count: $0.length) } + [empty])

      let foreground = state.theme.editorForeground
      let code = try #require(SyntaxPalette(theme: state.theme).style(for: .inlineCode).color)
      #expect(code != foreground)
      for (run, color) in zip(runs, [foreground, foreground, foreground, code, foreground]) {
        let attributes = actual.attributes(at: run.location, effectiveRange: nil)
        let font = try #require(
          attributes[.accessibilityFont] as? [NSAccessibility.FontAttributeKey: Any])
        let storageFont = try #require(
          view.layout.storage.attribute(.font, at: run.location, effectiveRange: nil) as? NSFont)
        #expect(font[.fontName] as? String == storageFont.fontName, "\(run)")
        #expect(font[.fontSize] as? CGFloat == storageFont.pointSize, "\(run)")
        // NSTextView と同じく、色空間は本文の色のもの (sRGB) から較正済み RGB に置き換わり、
        // 成分の値だけが引き継がれる。
        let value = try #require(attributes[.accessibilityForegroundColor])
        let components = try #require((value as! CGColor).components).map(Double.init)
        let expected = [color.red, color.green, color.blue, color.alpha]
        #expect(
          components.count == 4 && zip(components, expected).allSatisfy { abs($0 - $1) < 0.01 },
          "\(run) \(components) \(expected)")
        #expect(
          attributes[.accessibilityAlignment] as? Int == NSTextAlignment.left.rawValue, "\(run)")
      }
      #expect(view.accessibilityAttributedString(for: NSRange(location: 0, length: 0)) == nil)
      #expect(
        view.accessibilityAttributedString(for: NSRange(location: full.length, length: 1)) == nil)
    }

    @Test func multipleSelectionsExposePrimaryAndAllRanges() {
      let view = EditorView(text: "one two three")
      view.setFrameSize(NSSize(width: 400, height: 200))
      let ranges = [NSRange(location: 0, length: 3), NSRange(location: 8, length: 5)]
      view.select(ranges, primary: 1)
      #expect(view.accessibilitySelectedTextRange() == ranges[1])
      #expect(view.accessibilitySelectedText() == "three")
      #expect(view.accessibilitySelectedTextRanges()?.map(\.rangeValue) == ranges)
      #expect(view.accessibilityInsertionPointLineNumber() == NSNotFound)
      view.setAccessibilitySelectedTextRanges([
        NSValue(range: ranges[1]), NSValue(range: ranges[0]),
      ])
      #expect(view.accessibilitySelectedTextRanges()?.map(\.rangeValue) == ranges)
      #expect(view.accessibilitySelectedTextRange() == ranges[1])
      view.setAccessibilitySelectedText("X")
      #expect(view.text == "one two X")
      view.undo(nil)
      #expect(view.text == "one two three")
      #expect(view.accessibilitySelectedTextRanges()?.map(\.rangeValue) == ranges)
      #expect(view.accessibilitySelectedTextRange() == ranges[1])
      view.setAccessibilityValue("all")
      #expect(view.text == "all")
      #expect(
        view.accessibilitySelectedTextRanges()?.map(\.rangeValue) == [
          NSRange(location: 3, length: 0)
        ])
      view.undo(nil)
      #expect(view.text == "one two three")
      #expect(view.accessibilitySelectedTextRanges()?.map(\.rangeValue) == ranges)
      #expect(view.accessibilitySelectedTextRange() == ranges[1])
    }

    @Test(arguments: [false, true])
    func accessibilityEditsUndoOnce(replaceValue: Bool) {
      let (window, controller, view) = editor("abc def")
      defer {
        window.close()
        withExtendedLifetime(controller) {}
      }
      let range = NSRange(location: 4, length: 3)
      view.setAccessibilitySelectedTextRange(range)
      // 本文全体でも選択でも、置き換えた文字列の後ろにキャレットを置く。
      if replaceValue {
        view.setAccessibilityValue("new😀")
      } else {
        view.setAccessibilitySelectedText("new😀")
      }
      let (edited, end) = replaceValue ? ("new😀", 5) : ("abc new😀", 9)
      #expect(view.text == edited)
      #expect(view.selectedRange() == NSRange(location: end, length: 0))
      view.undo(nil)
      #expect(view.text == "abc def")
      #expect(view.selectedRange() == range)
      view.redo(nil)
      #expect(view.text == edited)
    }

    @Test func markedTextIsReadableAndWritable() {
      let (window, controller, view) = editor("start ")
      defer {
        window.close()
        withExtendedLifetime(controller) {}
      }
      view.setAccessibilitySelectedTextRange(NSRange(location: 6, length: 0))
      let missing = NSRange(location: NSNotFound, length: 0)
      view.setMarkedText(
        "にほん", selectedRange: NSRange(location: 1, length: 1), replacementRange: missing)
      #expect(view.hasMarkedText())
      // 変換中の文字も本文として読め、選択は変換中の文字の中の選択になる。
      #expect(view.accessibilityValue() as? String == "start にほん")
      #expect(view.accessibilityNumberOfCharacters() == 9)
      #expect(view.accessibilitySelectedText() == "ほ")
      #expect(view.accessibilitySelectedTextRange() == NSRange(location: 7, length: 1))
      view.setAccessibilitySelectedText("本")
      #expect(!view.hasMarkedText())
      #expect(view.text == "start に本ん")
      view.undo(nil)
      #expect(view.text == "start にほん")
    }

    @Test func wrappedLinesFramesAndVisibleRange() throws {
      let text = String(repeating: "abcdefghij ", count: 40) + "\n"
      let (window, controller, view) = editor(text, width: 180, height: 100)
      defer {
        window.close()
        withExtendedLifetime(controller) {}
      }
      let lines = view.layout.visualLines()
      #expect(lines.count > 10)
      #expect(lines.last?.range == NSRange(location: text.utf16.count, length: 0))
      var end = 0
      for (number, line) in lines.enumerated() {
        #expect(line.range.location == end)
        #expect(view.accessibilityRange(forLine: number) == line.range)
        #expect(view.accessibilityLine(for: line.range.location) == number)
        if line.range.length > 0 {
          #expect(view.accessibilityLine(for: NSMaxRange(line.range) - 1) == number)
        }
        end = NSMaxRange(line.range)
      }
      #expect(end == text.utf16.count)
      let range = NSRange(location: 1, length: 2)
      let local = try #require(view.layout.selectionRects(range).first)
        .offsetBy(dx: view.textOrigin.x, dy: view.textOrigin.y)
      #expect(
        view.accessibilityFrame(for: range) == window.convertToScreen(view.convert(local, to: nil)))
      let character = view.accessibilityFrame(for: NSRange(location: 1, length: 1))
      #expect(
        view.accessibilityRange(for: NSPoint(x: character.midX, y: character.midY))
          == NSRange(location: 1, length: 1))
      let severalLines = NSRange(
        location: lines[1].range.location,
        length: NSMaxRange(lines[3].range) - lines[1].range.location)
      let frame = view.accessibilityFrame(for: severalLines)
      #expect(frame.height > local.height * 2)
      let initial = view.accessibilityVisibleCharacterRange()
      #expect(initial.location == 0)
      #expect(initial.length > 0 && initial.length < text.utf16.count)
      controller.scrollView.contentView.scroll(
        to: NSPoint(x: 0, y: lines[5].frame.minY + view.textOrigin.y))
      controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
      let scrolled = view.accessibilityVisibleCharacterRange()
      #expect(scrolled.location == lines[5].range.location)
      #expect(scrolled.length > 0)
      view.withoutScrolling {
        view.setAccessibilitySelectedTextRange(
          NSRange(location: lines[6].range.location, length: 0))
      }
      #expect(view.accessibilityInsertionPointLineNumber() == 6)
      let caret = view.accessibilityFrame(for: view.selectedRange())
      #expect(caret.width == 0 && caret.height > 0)
    }

    @Test func notificationsFollowEditsSelectionsCompositionAndUndo() {
      let view = EditorView(text: "abc")
      view.setFrameSize(NSSize(width: 400, height: 200))
      var posted: [NSAccessibility.Notification] = []
      view.postAccessibilityNotification = { element, notification in
        #expect(element === view)
        posted.append(notification)
      }
      view.setAccessibilitySelectedTextRange(NSRange(location: 1, length: 1))
      #expect(posted == [.selectedTextChanged])
      posted = []
      view.setAccessibilitySelectedText("XYZ")
      #expect(posted == [.valueChanged, .selectedTextChanged])
      posted = []
      view.undo(nil)
      #expect(posted == [.valueChanged, .selectedTextChanged])
      posted = []
      view.setMarkedText(
        "仮", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(posted.contains(.valueChanged))
      #expect(posted.contains(.selectedTextChanged))
      view.unmarkText()
      posted = []
      view.replaceText("external")
      #expect(posted == [.valueChanged, .selectedTextChanged])
    }

    /// 合成文字やサロゲートペアの途中から始まる選択は、その文字の先頭から始める。
    @Test(arguments: ["a😀b", "ae\u{301}b"])
    func selectionStartsAtComposedCharacterBoundary(text: String) {
      let view = EditorView(text: text)
      for (range, expected) in [
        (NSRange(location: 2, length: 0), NSRange(location: 1, length: 0)),
        (NSRange(location: 2, length: 1), NSRange(location: 1, length: 2)),
        (NSRange(location: 2, length: 2), NSRange(location: 1, length: 3)),
      ] {
        view.setAccessibilitySelectedTextRange(range)
        #expect(view.selectedRange() == expected, "\(range)")
      }
      view.setAccessibilitySelectedTextRanges([
        NSValue(range: NSRange(location: 2, length: 0)),
        NSValue(range: NSRange(location: 4, length: 0)),
      ])
      #expect(
        view.accessibilitySelectedTextRanges()?.map(\.rangeValue) == [
          NSRange(location: 1, length: 0), NSRange(location: 4, length: 0),
        ])
    }

    /// 本文の左の余白は先頭の文字に当たり、右や上下の余白はどの文字にも当たらない。
    @Test func pointsInMarginsHitOnlyTheLeftInset() {
      let (window, controller, view) = editor("abc\ndef")
      defer {
        window.close()
        withExtendedLifetime(controller) {}
      }
      let first = view.accessibilityFrame(for: NSRange(location: 0, length: 1))
      let last = view.accessibilityFrame(for: NSRange(location: 6, length: 1))
      let empty = NSRange(location: 0, length: 0)
      for (point, expected) in [
        (NSPoint(x: first.maxX + 100, y: first.midY), empty),
        (NSPoint(x: first.minX - 10, y: first.midY), NSRange(location: 0, length: 1)),
        (NSPoint(x: first.midX, y: first.maxY + 10), empty),
        (NSPoint(x: last.midX, y: last.minY - 10), empty),
      ] {
        #expect(view.accessibilityRange(for: point) == expected, "\(point)")
      }
    }

    @Test func editingEarlierLineNotifiesMovedUTF16Selection() {
      let view = EditorView(text: "abc\ndef")
      view.select([NSRange(location: 5, length: 1)], primary: 0)
      var posted: [NSAccessibility.Notification] = []
      view.postAccessibilityNotification = { _, notification in posted.append(notification) }
      let replacement = EditorView.Replacement(NSRange(location: 0, length: 1), "abcd")
      #expect(view.replace([replacement], selecting: view.selections(after: [replacement])))
      #expect(view.selectedRange() == NSRange(location: 8, length: 1))
      #expect(posted == [.valueChanged, .selectedTextChanged])
      posted = []
      view.undo(nil)
      #expect(view.selectedRange() == NSRange(location: 5, length: 1))
      #expect(posted == [.valueChanged, .selectedTextChanged])
    }

    @Test func invalidWritesLeaveTextAndSelectionAlone() {
      let view = EditorView(text: "abc😀")
      let original = view.selectedRange()
      view.setAccessibilityValue(42)
      view.setAccessibilitySelectedText(nil)
      view.setAccessibilitySelectedTextRanges(nil)
      view.setAccessibilitySelectedTextRanges([])
      view.setAccessibilitySelectedTextRange(NSRange(location: NSNotFound, length: 0))
      view.setAccessibilitySelectedTextRange(NSRange(location: 4, length: Int.max))
      #expect(view.text == "abc😀")
      #expect(view.selectedRange() == original)
    }
  }
}
