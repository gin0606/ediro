import AppKit
import EdiroCore

/// SyntaxStyle を実際の NSFont に落とす。
///
/// トレイトの付与に NSFontManager.convert は使わない。システムの等幅フォントに
/// 対しては該当する書体を見つけられず、変換前のフォントをそのまま返してしまい、
/// 太字・斜体が無言で効かなくなるため。フォントディスクリプタで指定する。
public struct FontResolver {
  public let preferences: Preferences

  public init(preferences: Preferences) {
    self.preferences = preferences
  }

  public var bodyFont: NSFont {
    font(named: preferences.fontName, size: preferences.fontSize)
  }

  public func font(for style: SyntaxStyle) -> NSFont {
    let size = preferences.fontSize * style.scale
    let base =
      style.monospaced
      ? NSFont.monospacedSystemFont(ofSize: size, weight: style.bold ? .bold : .regular)
      : font(named: preferences.fontName, size: size)

    var traits: NSFontDescriptor.SymbolicTraits = []
    if style.bold { traits.insert(.bold) }
    if style.italic { traits.insert(.italic) }
    guard !traits.isEmpty else { return base }

    let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: descriptor, size: size) ?? base
  }

  private func font(named name: String, size: Double) -> NSFont {
    if !name.isEmpty, let font = NSFont(name: name, size: size) { return font }
    return .monospacedSystemFont(ofSize: size, weight: .regular)
  }
}
