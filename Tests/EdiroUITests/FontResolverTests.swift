import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

private func traits(_ font: NSFont) -> NSFontDescriptor.SymbolicTraits {
  font.fontDescriptor.symbolicTraits
}

@Test func 見出しは本文より大きく太い() {
  let palette = SyntaxPalette(theme: .fallback)
  let resolver = FontResolver(preferences: .default)
  let heading = resolver.resolve(for: palette.style(for: .heading(level: 1))).font
  #expect(heading.pointSize > resolver.bodyFont.pointSize)
}

@Test func フォント名が空なら等幅のシステムフォントを使う() {
  #expect(traits(FontResolver(preferences: .default).bodyFont).contains(.monoSpace))
}

@Test func 指定したフォント名を尊重する() {
  var preferences = Preferences.default
  preferences.fontName = "Menlo-Regular"
  #expect(FontResolver(preferences: preferences).bodyFont.fontName == "Menlo-Regular")
}

@Test func コード要素はプロポーショナルなフォントを選んでも等幅で描く() throws {
  var preferences = Preferences.default
  preferences.fontName = "Helvetica"
  try #require(NSFont(name: "Helvetica", size: 13)?.isFixedPitch == false)

  let resolver = FontResolver(preferences: preferences)
  let palette = SyntaxPalette(theme: .fallback)
  #expect(resolver.bodyFont.fontName == "Helvetica")
  #expect(resolver.resolve(for: palette.style(for: .inlineCode)).font.isFixedPitch)
  #expect(resolver.resolve(for: palette.style(for: .codeBlock)).font.isFixedPitch)
}

@Test func 等幅フォントを選んでいればコード要素もそのフォントを使う() {
  var preferences = Preferences.default
  preferences.fontName = "Menlo-Regular"
  let palette = SyntaxPalette(theme: .fallback)
  let code = FontResolver(preferences: preferences).resolve(for: palette.style(for: .inlineCode))
  #expect(code.font.fontName == "Menlo-Regular")
}
