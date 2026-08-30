import EdiroCore
import Foundation
import Testing
import TestSupport

@testable import EdiroUI

private func makeStore() -> DocumentStore {
  DocumentStore(fileURL: TestArtifacts.directory().appending(path: "draft.md"))
}

/// debounce の待ちは実時間なので、並行実行の負荷で揺れないよう詰めておく。
private func state(on store: DocumentStore) -> AppState {
  AppState(documentStore: store, defaults: InMemoryStore(), saveDelay: .zero)
}

@Test func 打鍵したあと待つとディスクに書かれる() async throws {
  let store = makeStore()
  let app = state(on: store)
  app.text = "保存される本文"

  #expect(await waitUntil({ (try? store.load()) == "保存される本文" }, timeout: .seconds(2)))
}

@Test func flushは待たずに書き出す() throws {
  let store = makeStore()
  let app = state(on: store)
  app.text = "すぐ書く本文"
  app.flush()

  #expect(try store.load() == "すぐ書く本文")
}

@Test func 本文を変えずに終了しても書き戻さない() throws {
  let store = makeStore()
  // 読めない本文を置くと、書き戻しが起きた回だけ退避が走って観測できる
  try FileManager.default.createDirectory(
    at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data([0xFF, 0xFE]).write(to: store.fileURL)

  let app = state(on: store)
  app.flush()

  #expect(app.quarantined == nil, "編集していないのに退避が走っている")
  #expect(try Data(contentsOf: store.fileURL) == Data([0xFF, 0xFE]), "元のバイト列が失われている")
}

@Test func 退避元が既に無ければ保存を止めない() throws {
  let store = makeStore()
  try FileManager.default.createDirectory(
    at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data([0xFF, 0xFE]).write(to: store.fileURL)

  let app = state(on: store)
  #expect(app.storageError != nil, "読み込み失敗が出ていない")

  // 起動後にユーザーが壊れたファイルを自分で退けた状況
  try FileManager.default.removeItem(at: store.fileURL)

  app.text = "その後に書いた本文"
  app.flush()

  #expect(try store.load() == "その後に書いた本文")
  #expect(app.storageError == nil, "実際の文言: \(app.storageError ?? "")")
  #expect(app.quarantined == nil)
}

@Test func 書き出せなければflushは失敗を返す() throws {
  // 保存先の親を通常ファイルにしておくと、ディレクトリを作れず保存が失敗する
  let root = TestArtifacts.directory()
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let blocker = root.appending(path: "blocked")
  try Data().write(to: blocker)

  let app = state(on: DocumentStore(fileURL: blocker.appending(path: "draft.md")))
  app.text = "書けない本文"

  #expect(app.flush() == false, "保存できていないのに成功を返している")
}

@Test func 書き出す必要が無ければflushは成功を返す() throws {
  let app = state(on: makeStore())
  #expect(app.flush(), "編集していないのに失敗を返している")

  app.text = "書ける本文"
  #expect(app.flush())
}

@Test func 保存に失敗した理由を画面に出す() throws {
  // 保存先の親を通常ファイルにしておくと、ディレクトリを作れず保存だけが失敗する。
  // 読み込みは「ファイルが無い」を空文字で返すので、退避の経路には入らない。
  let root = TestArtifacts.directory()
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let blocker = root.appending(path: "blocked")
  try Data().write(to: blocker)

  let app = state(on: DocumentStore(fileURL: blocker.appending(path: "draft.md")))
  #expect(app.storageError == nil, "読み込みは失敗していないはず")

  app.text = "書けない本文"
  app.flush()

  let error = try #require(app.storageError)
  #expect(error.hasPrefix("保存できませんでした"), "実際の文言: \(error)")
  #expect(app.quarantined == nil, "退避の経路に入っている")
}

@Test func 退避に失敗したときは上書きせず理由を出す() throws {
  let store = makeStore()
  try FileManager.default.createDirectory(
    at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data([0xFF, 0xFE]).write(to: store.fileURL)

  let app = state(on: store)
  #expect(app.storageError != nil, "読み込み失敗が出ていない")

  // 保存先ディレクトリを読み取り専用にすると、退避の rename が失敗する
  let directory = store.fileURL.deletingLastPathComponent()
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o500], ofItemAtPath: directory.path(percentEncoded: false))
  defer {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
  }

  app.text = "退避できないので保存しない本文"
  app.flush()

  #expect(try Data(contentsOf: store.fileURL) == Data([0xFF, 0xFE]), "元のバイト列が失われている")
  let error = try #require(app.storageError)
  #expect(error.contains("退避できない"), "実際の文言: \(error)")
}

@Test func 読めなかった本文は上書きせず退避する() throws {
  let store = makeStore()
  // UTF-8 として解釈できないバイト列を置き、load を失敗させる
  try FileManager.default.createDirectory(
    at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data([0xFF, 0xFE, 0xFF]).write(to: store.fileURL)

  let app = state(on: store)
  #expect(app.text == "")
  #expect(app.storageError != nil, "読み込み失敗が画面に出ていない")

  app.text = "後から書いた本文"
  app.flush()

  #expect(try store.load() == "後から書いた本文")
  let siblings = try FileManager.default.contentsOfDirectory(
    atPath: store.fileURL.deletingLastPathComponent().path(percentEncoded: false))
  let quarantined = try #require(siblings.first { $0.contains("unreadable") })
  #expect(app.quarantined == quarantined)

  let rescued = store.fileURL.deletingLastPathComponent().appending(path: quarantined)
  #expect(try Data(contentsOf: rescued) == Data([0xFF, 0xFE, 0xFF]), "元のバイト列が失われている")
}

@Test func 打鍵の直後には書かず待ってから書く() async throws {
  let store = makeStore()
  let app = AppState(
    documentStore: store, defaults: InMemoryStore(), saveDelay: .milliseconds(300))

  app.text = "待ってから書かれる本文"
  #expect((try? store.load()) != "待ってから書かれる本文", "待たずに書き出している")

  #expect(await waitUntil({ (try? store.load()) == "待ってから書かれる本文" }, timeout: .seconds(5)))
}

@Test func 連続した打鍵はひとつの書き込みにまとめる() async throws {
  let store = makeStore()
  let app = AppState(
    documentStore: store, defaults: InMemoryStore(), saveDelay: .milliseconds(200))

  // 打鍵の間隔を待ちより短く取る。まとめられていなければ、打鍵ごとの書き込みが
  // 同じ間隔で並ぶので、途中の本文がディスク上に現れる。
  app.text = "あ"
  try await Task.sleep(for: .milliseconds(60))
  app.text = "あい"
  try await Task.sleep(for: .milliseconds(60))
  app.text = "あいう"

  var seen: Set<String> = []
  let deadline = ContinuousClock.now + .milliseconds(700)
  while ContinuousClock.now < deadline {
    if let text = try? store.load(), !text.isEmpty { seen.insert(text) }
    try await Task.sleep(for: .milliseconds(5))
  }

  #expect(seen == ["あいう"], "途中の本文が書き出されている: \(seen.sorted())")
}
