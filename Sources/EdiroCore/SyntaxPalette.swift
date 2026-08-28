import Foundation

/// Markdown の構文要素に割り当てる見た目。
public struct SyntaxStyle: Equatable, Sendable {
  public let color: RGBA
  public let bold: Bool
  public let italic: Bool
  public let monospaced: Bool
  /// 本文サイズに対する倍率。見出しだけ 1 より大きくなる。
  public let scale: Double

  public init(
    color: RGBA, bold: Bool = false, italic: Bool = false,
    monospaced: Bool = false, scale: Double = 1
  ) {
    self.color = color
    self.bold = bold
    self.italic = italic
    self.monospaced = monospaced
    self.scale = scale
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

  public func style(for kind: Token.Kind) -> SyntaxStyle {
    switch kind {
    case .heading(let level):
      // 見出しは浅いほど大きく。
      let scale = 1.6 - (Double(min(max(level, 1), 6)) - 1) * 0.12
      return SyntaxStyle(color: accent, bold: true, scale: scale)
    case .strong:
      return SyntaxStyle(color: theme.editorForeground, bold: true)
    case .emphasis:
      return SyntaxStyle(color: theme.editorForeground, italic: true)
    case .inlineCode, .codeBlock:
      return SyntaxStyle(color: code, monospaced: true)
    case .link:
      return SyntaxStyle(color: accent)
    case .listMarker:
      return SyntaxStyle(color: accent, bold: true)
    case .blockquote:
      return SyntaxStyle(color: muted, italic: true)
    }
  }
}
