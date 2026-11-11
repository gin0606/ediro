import AppKit
import EdiroCore
import EditorEngine
import EditorMarkdown

/// エンジンの Document が Markdown のトークナイザで作った行トークンを、NSTextStorage の
/// 属性に反映する。入れ子のトークンは、外側の見た目を引き継いで自分の性質を足す。
public struct MarkdownAttributer {
  /// 合成した太字の濃さ。実際のボールド字面と同程度になる値。
  static let syntheticBoldStroke = -5.0

  private let palette: SyntaxPalette
  private let attributes: StyleAttributes

  public init(theme: Theme, preferences: Preferences) {
    palette = SyntaxPalette(theme: theme)
    attributes = StyleAttributes(
      resolver: FontResolver(preferences: preferences), foreground: theme.editorForeground,
      paragraphStyle: ParagraphStyle.make(for: preferences))
    // よく使う見た目は先に解決しておく。
    attributes.resolve(SyntaxStyle())
    for kind in MarkdownTokenKind.allCases {
      attributes.resolve(palette.style(for: kind))
    }
  }

  /// `lines` の行 (行末の改行を含む) の属性を、その行のトークンから当て直す。ほかの行には
  /// 触れないので、レイアウトも無効にしない。`storage` は `document` と同じ本文を持つこと。
  public func apply(lines: IndexSet, of document: Document, to storage: NSTextStorage) {
    let snapshot = document.snapshot
    let lines = lines.intersection(IndexSet(integersIn: 0..<snapshot.lineCount))
    guard storage.length == snapshot.utf16Count else {
      assertionFailure("本文の写しがエンジンの本文と食い違っている")
      return
    }
    guard !lines.isEmpty else { return }
    storage.beginEditing()
    for range in lines.rangeView {
      guard let start = try? snapshot.offset(at: Position(range.lowerBound, 0)),
        let end = range.upperBound == snapshot.lineCount
          ? snapshot.utf16Count : try? snapshot.offset(at: Position(range.upperBound, 0)),
        let tokens = try? document.lineTokens(in: range)
      else { continue }
      storage.setAttributes(
        attributes.resolve(SyntaxStyle()), range: NSRange(location: start, length: end - start))
      // トークンは外側が先に来る。内側は外側を当てた後に、外側の見た目を引き継いだ見た目で
      // 上書きする。
      var enclosing: [(end: Int, style: SyntaxStyle)] = []
      for token in tokens {
        guard let kind = MarkdownTokenKind(token),
          let offsets = try? snapshot.offsets(in: token.range)
        else { continue }
        while let last = enclosing.last, last.end <= offsets.lowerBound { enclosing.removeLast() }
        let style = palette.style(for: kind).inside(enclosing.last?.style ?? SyntaxStyle())
        enclosing.append((offsets.upperBound, style))
        storage.setAttributes(attributes.resolve(style), range: NSRange(offsets))
      }
    }
    storage.endEditing()
  }

  /// 本文全体の属性を当て直す。
  public func applyAll(of document: Document, to storage: NSTextStorage) {
    apply(
      lines: IndexSet(integersIn: 0..<document.snapshot.lineCount), of: document, to: storage)
  }
}

/// 見た目ごとの属性。打鍵のたびにフォントを解決し直さないよう、解決した見た目を取っておく。
/// 見た目の組み合わせは種別の数で限られる。
private final class StyleAttributes {
  private let resolver: FontResolver
  /// 色を持たない見た目 (本文と、本文の中の太字・斜体) の色。
  private let foreground: RGBA
  private let paragraphStyle: NSParagraphStyle
  private var resolved: [SyntaxStyle: [NSAttributedString.Key: Any]] = [:]

  init(resolver: FontResolver, foreground: RGBA, paragraphStyle: NSParagraphStyle) {
    self.resolver = resolver
    self.foreground = foreground
    self.paragraphStyle = paragraphStyle
  }

  @discardableResult
  func resolve(_ style: SyntaxStyle) -> [NSAttributedString.Key: Any] {
    if let attributes = resolved[style] { return attributes }
    let color = (style.color ?? foreground).nsColor
    let font = resolver.resolve(for: style)
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font.font,
      .foregroundColor: color,
      .paragraphStyle: paragraphStyle,
    ]
    if font.needsSyntheticBold {
      // 負の値は塗りと縁の両方を描く。縁の色を前景と揃えて太さだけを足す。
      attributes[.strokeWidth] = MarkdownAttributer.syntheticBoldStroke
      attributes[.strokeColor] = color
    }
    resolved[style] = attributes
    return attributes
  }
}
