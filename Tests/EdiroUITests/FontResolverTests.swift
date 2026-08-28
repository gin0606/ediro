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
