import AppKit
import Testing

@testable import EdiroUI

extension AppKitTests {
  /// 支援技術に見せる本文・選択・属性を、同じ本文の参照 NSTextView と比べる。
  /// 既定のテストは期待する値を書いて確かめ、ここでは標準の振る舞いが OS の更新で
  /// 変わっていないかを見る。食い違ったら、標準に合わせるかを決めてから既定のテストを直す。
  ///
  /// EDIRO_INVENTORY=1 swift test --filter AccessibilityReferenceTests
  /// 属性の表し方 (色空間やフォントの表示名など) は OS やユーザーの言語で変わるので、
  /// 既定の `swift test` では走らせない。
  @Suite(.enabled(if: ProcessInfo.processInfo.environment["EDIRO_INVENTORY"] == "1"))
  struct AccessibilityReferenceTests {
    private func editor(_ text: String) -> (NSWindow, EditorTextController, EditorView) {
      let controller = EditorTextController(state: makeState(text: text))
      let window = NSWindow(
        contentRect: NSRect(x: 80, y: 100, width: 400, height: 300), styleMask: [.titled],
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

    /// 参照にはエディタと同じ属性の本文を入れ、属性の変換を比べる。
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
    }

    @Test(arguments: [false, true])
    func accessibilityEditsMatchReference(replaceValue: Bool) {
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
    }

    @Test func markedTextMatchesReference() {
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
      #expect(view.accessibilityValue() as? String == reference.textView.accessibilityValue())
      #expect(
        view.accessibilityNumberOfCharacters()
          == reference.textView.accessibilityNumberOfCharacters())
      #expect(view.accessibilitySelectedText() == reference.textView.accessibilitySelectedText())
      #expect(
        view.accessibilitySelectedTextRange() == reference.textView.accessibilitySelectedTextRange()
      )
    }

    @Test(arguments: ["a😀b", "ae\u{301}b"])
    func selectionBoundariesMatchReference(text: String) {
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
    }

    /// 余白の点を、それぞれのビューの文字の矩形から同じだけ離して置く。
    @Test func pointsInMarginsMatchReference() {
      let (window, controller, view) = editor("abc\ndef")
      defer {
        window.close()
        withExtendedLifetime(controller) {}
      }
      let reference = ReferenceTextView(text: view.text)
      defer { reference.close() }
      func points(_ frame: (NSRange) -> NSRect) -> [NSPoint] {
        let first = frame(NSRange(location: 0, length: 1))
        let last = frame(NSRange(location: 6, length: 1))
        return [
          NSPoint(x: first.maxX + 100, y: first.midY), NSPoint(x: first.minX - 10, y: first.midY),
          NSPoint(x: first.midX, y: first.maxY + 10), NSPoint(x: last.midX, y: last.minY - 10),
        ]
      }
      let actualPoints = points(view.accessibilityFrame(for:))
      let expectedPoints = points(reference.textView.accessibilityFrame(for:))
      for (actual, expected) in zip(actualPoints, expectedPoints) {
        #expect(
          view.accessibilityRange(for: actual)
            == reference.textView.accessibilityRange(for: expected))
      }
    }
  }
}
