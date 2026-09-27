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

  private var bodyAttributes: [NSAttributedString.Key: Any] {
    [
      .font: resolver.bodyFont,
      .foregroundColor: theme.editorForeground.nsColor,
      .paragraphStyle: ParagraphStyle.make(for: preferences),
    ]
  }

  private func attributes(for kind: Token.Kind) -> [NSAttributedString.Key: Any] {
    let style = SyntaxPalette(theme: theme).style(for: kind)
    let resolved = resolver.resolve(for: style)
    var attributes: [NSAttributedString.Key: Any] = [
      .font: resolved.font, .foregroundColor: style.color.nsColor,
    ]
    if resolved.needsSyntheticBold {
      // 負の値は塗りと縁の両方を描く。縁の色を前景と揃えて太さだけを足す。
      attributes[.strokeWidth] = Self.syntheticBoldStroke
      attributes[.strokeColor] = style.color.nsColor
    }
    return attributes
  }

  func typingAttributes(in text: String, replacing range: NSRange) -> [NSAttributedString.Key: Any]
  {
    let source = text as NSString
    guard range.location != NSNotFound, range.location <= source.length,
      range.length <= source.length - range.location
    else { return bodyAttributes }
    // 選択範囲を通常文字で置換して判定する。閉じ記号の外側や構文記号を
    // 含む選択では、直前の文字の装飾をそのまま引き継がない。
    let candidate = source.replacingCharacters(in: range, with: "a")
    guard
      let token = highlighter.tokens(in: candidate).first(where: {
        NSLocationInRange(range.location, $0.range)
      })
    else { return bodyAttributes }
    return bodyAttributes.merging(attributes(for: token.kind)) { _, style in style }
  }

  public func apply(to storage: NSTextStorage) {
    let text = storage.string
    let full = NSRange(location: 0, length: (text as NSString).length)

    let styled = NSTextStorage(string: text)
    styled.beginEditing()
    styled.setAttributes(bodyAttributes, range: full)

    for token in highlighter.tokens(in: text) {
      styled.addAttributes(attributes(for: token.kind), range: token.range)
    }
    styled.endEditing()
    // フォントのフォールバック・段落属性の遅延補正を済ませてから比較する。
    styled.ensureAttributesAreFixed(in: full)

    // 全文の属性を消してから付け直すと、画面外も含むレイアウトが繰り返し
    // 無効になる。完成した書式と比較し、差分だけを一度に通知する。
    var changes: [(NSRange, [NSAttributedString.Key: Any])] = []
    styled.enumerateAttributes(in: full) { attributes, range, _ in
      storage.enumerateAttributes(in: range) { current, currentRange, _ in
        if !Self.equalAttributes(current, attributes) {
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

  private static func equalAttributes(
    _ left: [NSAttributedString.Key: Any], _ right: [NSAttributedString.Key: Any]
  ) -> Bool {
    if NSDictionary(dictionary: left).isEqual(to: right) { return true }
    guard let leftFont = left[.font] as? NSFont, let rightFont = right[.font] as? NSFont,
      leftFont.pointSize == rightFont.pointSize,
      NSDictionary(dictionary: leftFont.fontDescriptor.fontAttributes)
        .isEqual(to: rightFont.fontDescriptor.fontAttributes)
    else { return false }
    // フォールバックで別インスタンスになった同じ書体も、書式の変更とは扱わない。
    var comparable = left
    comparable[.font] = rightFont
    return NSDictionary(dictionary: comparable).isEqual(to: right)
  }
}
