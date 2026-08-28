import AppKit
import EdiroCore

/// Markdown のトークンを NSTextStorage の属性に反映する。
public struct MarkdownAttributer {
  private let theme: Theme
  private let preferences: Preferences
  private let highlighter = MarkdownHighlighter()
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
      storage.addAttributes(
        [.font: resolver.font(for: style), .foregroundColor: style.color.nsColor],
        range: token.range)
    }
  }
}
