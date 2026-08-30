import Foundation
import Testing
import TestSupport

@testable import EdiroCore

private func makeDefaults() -> InMemoryStore { InMemoryStore() }

@Test func 保存した設定を読み戻せる() {
  let defaults = makeDefaults()
  var preferences = Preferences.default
  preferences.themeID = "aesthetic-wave"
  preferences.fontSize = 20
  preferences.fontName = "Menlo-Regular"
  preferences.tabSize = 2
  preferences.save(to: defaults)

  #expect(Preferences.load(from: defaults) == preferences)
}

@Test func 未保存の状態では既定値になる() {
  #expect(Preferences.load(from: makeDefaults()) == .default)
}

@Test func 範囲外の値を丸める() {
  var preferences = Preferences.default
  preferences.fontSize = 999
  preferences.tabSize = 0
  preferences.clamp()
  #expect(preferences.fontSize == 100)
  #expect(preferences.tabSize == 1)
}

@Test func 存在しないテーマIDは既定テーマに戻す() {
  let defaults = makeDefaults()
  defaults.set("no-such-theme", forKey: "theme")
  #expect(Preferences.load(from: defaults).themeID == Theme.fallback.id)
}
