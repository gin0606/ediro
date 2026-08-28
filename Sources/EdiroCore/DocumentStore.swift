import Foundation

/// 下書き本文の保存先。
///
/// 本文は設定と違って際限なく伸びるので UserDefaults ではなく実ファイルに置く。
public struct DocumentStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static func applicationSupport(
    bundle: Bundle = .main, fileManager: FileManager = .default
  ) throws -> DocumentStore {
    let base = try fileManager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let directory = directoryName(
      bundleName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
      bundleIdentifier: bundle.bundleIdentifier)
    return DocumentStore(fileURL: base.appending(path: "\(directory)/draft.md"))
  }

  /// 保存先のディレクトリ名。バンドル名から導くことで、名前の違うビルドは
  /// 別の場所を使う。開発用ビルドが実際に使うビルドの下書きに触れない。
  public static func directoryName(bundleName: String?, bundleIdentifier: String?) -> String {
    if let bundleName, !bundleName.isEmpty { return bundleName }
    if let bundleIdentifier, !bundleIdentifier.isEmpty { return bundleIdentifier }
    return "Ediro"
  }

  /// 保存済みの本文を読む。ファイルが無い初回起動は空文字を返す。
  public func load() throws -> String {
    guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
      return ""
    }
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  /// 書き込みは atomic に行う。保存中のクラッシュで本文が壊れるのを避けるため。
  public func save(_ text: String) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try text.write(to: fileURL, atomically: true, encoding: .utf8)
  }
}
