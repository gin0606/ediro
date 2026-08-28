import Foundation

/// ナビゲーションバーに出す文字数と行数。
public struct TextMetrics: Equatable, Sendable {
  public let characters: Int
  public let lines: Int

  /// 文字数は書記素クラスタ単位で数える。絵文字や結合文字を人間の見た目どおりに
  /// 1 文字として扱うため、UTF-16 の長さは使わない。
  public init(text: String) {
    characters = text.count
    lines = text.isEmpty ? 1 : text.count(where: { $0 == "\n" }) + 1
  }
}
