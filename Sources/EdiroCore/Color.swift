import Foundation

/// AppKit に依存せずテーマを表現するための色。成分は 0...1。
public struct RGBA: Equatable, Sendable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// `#RRGGBB` 形式から生成する。
  public init(hex: UInt32, alpha: Double = 1) {
    self.red = Double((hex >> 16) & 0xFF) / 255
    self.green = Double((hex >> 8) & 0xFF) / 255
    self.blue = Double(hex & 0xFF) / 255
    self.alpha = alpha
  }
}

/// ナビゲーションバーの塗り。
public enum Fill: Equatable, Sendable {
  case solid(RGBA)
  /// 色は始点から終点の順。`angle` は度数法で、0 が左→右、90 が下→上。
  case linearGradient(colors: [RGBA], angle: Double)
}
