import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

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
