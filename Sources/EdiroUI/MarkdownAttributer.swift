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

    let styled = NSMutableAttributedString(string: text)
    styled.setAttributes(
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
      styled.addAttributes(attributes, range: token.range)
    }
    // NSTextStorage と同じフォントのフォールバック・段落属性に揃えて比較する。
    styled.fixAttributes(in: full)

    // 全文の属性を消してから付け直すと、画面外も含むレイアウトが繰り返し
    // 無効になる。完成した書式と比較し、差分だけを一度に通知する。
    var changes: [(NSRange, [NSAttributedString.Key: Any])] = []
    styled.enumerateAttributes(in: full) { attributes, range, _ in
      storage.enumerateAttributes(in: range) { current, currentRange, _ in
        if !NSDictionary(dictionary: current).isEqual(to: attributes) {
          changes.append((currentRange, attributes))
        }
      }
    }
    guard !changes.isEmpty else { return }
    storage.beginEditing()
    for (range, attributes) in changes {
      storage.setAttributes(attributes, range: range)
    }
    storage.endEditing()
  }
}
