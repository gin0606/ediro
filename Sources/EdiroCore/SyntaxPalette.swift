import EditorMarkdown
import Foundation

/// Markdown の構文要素に割り当てる見た目。要素の中の要素は、外側の見た目に自分の性質を
/// 足した見た目になる (`inside(_:)`)。
public struct SyntaxStyle: Hashable, Sendable {
  /// nil なら外側の色を引き継ぐ。
  public let color: RGBA?
  public let bold: Bool
  public let italic: Bool
  public let monospaced: Bool
  /// 本文サイズに対する倍率。見出しだけが持ち、nil なら外側の大きさを引き継ぐ。
  public let scale: Double?

  public init(
    color: RGBA? = nil, bold: Bool = false, italic: Bool = false,
    monospaced: Bool = false, scale: Double? = nil
  ) {
    self.color = color
    self.bold = bold
    self.italic = italic
    self.monospaced = monospaced
    self.scale = scale
  }

  /// `outer` の要素の中にあるときの見た目。色と大きさは持っていれば自分のものを使い、
  /// 太字・斜体・等幅はどちらかが持てば付く。
  public func inside(_ outer: SyntaxStyle) -> SyntaxStyle {
    SyntaxStyle(
      color: color ?? outer.color, bold: bold || outer.bold, italic: italic || outer.italic,
      monospaced: monospaced || outer.monospaced, scale: scale ?? outer.scale)
  }
}

public struct SyntaxPalette: Sendable {
  public let theme: Theme

  public init(theme: Theme) {
    self.theme = theme
  }

  private var isDark: Bool { theme.appearance == .dark }

  private var accent: RGBA { isDark ? RGBA(hex: 0x4FC1FF) : RGBA(hex: 0x0069FF) }
  private var code: RGBA { isDark ? RGBA(hex: 0xCE9178) : RGBA(hex: 0xA31515) }
  private var muted: RGBA { isDark ? RGBA(hex: 0x8A8A8A) : RGBA(hex: 0x6E6E6E) }

  /// 太字と斜体は色を持たず、外側の色で描く。URL は見た目を何も足さない。
  public func style(for kind: MarkdownTokenKind) -> SyntaxStyle {
    switch kind {
    case .heading(let level):
      // 見出しは浅いほど大きく。
      let scale = 1.6 - (Double(min(max(level, 1), 6)) - 1) * 0.12
      return SyntaxStyle(color: accent, bold: true, scale: scale)
    case .strong:
      return SyntaxStyle(bold: true)
    case .emphasis:
      return SyntaxStyle(italic: true)
    case .inlineCode, .codeBlock:
      return SyntaxStyle(color: code, monospaced: true)
    case .link:
      return SyntaxStyle(color: accent)
    case .listMarker:
      return SyntaxStyle(color: accent, bold: true)
    case .blockquote:
      return SyntaxStyle(color: muted, italic: true)
    case .url:
      return SyntaxStyle()
    }
  }
}
