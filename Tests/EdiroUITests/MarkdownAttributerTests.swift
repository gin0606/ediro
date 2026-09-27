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

      let beforeFont = before.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
      let afterFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
      #expect(
        recorder.ranges.isEmpty,
        "before: \(beforeFont?.fontDescriptor.fontAttributes ?? [:])\nafter: \(afterFont?.fontDescriptor.fontAttributes ?? [:])"
      )
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

    @Test(arguments: [
      "> 引用¦", "# 見出し¦", "> 引用\n¦", "# 見出し\n¦",
      "**太¦字**", "**太字**¦", "**¦太字**", "*斜¦体*", "*斜体*¦",
      "`co¦de`", "`code`¦", "[la¦bel](url)", "[label](url)¦",
      "- ¦item", "- item¦", "```\nco¦de\n```", "```\ncode\n```¦",
      "> **太¦字**", "# `co¦de`", "😀> 引用¦", "¦",
    ])
    func 入力位置の属性が通常文字を挿入した構文に一致する(marked: String) {
      let position = (marked as NSString).range(of: "¦").location
      let text = marked.replacingOccurrences(of: "¦", with: "")
      let attributer = MarkdownAttributer(theme: .fallback, preferences: .default)
      let attributes = attributer.typingAttributes(
        in: text, replacing: NSRange(location: position, length: 0))
      let candidate = (text as NSString).replacingCharacters(
        in: NSRange(location: position, length: 0), with: "a")
      let expected = NSTextStorage(string: candidate)
      attributer.apply(to: expected)
      #expect(
        NSDictionary(dictionary: attributes).isEqual(
          to: expected.attributes(at: position, effectiveRange: nil)))
    }

    @Test func 選択した構文記号の置換には元の装飾を引き継がない() {
      let attributer = MarkdownAttributer(theme: .fallback, preferences: .default)
      let body = attributer.typingAttributes(in: "", replacing: NSRange(location: 0, length: 0))
      for text in ["> 引用", "# 見出し", "**太字**", "*斜体*", "`code`", "[link](url)"] {
        for range in [
          NSRange(location: 0, length: 1), NSRange(location: 0, length: (text as NSString).length),
        ] {
          #expect(
            NSDictionary(dictionary: attributer.typingAttributes(in: text, replacing: range))
              .isEqual(to: body))
        }
      }
    }

    private func attributedFont(_ text: String, at substring: String) throws -> NSFont {
      let storage = NSTextStorage(string: text)
      MarkdownAttributer(theme: .fallback, preferences: .default).apply(to: storage)
      let range = (text as NSString).range(of: substring)
      try #require(range.location != NSNotFound)
      return try #require(
        storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
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
  }
}
