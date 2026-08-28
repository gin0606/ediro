import Testing

@testable import EdiroCore

@Test func hexから色成分を復元する() {
  let color = RGBA(hex: 0x5433FF)
  #expect(abs(color.red - 84.0 / 255) < 0.0001)
  #expect(abs(color.green - 51.0 / 255) < 0.0001)
  #expect(abs(color.blue - 255.0 / 255) < 0.0001)
}

@Test func テーマIDは重複しない() {
  #expect(Set(Theme.all.map(\.id)).count == Theme.all.count)
}

@Test func 未知のIDは既定テーマにフォールバックする() {
  #expect(Theme.theme(id: "存在しない") == Theme.fallback)
  #expect(Theme.theme(id: "aesthetic").name == "Aesthetic")
}

@Test func 明暗に応じてエディタの前景と背景が入れ替わる() {
  let dark = Theme.theme(id: "dark")
  let light = Theme.theme(id: "light")
  #expect(dark.editorBackground.red < 0.5)
  #expect(light.editorBackground.red > 0.5)
}

@Test func 見出しは浅いほど大きい() {
  let palette = SyntaxPalette(theme: .fallback)
  let h1 = palette.style(for: .heading(level: 1)).scale
  let h3 = palette.style(for: .heading(level: 3)).scale
  #expect(h1 > h3)
  #expect(h3 > 1)
}

@Test func コード要素は等幅で描画する() {
  let palette = SyntaxPalette(theme: .fallback)
  #expect(palette.style(for: .inlineCode).monospaced)
  #expect(palette.style(for: .codeBlock).monospaced)
}

@Test func 既定テーマは並び順ではなくIDで決まる() {
  #expect(Theme.fallback.id == "dark-grad")
  #expect(Preferences.default.themeID == "dark-grad")
}
