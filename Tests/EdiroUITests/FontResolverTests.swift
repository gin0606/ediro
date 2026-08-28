import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

private func traits(_ font: NSFont) -> NSFontDescriptor.SymbolicTraits {
  font.fontDescriptor.symbolicTraits
}

@Test func 強調スタイルは実際に太字のフォントになる() {
  let palette = SyntaxPalette(theme: .fallback)
  let resolver = FontResolver(preferences: .default)
  let font = resolver.font(for: palette.style(for: .strong))
  #expect(traits(font).contains(.bold))
}

@Test func 斜体スタイルは実際に斜体のフォントになる() {
  let palette = SyntaxPalette(theme: .fallback)
  let resolver = FontResolver(preferences: .default)
  let font = resolver.font(for: palette.style(for: .emphasis))
  #expect(traits(font).contains(.italic))
}

@Test func 見出しは本文より大きく太い() {
  let palette = SyntaxPalette(theme: .fallback)
  let resolver = FontResolver(preferences: .default)
  let heading = resolver.font(for: palette.style(for: .heading(level: 1)))
  #expect(heading.pointSize > resolver.bodyFont.pointSize)
  #expect(traits(heading).contains(.bold))
}

@Test func フォント名が空なら等幅のシステムフォントを使う() {
  #expect(traits(FontResolver(preferences: .default).bodyFont).contains(.monoSpace))
}

@Test func 指定したフォント名を尊重する() {
  var preferences = Preferences.default
  preferences.fontName = "Menlo-Regular"
  #expect(FontResolver(preferences: preferences).bodyFont.fontName == "Menlo-Regular")
}
