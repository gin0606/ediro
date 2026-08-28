import AppKit

/// Preferences のフォント一覧。
public struct FontCatalog {
  public struct Entry: Identifiable, Hashable {
    public let postScriptName: String
    public let displayName: String
    public let isMonospaced: Bool
    public var id: String { postScriptName }
  }

  public let monospaced: [Entry]
  public let proportional: [Entry]

  public init() {
    let manager = NSFontManager.shared
    var entries: [Entry] = []

    for family in manager.availableFontFamilies {
      guard let font = NSFont(name: family, size: 12) else { continue }
      entries.append(
        Entry(
          postScriptName: font.fontName,
          displayName: family,
          isMonospaced: font.isFixedPitch))
    }

    entries.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    monospaced = entries.filter(\.isMonospaced)
    proportional = entries.filter { !$0.isMonospaced }
  }
}
