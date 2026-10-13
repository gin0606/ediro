import AppKit
import Testing

@testable import EdiroUI

extension AppKitTests {
  struct AccessibilityTests {
    private func editor(_ text: String, width: CGFloat = 400, height: CGFloat = 300)
      -> (NSWindow, EditorTextController, EditorView)
    {
      let controller = EditorTextController(state: makeState(text: text))
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

    @Test(arguments: ["", "abc", "ab😀e\u{301}\ncd\n", "first\nsecond", "日本語\n\n末尾"])
    func textAttributesMatchReference(text: String) throws {
      let (window, controller, view) = editor(text)
      defer {
        window.close()
        withExtendedLifetime(controller) {}
      }
      let reference = ReferenceTextView(text: text)
      defer { reference.close() }
      let expected = reference.textView
      #expect(view.isAccessibilityElement())
      #expect(view.accessibilityRole() == expected.accessibilityRole())
      #expect(view.accessibilityValue() as? String == expected.accessibilityValue())
      #expect(view.accessibilityNumberOfCharacters() == expected.accessibilityNumberOfCharacters())
      let length = text.utf16.count
      for index in -1...(length + 1) {
        #expect(view.accessibilityRange(for: index) == expected.accessibilityRange(for: index))
        #expect(view.accessibilityLine(for: index) == expected.accessibilityLine(for: index))
      }
      for line in -1...5 {
        #expect(
          view.accessibilityRange(forLine: line) == expected.accessibilityRange(forLine: line))
      }
      for range in [
        NSRange(location: 0, length: 0), NSRange(location: 0, length: length),
        NSRange(location: length, length: 0), NSRange(location: length, length: 1),
        NSRange(location: NSNotFound, length: 1), NSRange(location: 1, length: Int.max),
      ] {
        #expect(view.accessibilityString(for: range) == expected.accessibilityString(for: range))
      }
      let selections = [
        NSRange(location: 0, length: 0), NSRange(location: 0, length: length),
        NSRange(location: length, length: 0),
      ]
      for range in selections {
        view.setAccessibilitySelectedTextRange(range)
        expected.setAccessibilitySelectedTextRange(range)
        #expect(view.accessibilitySelectedText() == expected.accessibilitySelectedText())
        #expect(view.accessibilitySelectedTextRange() == expected.accessibilitySelectedTextRange())
        #expect(
          view.accessibilitySelectedTextRanges() == expected.accessibilitySelectedTextRanges())
        #expect(
          view.accessibilityInsertionPointLineNumber()
            == expected.accessibilityInsertionPointLineNumber())
      }
    }

    @Test func attributedTextAndStylesMatchReference() throws {
      let (window, controller, view) = editor("plain **bold** and `code`\n")
      defer {
        window.close()
        withExtendedLifetime(controller) {}
      }
      let reference = ReferenceTextView(text: view.text)
      defer { reference.close() }
      reference.textView.textStorage?.setAttributedString(view.layout.storage)
      let full = NSRange(location: 0, length: view.text.utf16.count)
      let actual = try #require(view.accessibilityAttributedString(for: full))
      let expected = try #require(reference.textView.accessibilityAttributedString(for: full))
      #expect(actual == expected)
      for index in -1...full.length {
        #expect(
          view.accessibilityStyleRange(for: index)
            == reference.textView.accessibilityStyleRange(for: index))
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
      let reference = ReferenceTextView(text: view.text)
      defer { reference.close() }
      let range = NSRange(location: 4, length: 3)
      view.setAccessibilitySelectedTextRange(range)
      reference.textView.setAccessibilitySelectedTextRange(range)
      if replaceValue {
        view.setAccessibilityValue("new😀")
        reference.textView.setAccessibilityValue("new😀")
      } else {
        view.setAccessibilitySelectedText("new😀")
        reference.textView.setAccessibilitySelectedText("new😀")
      }
      #expect(view.text == reference.textView.string)
      #expect(view.selectedRange() == reference.textView.selectedRange())
      view.undo(nil)
      #expect(view.text == "abc def")
      #expect(view.selectedRange() == range)
      view.redo(nil)
      #expect(view.text == reference.textView.string)
    }

    @Test func markedTextIsReadableAndWritable() {
      let (window, controller, view) = editor("start ")
      defer {
        window.close()
        withExtendedLifetime(controller) {}
      }
      let reference = ReferenceTextView(text: view.text)
      defer { reference.close() }
      let range = NSRange(location: 6, length: 0)
      view.setAccessibilitySelectedTextRange(range)
      reference.textView.setAccessibilitySelectedTextRange(range)
      let missing = NSRange(location: NSNotFound, length: 0)
      view.setMarkedText(
        "にほん", selectedRange: NSRange(location: 1, length: 1), replacementRange: missing)
      reference.textView.setMarkedText(
        "にほん", selectedRange: NSRange(location: 1, length: 1), replacementRange: missing)
      #expect(view.hasMarkedText())
      #expect(view.accessibilityValue() as? String == "start にほん")
      #expect(view.accessibilityValue() as? String == reference.textView.accessibilityValue())
      #expect(
        view.accessibilityNumberOfCharacters()
          == reference.textView.accessibilityNumberOfCharacters())
      #expect(view.accessibilitySelectedText() == reference.textView.accessibilitySelectedText())
      #expect(
        view.accessibilitySelectedTextRange() == reference.textView.accessibilitySelectedTextRange()
      )
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

    @Test(arguments: ["a😀b", "ae\u{301}b"])
    func selectionStartsAtComposedCharacterBoundary(text: String) {
      let view = EditorView(text: text)
      let reference = ReferenceTextView(text: text)
      defer { reference.close() }
      for range in [
        NSRange(location: 2, length: 0), NSRange(location: 2, length: 1),
        NSRange(location: 2, length: 2),
      ] {
        view.setAccessibilitySelectedTextRange(range)
        reference.textView.setAccessibilitySelectedTextRange(range)
        #expect(view.selectedRange() == reference.textView.selectedRange())
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

    @Test func pointsInMarginsMatchReference() {
      let (window, controller, view) = editor("abc\ndef")
      defer {
        window.close()
        withExtendedLifetime(controller) {}
      }
      let reference = ReferenceTextView(text: view.text)
      defer { reference.close() }
      let actualFirst = view.accessibilityFrame(for: NSRange(location: 0, length: 1))
      let expectedFirst = reference.textView.accessibilityFrame(
        for: NSRange(location: 0, length: 1))
      let actualLast = view.accessibilityFrame(for: NSRange(location: 6, length: 1))
      let expectedLast = reference.textView.accessibilityFrame(for: NSRange(location: 6, length: 1))
      let points = [
        (
          NSPoint(x: actualFirst.maxX + 100, y: actualFirst.midY),
          NSPoint(x: expectedFirst.maxX + 100, y: expectedFirst.midY)
        ),
        (
          NSPoint(x: actualFirst.minX - 10, y: actualFirst.midY),
          NSPoint(x: expectedFirst.minX - 10, y: expectedFirst.midY)
        ),
        (
          NSPoint(x: actualFirst.midX, y: actualFirst.maxY + 10),
          NSPoint(x: expectedFirst.midX, y: expectedFirst.maxY + 10)
        ),
        (
          NSPoint(x: actualLast.midX, y: actualLast.minY - 10),
          NSPoint(x: expectedLast.midX, y: expectedLast.minY - 10)
        ),
      ]
      for (index, pair) in points.enumerated() {
        let range = NSRange(location: 0, length: index == 1 ? 1 : 0)
        #expect(reference.textView.accessibilityRange(for: pair.1) == range)
        #expect(view.accessibilityRange(for: pair.0) == range)
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
