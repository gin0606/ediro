import AppKit
import EdiroCore
import SwiftUI
import Testing

@testable import EdiroUI

/// 帯が単色のテーマ。塗りのグラデーションを挟まずに画素を比べられる。
private let flatTheme = Theme.theme(id: "dark")

private func render(_ view: some View, width: Double) throws -> NSBitmapImageRep {
  let renderer = ImageRenderer(content: view.frame(width: width, height: 26))
  renderer.scale = 1
  let image = try #require(renderer.nsImage)
  let data = try #require(image.tiffRepresentation)
  return try #require(NSBitmapImageRep(data: data))
}

/// 指定した横位置の範囲で、色が異なる画素の数を数える。
private func differingPixels(
  _ a: NSBitmapImageRep, _ b: NSBitmapImageRep, columns: Range<Int>
) -> Int {
  var count = 0
  for x in columns {
    for y in 0..<a.pixelsHigh {
      let left = a.colorAt(x: x, y: y)?.brightnessComponent ?? 0
      let right = b.colorAt(x: x, y: y)?.brightnessComponent ?? 0
      if abs(left - right) > 0.05 { count += 1 }
    }
  }
  return count
}

private func plainState() -> AppState {
  let state = makeState(text: "本文\n2 行目")
  state.preferences.themeID = flatTheme.id
  return state
}

/// 退避も保存失敗も起きた状態を、実際のファイル操作で作る。
private func troubledState() throws -> AppState {
  let root = TestArtifacts.directory()
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let file = root.appending(path: "draft.md")
  try Data([0xFF, 0xFE]).write(to: file)

  let app = AppState(
    documentStore: DocumentStore(fileURL: file), defaults: TestArtifacts.defaults(),
    saveDelay: .zero)
  app.preferences.themeID = flatTheme.id
  app.text = "本文\n2 行め"
  app.flush()

  let path = root.path(percentEncoded: false)
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
  // 文字数は plainState と揃える。数字の桁が変わると先頭の描画がずれる
  app.text = "本文\n2 行目"
  app.flush()
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)

  try #require(app.quarantined != nil)
  try #require(app.storageError != nil)
  return app
}

@Test func 異常の文面が出ても文字数の描画位置は変わらない() throws {
  let troubled = try troubledState()
  // ウィンドウの最小幅。ここで崩れなければ広い幅でも崩れない
  let plain = try render(NavBarView(state: plainState()), width: 320)
  let noisy = try render(NavBarView(state: troubled), width: 320)

  // 先頭は "Characters: 7  Lines: 2" の領域。優先度が効いていれば、異常の
  // 文面が増えても同じ画素で描かれる
  let differing = differingPixels(plain, noisy, columns: 0..<90)
  #expect(differing == 0, "文字数の描画が異常の文面に押されている (\(differing) 画素)")
}
