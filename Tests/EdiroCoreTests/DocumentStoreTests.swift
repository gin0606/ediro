import Foundation
import Testing

@testable import EdiroCore

private func makeStore() -> DocumentStore {
  DocumentStore(fileURL: TestArtifacts.directory().appending(path: "draft.md"))
}

@Test func 保存した本文を読み戻せる() throws {
  let store = makeStore()
  try store.save("# 下書き\n\n本文")
  #expect(try store.load() == "# 下書き\n\n本文")
}

@Test func 初回起動では空文字を返す() throws {
  #expect(try makeStore().load() == "")
}

@Test func 上書き保存で古い内容が残らない() throws {
  let store = makeStore()
  try store.save("長いほうの本文です")
  try store.save("短い")
  #expect(try store.load() == "短い")
}

@Test func 保存先はバンドル名から分かれる() {
  #expect(
    DocumentStore.directoryName(bundleName: "Ediro", bundleIdentifier: "me.gin0606.ediro")
      != DocumentStore.directoryName(
        bundleName: "Ediro Dev", bundleIdentifier: "me.gin0606.ediro.dev"))
}

@Test func バンドル名が無ければ識別子を使う() {
  #expect(
    DocumentStore.directoryName(bundleName: nil, bundleIdentifier: "me.gin0606.ediro.dev")
      == "me.gin0606.ediro.dev")
  #expect(DocumentStore.directoryName(bundleName: "", bundleIdentifier: "x") == "x")
}

@Test func どちらも無ければ既定の名前になる() {
  #expect(DocumentStore.directoryName(bundleName: nil, bundleIdentifier: nil) == "Ediro")
}

@Test func 退避すると元のファイルが別名で残る() throws {
  let store = makeStore()
  try store.save("読めなくなる前の本文")

  let moved = try #require(try store.quarantine())
  #expect(moved != store.fileURL)
  #expect(try String(contentsOf: moved, encoding: .utf8) == "読めなくなる前の本文")
  #expect(try store.load() == "", "退避後の保存先は空になっている")
}

@Test func 退避するものが無ければnilを返す() throws {
  #expect(try makeStore().quarantine() == nil)
}

@Test func 同じ秒に退避しても前の退避先を潰さない() throws {
  let store = makeStore()
  let now = Date()

  try store.save("いちど目")
  let first = try #require(try store.quarantine(now: now))
  try store.save("にど目")
  let second = try #require(try store.quarantine(now: now))

  #expect(first != second)
  #expect(try String(contentsOf: first, encoding: .utf8) == "いちど目")
  #expect(try String(contentsOf: second, encoding: .utf8) == "にど目")
}
