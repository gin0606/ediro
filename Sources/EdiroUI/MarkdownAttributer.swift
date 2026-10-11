import AppKit
import EdiroCore
import EditorEngine
import EditorMarkdown

/// エンジンの Document が Markdown のトークナイザで作った行トークンを、NSTextStorage の
/// 属性に反映する。
public struct MarkdownAttributer {
  /// 合成した太字の濃さ。実際のボールド字面と同程度になる値。
  static let syntheticBoldStroke = -5.0

  private let bodyAttributes: [NSAttributedString.Key: Any]
  /// 種別ごとの属性。打鍵のたびにフォントを解決し直さないよう、先に作っておく。
  private let styledAttributes: [MarkdownTokenKind: [NSAttributedString.Key: Any]]

  public init(theme: Theme, preferences: Preferences) {
    let resolver = FontResolver(preferences: preferences)
    let body: [NSAttributedString.Key: Any] = [
      .font: resolver.bodyFont,
      .foregroundColor: theme.editorForeground.nsColor,
      .paragraphStyle: ParagraphStyle.make(for: preferences),
    ]
    let palette = SyntaxPalette(theme: theme)
    var styled: [MarkdownTokenKind: [NSAttributedString.Key: Any]] = [:]
    for kind in MarkdownTokenKind.allCases {
      let style = palette.style(for: kind)
      let resolved = resolver.resolve(for: style)
      var attributes = body
      attributes[.font] = resolved.font
      attributes[.foregroundColor] = style.color.nsColor
      if resolved.needsSyntheticBold {
        // 負の値は塗りと縁の両方を描く。縁の色を前景と揃えて太さだけを足す。
        attributes[.strokeWidth] = Self.syntheticBoldStroke
        attributes[.strokeColor] = style.color.nsColor
      }
      styled[kind] = attributes
    }
    bodyAttributes = body
    styledAttributes = styled
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
      storage.setAttributes(bodyAttributes, range: NSRange(location: start, length: end - start))
      for token in tokens {
        guard let kind = MarkdownTokenKind(token), let attributes = styledAttributes[kind],
          let offsets = try? snapshot.offsets(in: token.range)
        else { continue }
        storage.setAttributes(attributes, range: NSRange(offsets))
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
