import AppKit
import EdiroCore
import SwiftUI
import Testing

@testable import EdiroUI

extension AppKitTests {
  struct RenderingTests {
    /// ビューをオフスクリーンで PNG 化する。
    ///
    /// `ImageRenderer` は `NSViewRepresentable` を描画できず、禁止マークのプレースホルダに
    /// 差し替える。差し替わってもエラーにならないため、寸法だけを見るテストは通ってしまう。
    /// エディタを含みうるビューを通すなら `colorAt` で色を見る。合成の確認は実機の撮影で行う。
    private func render<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
      let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
      renderer.scale = 1
      let image = try #require(renderer.nsImage)
      let data = try #require(image.tiffRepresentation)
      return try #require(NSBitmapImageRep(data: data))
    }

    @Test func 単色テーマは指定した色で塗られる() throws {
      let theme = Theme.theme(id: "dark")
      let rep = try render(theme.navBar.view, size: CGSize(width: 100, height: 26))
      let pixel = try #require(rep.colorAt(x: 50, y: 13))
      // #333333
      #expect(abs(pixel.redComponent - 0x33 / 255.0) < 0.02)
      #expect(abs(pixel.greenComponent - 0x33 / 255.0) < 0.02)
      #expect(abs(pixel.blueComponent - 0x33 / 255.0) < 0.02)
    }

    @Test func 横方向グラデーションは左右で色が変わる() throws {
      let theme = Theme.theme(id: "dark-grad")
      let rep = try render(theme.navBar.view, size: CGSize(width: 200, height: 26))
      let left = try #require(rep.colorAt(x: 3, y: 13))
      let right = try #require(rep.colorAt(x: 196, y: 13))
      // 左端は紫 (#5433FF) 寄り、右端は水色 (#30D9EF) 寄り
      #expect(left.blueComponent > left.greenComponent)
      #expect(right.greenComponent > right.redComponent)
    }

    @Test func タイトルバーの高さが取れる() {
      #expect(WindowMetrics.titleBarHeight > 0)
    }

    @Test func タイトルバーの帯はテーマの色で塗られる() throws {
      // vscode はナビゲーションバー (#0077D5) と帯 (#333333) の色が違い、塗りの取り違えも分かる
      let theme = Theme.theme(id: "vscode")
      let rep = try render(TitleBarView(theme: theme), size: CGSize(width: 200, height: 32))
      let pixel = try #require(rep.colorAt(x: 100, y: 16))
      #expect(abs(pixel.redComponent - 0x33 / 255.0) < 0.05)
      #expect(abs(pixel.blueComponent - 0x33 / 255.0) < 0.05)
    }

    @Test func 明るいテーマの帯は暗いテーマより明るい() throws {
      func brightness(_ id: String) throws -> Double {
        let rep = try render(
          TitleBarView(theme: Theme.theme(id: id)), size: CGSize(width: 200, height: 32))
        return Double(try #require(rep.colorAt(x: 100, y: 16)).brightnessComponent)
      }
      #expect(try brightness("light") > brightness("dark"))
    }
  }
}
