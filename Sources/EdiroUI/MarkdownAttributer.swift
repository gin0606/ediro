import AppKit
import EdiroCore

/// Markdown のトークンを NSTextStorage の属性に反映する。
public struct MarkdownAttributer {
  /// 合成した太字の濃さ。実際のボールド字面と同程度になる値。
  static let syntheticBoldStroke = -5.0

  private let theme: Theme
  private let preferences: Preferences
  private let highlighter = MarkdownHighlighter.shared
  private let resolver: FontResolver

  public init(theme: Theme, preferences: Preferences) {
    self.theme = theme
    self.preferences = preferences
    self.resolver = FontResolver(preferences: preferences)
  }

  public func apply(to storage: NSTextStorage) {
    let text = storage.string
    let full = NSRange(location: 0, length: (text as NSString).length)
    let palette = SyntaxPalette(theme: theme)

    storage.setAttributes(
      [
        .font: resolver.bodyFont,
        .foregroundColor: theme.editorForeground.nsColor,
        .paragraphStyle: ParagraphStyle.make(for: preferences),
      ], range: full)

    for token in highlighter.tokens(in: text) {
      let style = palette.style(for: token.kind)
      let resolved = resolver.resolve(for: style)
      var attributes: [NSAttributedString.Key: Any] = [
        .font: resolved.font, .foregroundColor: style.color.nsColor,
      ]
      if resolved.needsSyntheticBold {
        // 負の値は塗りと縁の両方を描く。縁の色を前景と揃えて太さだけを足す。
        attributes[.strokeWidth] = Self.syntheticBoldStroke
        attributes[.strokeColor] = style.color.nsColor
      }
      storage.addAttributes(attributes, range: token.range)
    }
  }
}
