import Foundation
import Testing
import TestSupport

@testable import EdiroCore

private func makeDefaults() -> InMemoryStore { InMemoryStore() }

// キー名は既存ユーザーの UserDefaults に残っている設定との互換の契約なので、
// 実装の定数ではなく文字列で固定する。
@Test func 既存ユーザーの設定をキー名で読み込める() {
  let defaults = InMemoryStore([
    "theme": "aesthetic-wave", "fontSize": 20.0, "fontName": "Menlo-Regular", "tabSize": 2
  ])
  #expect(
    Preferences.load(from: defaults)
      == Preferences(themeID: "aesthetic-wave", fontSize: 20, fontName: "Menlo-Regular", tabSize: 2))
}

@Test func 設定は読み込みと同じキー名で保存される() {
  let defaults = makeDefaults()
  Preferences(themeID: "aesthetic-wave", fontSize: 20, fontName: "Menlo-Regular", tabSize: 2)
    .save(to: defaults)

  #expect(defaults.string(forKey: "theme") == "aesthetic-wave")
  #expect(defaults.double(forKey: "fontSize") == 20)
  #expect(defaults.string(forKey: "fontName") == "Menlo-Regular")
  #expect(defaults.integer(forKey: "tabSize") == 2)
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
