import AppKit
import EdiroCore

/// SyntaxStyle を実際の NSFont に落とす。
public struct FontResolver {
  public let preferences: Preferences

  /// 斜体のシアー量。一般的なイタリック角に合わせた約 12 度。
  private static let slant = 0.22

  public init(preferences: Preferences) {
    self.preferences = preferences
  }

  public var bodyFont: NSFont {
    weighted(size: preferences.fontSize, bold: false)
  }

  public func font(for style: SyntaxStyle) -> NSFont {
    let size = preferences.fontSize * style.scale
    let base = weighted(size: size, bold: style.bold)
    return style.italic ? Self.slanted(base, size: size) : base
  }

  /// システムの等幅フォントでは weight を直接指定する。
  /// ディスクリプタに .bold トレイトを付けても Semibold にしかならず、
  /// 和文のフォールバック先が本文から一段しか太くならないため見分けが付かない。
  private func weighted(size: Double, bold: Bool) -> NSFont {
    guard !preferences.fontName.isEmpty,
      let named = NSFont(name: preferences.fontName, size: size)
    else {
      return .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
    guard bold else { return named }

    // withSymbolicTraits はマスクを合成せず置換するため、既存のトレイトに足す。
    let traits = named.fontDescriptor.symbolicTraits.union(.bold)
    return NSFont(descriptor: named.fontDescriptor.withSymbolicTraits(traits), size: size) ?? named
  }

  /// フォント行列を傾けて斜体にする。
  ///
  /// 和文には斜体の字面が無く、CoreText はフォールバック先へ slant を合成しない。
  /// 行列を傾ければフォールバックされたグリフごと傾く。グリフの送り幅と行高は
  /// 変わらないが、和文と欧文が隣接する箇所の詰めだけはわずかに動く。
  /// NSAttributedString の .obliqueness は TextKit 2 の NSTextView では無視される。
  private static func slanted(_ font: NSFont, size: Double) -> NSFont {
    var matrix = AffineTransform(scale: size)
    matrix.append(AffineTransform(m11: 1, m12: 0, m21: slant, m22: 1, tX: 0, tY: 0))
    return NSFont(descriptor: font.fontDescriptor.withMatrix(matrix), size: size) ?? font
  }
}
