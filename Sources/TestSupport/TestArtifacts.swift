import Foundation

/// テストが使う一時ディレクトリ。
///
/// テスト同士が実際の下書きに触れないよう、資源はテストごとに分ける。破棄は
/// プロセスの終了時ではなく次回の起動時にまとめて行う。終了時フックは Swift
/// ランタイムの後片付けと順序が競合するため使わない。
public enum TestArtifacts {
  static let root = URL(filePath: NSTemporaryDirectory()).appending(path: "ediro-tests")

  /// 掃除の対象とみなすまでの猶予。1 回の `swift test` が終わるより十分に長く取る。
  /// `swift test` は同時に 2 つ走りうるので、名前だけで判断すると走っている
  /// 別プロセスが使用中のディレクトリを消してしまう。
  static let staleAfter: TimeInterval = 600

  private static let swept: Bool = {
    let manager = FileManager.default
    let cutoff = Date().addingTimeInterval(-staleAfter)
    for entry in (try? manager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
      let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      if modified ?? .distantPast < cutoff { try? manager.removeItem(at: entry) }
    }
    return true
  }()

  public static func directory() -> URL {
    _ = swept
    return root.appending(path: UUID().uuidString)
  }
}
