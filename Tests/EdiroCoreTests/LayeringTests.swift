import Foundation
import Testing

/// Core が UI フレームワークに依存していないことを、散文の規約ではなく
/// テストで固定する。依存すると GUI なしに走らせられる範囲が狭まる。
@Test func CoreはUIフレームワークをimportしない() throws {
  let core = URL(filePath: #filePath)
    .deletingLastPathComponent()  // EdiroCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // リポジトリ直下
    .appending(path: "Sources/EdiroCore")

  // サブディレクトリに分けたファイルも見落とさないよう、再帰して集める。
  let files = try #require(FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil))
    .compactMap { $0 as? URL }
    .filter { $0.pathExtension == "swift" }
  #expect(!files.isEmpty, "走査対象が見つからない: \(core.path())")

  for file in files {
    let source = try String(contentsOf: file, encoding: .utf8)
    for framework in ["AppKit", "SwiftUI", "UIKit", "Cocoa"] {
      #expect(
        !source.contains("import \(framework)"),
        "\(file.lastPathComponent) が \(framework) を import している")
    }
  }
}
