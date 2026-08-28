import AppKit
import EdiroCore

/// 書体の解決結果。太い字面を持たないフォントでは、描画側で太らせる必要がある。
public struct ResolvedFont {
  public let font: NSFont
  public let needsSyntheticBold: Bool
}

/// SyntaxStyle を実際の NSFont に落とす。
public struct FontResolver {
  public let preferences: Preferences

  /// 斜体のシアー量。一般的なイタリック角に合わせた約 12 度。
  private static let slant = 0.22

  public init(preferences: Preferences) {
    self.preferences = preferences
  }

  public var bodyFont: NSFont {
    weighted(size: preferences.fontSize, bold: false).font
  }

  public func resolve(for style: SyntaxStyle) -> ResolvedFont {
    let size = preferences.fontSize * style.scale
    let base = weighted(size: size, bold: style.bold, monospaced: style.monospaced)
    guard style.italic else { return base }
    return ResolvedFont(
      font: Self.slanted(base.font, size: size), needsSyntheticBold: base.needsSyntheticBold)
  }

  /// システムの等幅フォントでは weight を直接指定する。
  /// ディスクリプタに .bold トレイトを付けても Semibold にしかならず、
  /// 和文のフォールバック先が本文から一段しか太くならないため見分けが付かない。
  ///
  /// `monospaced` の要素は、本文にプロポーショナルなフォントが選ばれていても
  /// 等幅で描く。コードの桁が揃わないと下書きとして読めなくなるため。
  private func weighted(size: Double, bold: Bool, monospaced: Bool = false) -> ResolvedFont {
    guard !preferences.fontName.isEmpty,
      let named = NSFont(name: preferences.fontName, size: size),
      !monospaced || named.isFixedPitch
    else {
      // 等幅システムフォントは和文の字面を持たず、和文はシステムのフォールバックが
      // 描く。解決先は各マシンの構成で決まる。和文の送りは全角の 1em で、この
      // フォントの欧文 0.618em の 2 倍に足りないため、和文と欧文の桁は揃わない。
      // 揃えたい場合は欧文を和文の半分の送りで持つフォント (BIZ UDGothic 等) を
      // Preferences で選ぶ。
      return ResolvedFont(
        font: .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular),
        needsSyntheticBold: false)
    }
    guard bold else { return ResolvedFont(font: named, needsSyntheticBold: false) }

    // withSymbolicTraits はマスクを合成せず置換するため、既存のトレイトに足す。
    let traits = named.fontDescriptor.symbolicTraits.union(.bold)
    let resolved = NSFont(descriptor: named.fontDescriptor.withSymbolicTraits(traits), size: size)

    // 太い字面を持たないフォントでは、AppKit は変換に失敗するか同じ書体を返す。
    // 一般的な描画系と同じく、字面が無ければ縁を太らせて合成する。
    guard let resolved, resolved.fontName != named.fontName else {
      return ResolvedFont(font: named, needsSyntheticBold: true)
    }
    return ResolvedFont(font: resolved, needsSyntheticBold: false)
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
