import Foundation

/// 永続化する設定値。本文以外はここに収まる。
public struct Preferences: Equatable, Sendable {
  public var themeID: String
  public var fontSize: Double
  /// 空文字はシステム既定のフォントを使う意味。
  public var fontName: String
  public var tabSize: Int

  public static let `default` = Preferences(
    themeID: Theme.fallback.id, fontSize: 13, fontName: "", tabSize: 4)

  public static let fontSizeRange: ClosedRange<Double> = 10...100
  public static let tabSizeRange: ClosedRange<Int> = 1...10

  public init(themeID: String, fontSize: Double, fontName: String, tabSize: Int) {
    self.themeID = themeID
    self.fontSize = fontSize
    self.fontName = fontName
    self.tabSize = tabSize
  }

  public var theme: Theme { Theme.theme(id: themeID) }

  /// 範囲外の値を丸める。フォントサイズはメニューからも増減できるため、
  /// 表示側ではなくここで一箇所に寄せる。
  public mutating func clamp() {
    fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    tabSize = min(max(tabSize, Self.tabSizeRange.lowerBound), Self.tabSizeRange.upperBound)
    if Theme.all.allSatisfy({ $0.id != themeID }) {
      themeID = Theme.fallback.id
    }
  }
}

extension Preferences {
  private enum Key {
    static let theme = "theme"
    static let fontSize = "fontSize"
    static let fontName = "fontName"
    static let tabSize = "tabSize"
  }

  /// 設定の置き場所は外界なので、欠けた値・壊れた値は既定値で補う。
  public static func load(from defaults: some KeyValueStore) -> Preferences {
    var preferences = Preferences.default
    if let theme = defaults.string(forKey: Key.theme) { preferences.themeID = theme }
    if defaults.object(forKey: Key.fontSize) != nil {
      preferences.fontSize = defaults.double(forKey: Key.fontSize)
    }
    if let font = defaults.string(forKey: Key.fontName) { preferences.fontName = font }
    if defaults.object(forKey: Key.tabSize) != nil {
      preferences.tabSize = defaults.integer(forKey: Key.tabSize)
    }
    preferences.clamp()
    return preferences
  }

  public func save(to defaults: some KeyValueStore) {
    defaults.set(themeID, forKey: Key.theme)
    defaults.set(fontSize, forKey: Key.fontSize)
    defaults.set(fontName, forKey: Key.fontName)
    defaults.set(tabSize, forKey: Key.tabSize)
  }
}
