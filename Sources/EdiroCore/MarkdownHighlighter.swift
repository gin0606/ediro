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
  /// パターン表が示す種別。見出しだけは捕捉した `#` の数でレベルが決まるので、
  /// 表の時点では確定しない。`Token.Kind` に不正なレベルの値を置かずに済ませる。
  private enum Matched {
    case fixed(Token.Kind)
    case heading
  }

  private static let patterns: [(Matched, String)] = [
    // フェンス付きコードブロックは他の記法より先に検出して優先させる
    (.fixed(.codeBlock), "(?m)^```[\\s\\S]*?^```"),
    (.heading, "(?m)^(#{1,6})[ \\t]+.*$"),
    (.fixed(.blockquote), "(?m)^[ \\t]*>[ \\t]?.*$"),
    (.fixed(.listMarker), "(?m)^[ \\t]*(?:[-*+]|\\d+\\.)[ \\t]+"),
    (.fixed(.link), "\\[[^\\]\\n]*\\]\\([^)\\n]*\\)"),
    // 直前直後の文字種で境界を判定しない。ICU の \\w は日本語にもマッチするため、
    // 「と*斜体*が」のように和文へ挟まれた記法を取りこぼす。
    (.fixed(.strong), "(?<!\\*)\\*\\*(?!\\s)[^*\\n]+(?<!\\s)\\*\\*(?!\\*)"),
    (.fixed(.emphasis), "(?<!\\*)\\*(?!\\s|\\*)[^*\\n]+(?<!\\s)\\*(?!\\*)"),
    (.fixed(.inlineCode), "`[^`\\n]+`")
  ]

  /// 打鍵のたびに作り直されるので、コンパイル済みの正規表現は使い回す。
  /// `NSRegularExpression` は不変で、複数スレッドから同時に使える。
  public static let shared = MarkdownHighlighter()

  private let expressions: [(Matched, NSRegularExpression)]

  public init() {
    // パターンはリテラルで、実行時入力を含まない。コンパイルに失敗するのは
    // 上のパターンの記述ミスに限られるので、その場で落として気付けるようにする。
    expressions = Self.patterns.map { matched, pattern in
      guard let regex = try? NSRegularExpression(pattern: pattern) else {
        preconditionFailure("MarkdownHighlighter の正規表現が不正: \(pattern)")
      }
      return (matched, regex)
    }
  }

  /// 先に検出した要素の範囲を優先し、重なる後続の検出は捨てる。
  public func tokens(in text: String) -> [Token] {
    let full = NSRange(location: 0, length: (text as NSString).length)
    var claimed: [NSRange] = []
    var tokens: [Token] = []

    for (matched, regex) in expressions {
      for match in regex.matches(in: text, range: full) {
        let range = match.range
        if claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }

        let kind: Token.Kind
        switch matched {
        case .fixed(let fixed): kind = fixed
        case .heading: kind = .heading(level: match.range(at: 1).length)
        }
        claimed.append(range)
        tokens.append(Token(kind: kind, range: range))
      }
    }

    return tokens.sorted { $0.range.location < $1.range.location }
  }
}
