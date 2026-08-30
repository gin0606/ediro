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

  /// 直前の版の置き場所。
  ///
  /// 全消しのような誤操作はアプリ内の取り消しで戻せるが、それは再起動で失われる。
  /// 残るのは 1 世代だけで、保存のたびに入れ替わる。
  public var previousURL: URL {
    fileURL.appendingPathExtension("previous")
  }

  /// 書き込みは atomic に行う。保存中のクラッシュで本文が壊れるのを避けるため。
  /// 上書きする前に、今ディスクにある本文を直前の版として残す。
  public func save(_ text: String) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try keepPreviousVersion()
    try text.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  /// 今ディスクにある本文を直前の版として複製する。
  ///
  /// 移動ではなく複製にするのは、この後の書き込みが失敗したときに保存先を
  /// 空にしないため。読めないファイルは `quarantine()` が退避するので、
  /// 直前の版で潰してはいけない。
  private func keepPreviousVersion() throws {
    guard let current = try? Data(contentsOf: fileURL) else { return }
    try current.write(to: previousURL, options: .atomic)
  }

  /// 読めなかった本文を隣に退避し、退避先を返す。
  ///
  /// `load()` が投げた後にそのまま保存すると、読めなかっただけで中身は残っている
  /// ファイルを空の本文で上書きしてしまう。退避してから保存すれば、元の内容も
  /// その回に書いた内容も失われない。
  /// 退避先の名前は秒までしか持たないため、既にあるときは連番で避ける。
  /// 退避すべきファイルが既に無いときは `nil` を返す。
  public func quarantine(now: Date = Date()) throws -> URL? {
    guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
      return nil
    }
    let stamp = ISO8601DateFormatter().string(from: now)
      .replacingOccurrences(of: ":", with: "-")
    let directory = fileURL.deletingLastPathComponent()
    let base = "\(fileURL.lastPathComponent).unreadable-\(stamp)"

    var destination = directory.appending(path: base)
    var suffix = 2
    while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
      destination = directory.appending(path: "\(base)-\(suffix)")
      suffix += 1
    }
    try FileManager.default.moveItem(at: fileURL, to: destination)
    return destination
  }
}
