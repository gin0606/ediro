import AppKit
import EdiroCore
import SwiftUI
import Testing

@testable import EdiroUI

/// ビューをオフスクリーンで PNG 化する。
private func render<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
  let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
  renderer.scale = 1
  let image = try #require(renderer.nsImage)
  let data = try #require(image.tiffRepresentation)
  return try #require(NSBitmapImageRep(data: data))
}

@Test func 全テーマのナビゲーションバーを描画できる() throws {
  for theme in Theme.all {
    let rep = try render(theme.navBar.view, size: CGSize(width: 200, height: 26))
    #expect(rep.pixelsWide == 200)
    #expect(rep.pixelsHigh == 26)
  }
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

@Test func エディタ本体を含むルートビューが描画できる() throws {
  let store = DocumentStore(
    fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "ediro-ui-tests/\(UUID().uuidString)/draft.md"))
  let state = AppState(
    documentStore: store, defaults: UserDefaults(suiteName: "ediro.ui.\(UUID().uuidString)")!)
  state.text = "# 見出し\n\n本文です。"

  let rep = try render(RootView(state: state), size: CGSize(width: 400, height: 300))
  #expect(rep.pixelsWide == 400)
  #expect(rep.pixelsHigh == 300)
}
