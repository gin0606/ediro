import Foundation

/// ハイライト対象として認識した Markdown の構文要素。
/// `range` は元テキストに対する UTF-16 オフセット（NSAttributedString と揃えるため）。
public struct Token: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case heading(level: Int)
    case strong
    case emphasis
    case inlineCode
    case codeBlock
    case link
    case listMarker
    case blockquote
  }

  public let kind: Kind
  public let range: NSRange

  public init(kind: Kind, range: NSRange) {
    self.kind = kind
    self.range = range
  }
}

/// 正規表現ベースの Markdown ハイライタ。
///
/// CommonMark に完全準拠はしない。下書き用途で視認性に効く要素だけを拾う。
public struct MarkdownHighlighter: Sendable {
  private static let patterns: [(Token.Kind, String)] = [
    // フェンス付きコードブロックは他の記法より先に検出して優先させる
    (.codeBlock, "(?m)^```[\\s\\S]*?^```"),
    (.heading(level: 0), "(?m)^(#{1,6})[ \\t]+.*$"),
    (.blockquote, "(?m)^[ \\t]*>[ \\t]?.*$"),
    (.listMarker, "(?m)^[ \\t]*(?:[-*+]|\\d+\\.)[ \\t]+"),
    (.link, "\\[[^\\]\\n]*\\]\\([^)\\n]*\\)"),
    // 直前直後の文字種で境界を判定しない。ICU の \\w は日本語にもマッチするため、
    // 「と*斜体*が」のように和文へ挟まれた記法を取りこぼす。
    (.strong, "(?<!\\*)\\*\\*(?!\\s)[^*\\n]+(?<!\\s)\\*\\*(?!\\*)"),
    (.emphasis, "(?<!\\*)\\*(?!\\s|\\*)[^*\\n]+(?<!\\s)\\*(?!\\*)"),
    (.inlineCode, "`[^`\\n]+`")
  ]

  private let expressions: [(Token.Kind, NSRegularExpression)]

  public init() {
    // パターンはリテラルで、実行時入力を含まない。コンパイルに失敗するのは
    // 上のパターンの記述ミスに限られるので、その場で落として気付けるようにする。
    expressions = Self.patterns.map { kind, pattern in
      guard let regex = try? NSRegularExpression(pattern: pattern) else {
        preconditionFailure("MarkdownHighlighter の正規表現が不正: \(pattern)")
      }
      return (kind, regex)
    }
  }

  /// 先に検出した要素の範囲を優先し、重なる後続の検出は捨てる。
  public func tokens(in text: String) -> [Token] {
    let full = NSRange(location: 0, length: (text as NSString).length)
    var claimed: [NSRange] = []
    var tokens: [Token] = []

    for (kind, regex) in expressions {
      for match in regex.matches(in: text, range: full) {
        let range = match.range
        if claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }

        let resolved: Token.Kind
        if case .heading = kind {
          resolved = .heading(level: match.range(at: 1).length)
        } else {
          resolved = kind
        }
        claimed.append(range)
        tokens.append(Token(kind: resolved, range: range))
      }
    }

    return tokens.sorted { $0.range.location < $1.range.location }
  }
}
