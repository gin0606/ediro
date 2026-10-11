import AppKit
import EdiroCore
import EditorEngine
import EditorMarkdown
import Testing

@testable import EdiroUI

extension AppKitTests {
  struct MarkdownAttributerTests {
    final class EditRecorder: NSObject, NSTextStorageDelegate {
      var ranges: [NSRange] = []

      func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
      ) {
        ranges.append(editedRange)
      }
    }

    @Test func 指定した行だけ装飾を当て直す() {
      let text = "# 見出し\n本文と**太字**\n> 引用"
      let document = Document(id: "lines", text: text, lineTokenizer: MarkdownTokenizer())
      let storage = NSTextStorage(string: text)
      let recorder = EditRecorder()
      storage.delegate = recorder
      let attributer = MarkdownAttributer(theme: .fallback, preferences: .default)
      let untouched = NSAttributedString(attributedString: storage)

      attributer.apply(lines: IndexSet(integer: 1), of: document, to: storage)

      let line = (text as NSString).range(of: "本文と**太字**\n")
      #expect(recorder.ranges == [line])
      for other in [NSRange(location: 0, length: line.location), NSRange(location: NSMaxRange(line), length: storage.length - NSMaxRange(line))] {
        #expect(storage.attributedSubstring(from: other).isEqual(to: untouched.attributedSubstring(from: other)))
      }
      let expected = highlighted(text)
      #expect(
        storage.attributedSubstring(from: line).isEqual(to: expected.attributedSubstring(from: line)))
    }

    private func attributedFont(
      _ text: String, at substring: String, preferences: Preferences = .default
    ) throws -> NSFont {
      let storage = highlighted(text, preferences: preferences)
      let range = (text as NSString).range(of: substring)
      try #require(range.location != NSNotFound)
      return try #require(
        storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    private func attributedColor(_ text: String, at substring: String) throws -> NSColor {
      let storage = highlighted(text)
      let range = (text as NSString).range(of: substring)
      try #require(range.location != NSNotFound)
      return try #require(
        storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
    }

    @Test func 見出しは本文より大きいフォントになる() throws {
      let text = "# 見出し\n本文"
      let heading = try attributedFont(text, at: "# 見出し")
      let body = try attributedFont(text, at: "本文")
      #expect(heading.pointSize > body.pointSize)
    }

    @Test func 引用の文字サイズは本文と同じ() throws {
      let text = "> 引用文\n本文"
      let quote = try attributedFont(text, at: "引用文")
      let body = try attributedFont(text, at: "本文")
      #expect(
        quote.pointSize == body.pointSize,
        "quote: \(quote.pointSize), body: \(body.pointSize)")
    }

    @Test func 装飾のない本文は既定の前景色になる() throws {
      let color = try attributedColor("ただの本文です", at: "ただの")
      let expected = Theme.fallback.editorForeground.nsColor
      #expect(abs(color.redComponent - expected.redComponent) < 0.01)
    }

    @Test func インラインコードには専用の色が付く() throws {
      let code = try attributedColor("実行は `swift test` で", at: "`swift test`")
      let body = try attributedColor("実行は `swift test` で", at: "実行は")
      #expect(code != body)
    }

    /// 本文が等幅でない設定。既定の本文は等幅で、コードと書体では見分けられない。
    private var proportional: Preferences {
      var preferences = Preferences.default
      preferences.fontName = "Helvetica"
      return preferences
    }

    @Test func コードブロックは空行と改行まで等幅の書体になる() throws {
      // 空行の高さを周りのコードの行と揃えるため、改行にもコードの書体を付ける。
      let text = "```\na\n\nb\n```\nplain"
      let storage = highlighted(text, preferences: proportional)
      let code = try attributedFont(text, at: "a", preferences: proportional)
      for location in [3, 5, 6, 8] {
        let font = try #require(storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch && font.pointSize == code.pointSize, "\(location)")
      }
      #expect(try !attributedFont(text, at: "plain", preferences: proportional).isFixedPitch)
    }

    @Test func 閉じていないコードブロックは文書の末尾まで続く() throws {
      let text = "plain\n```\n# not a heading\n**not bold**"
      #expect(try attributedFont(text, at: "not a heading", preferences: proportional).isFixedPitch)
      #expect(try attributedFont(text, at: "not bold", preferences: proportional).isFixedPitch)
      #expect(try !attributedFont(text, at: "plain", preferences: proportional).isFixedPitch)
    }
  }
}
