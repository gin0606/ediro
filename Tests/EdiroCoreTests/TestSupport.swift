import Foundation

/// テストが作る一時ディレクトリと UserDefaults suite の後始末。
///
/// suite は plist として、一時ディレクトリはそのまま残る。掃除しないと
/// `swift test` を走らせるたびにホームディレクトリと TMPDIR に溜まり続ける。
/// テストは並行に走るので資源はテストごとに分け、破棄はプロセスの終了時ではなく
/// 次回の起動時にまとめて行う。終了時フックは Swift ランタイムの後片付けと
/// 順序が競合するため使わない。
///
/// 掃除の対象は接頭辞で分ける。`swift test` は両方のテストターゲットを 1 つの
/// プロセスに束ねるため、EdiroCoreTests と EdiroUITests の掃除が同じ実行の中で
/// 走る。接頭辞を揃えると、片方の掃除がもう片方の使用中の suite を消す。
enum TestArtifacts {
  static let suitePrefix = "me.gin0606.ediro.tests."
  static let root = URL(filePath: NSTemporaryDirectory()).appending(path: "ediro-tests/core")

  private static let swept: Bool = {
    sweep(root: root, suitePrefix: suitePrefix)
    return true
  }()

  static func directory() -> URL {
    _ = swept
    return root.appending(path: UUID().uuidString)
  }

  static func defaults() -> UserDefaults {
    _ = swept
    let suite = "\(suitePrefix)\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}

/// 前回までの実行が残した一時ディレクトリと suite を消す。
///
/// 消すのは十分に古いものだけにする。`swift test` は同時に 2 つ走りうるので、
/// 名前だけで判断すると、走っている別プロセスが使用中の suite とディレクトリを
/// 消してしまい、相手の設定テストが既定値に落ちる。
func sweep(root: URL, suitePrefix: String) {
  let manager = FileManager.default
  let cutoff = Date().addingTimeInterval(-staleAfter)

  for stale in (try? manager.contentsOfDirectory(
    at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
    if lastModified(stale) ?? .distantPast < cutoff { try? manager.removeItem(at: stale) }
  }

  guard
    let preferences = try? manager.url(
      for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
      .appending(path: "Preferences"),
    let entries = try? manager.contentsOfDirectory(atPath: preferences.path(percentEncoded: false))
  else { return }

  for entry in entries where entry.hasPrefix(suitePrefix) && entry.hasSuffix(".plist") {
    let file = preferences.appending(path: entry)
    guard lastModified(file) ?? .distantPast < cutoff else { continue }
    UserDefaults.standard.removePersistentDomain(forName: String(entry.dropLast(".plist".count)))
    try? manager.removeItem(at: file)
  }
}

/// 掃除の対象とみなすまでの猶予。1 回の `swift test` が終わるより十分に長く取る。
let staleAfter: TimeInterval = 600

func lastModified(_ url: URL) -> Date? {
  try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}
