import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

extension AppKitTests {
  struct MarkdownAttributerTests {
    private final class EditRecorder: NSObject, NSTextStorageDelegate {
      var ranges: [NSRange] = []

      func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
      ) {
        ranges.append(editedRange)
      }
    }

    @Test func 同じハイライトを掛け直してもレイアウトを無効にしない() {
      let storage = NSTextStorage(string: "# 見出し\n本文と**太字**\n")
      let attributer = MarkdownAttributer(theme: .fallback, preferences: .default)
      attributer.apply(to: storage)
      let recorder = EditRecorder()
      storage.delegate = recorder
      let before = NSAttributedString(attributedString: storage)

      attributer.apply(to: storage)

      #expect(recorder.ranges.isEmpty, "before: \(before)\nafter: \(storage)")
    }

    @Test func 長文の下部の書式変更で上部を無効にしない() {
      let prefix = String(repeating: "# 見出し\n本文と**太字**です。\n", count: 500)
      let storage = NSTextStorage(string: prefix + "末尾の本文\n後続の本文")
      let attributer = MarkdownAttributer(theme: .fallback, preferences: .default)
      attributer.apply(to: storage)
      let location = (prefix as NSString).length
      storage.replaceCharacters(in: NSRange(location: location, length: 0), with: "# ")
      let recorder = EditRecorder()
      storage.delegate = recorder

      attributer.apply(to: storage)

      #expect(recorder.ranges.count == 1)
      #expect(recorder.ranges.allSatisfy { $0.location >= location })
      #expect(storage.string == prefix + "# 末尾の本文\n後続の本文")
      let expected = NSTextStorage(string: storage.string)
      attributer.apply(to: expected)
      #expect(storage.isEqual(to: expected))

      storage.replaceCharacters(in: NSRange(location: location, length: 2), with: "")
      attributer.apply(to: storage)
      let restored = NSTextStorage(string: prefix + "末尾の本文\n後続の本文")
      attributer.apply(to: restored)
      #expect(storage.isEqual(to: restored))
    }

    private func attributedFont(_ text: String, at substring: String) throws -> NSFont {
      let storage = NSTextStorage(string: text)
      MarkdownAttributer(theme: .fallback, preferences: .default).apply(to: storage)
      let range = (text as NSString).range(of: substring)
      try #require(range.location != NSNotFound)
      return try #require(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    private func attributedColor(_ text: String, at substring: String) throws -> NSColor {
      let storage = NSTextStorage(string: text)
      MarkdownAttributer(theme: .fallback, preferences: .default).apply(to: storage)
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
  }
}
