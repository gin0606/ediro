import AppKit
import EdiroCore
import SwiftUI

extension RGBA {
  var nsColor: NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
  }

  var color: Color {
    Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
  }
}

extension Fill {
  @ViewBuilder var view: some View {
    switch self {
    case .solid(let rgba):
      rgba.color
    case .linearGradient(let colors, let angle):
      let radians = angle * .pi / 180
      let dx = cos(radians) / 2
      let dy = sin(radians) / 2
      LinearGradient(
        colors: colors.map(\.color),
        startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 + dy),
        endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 - dy))
    }
  }
}
