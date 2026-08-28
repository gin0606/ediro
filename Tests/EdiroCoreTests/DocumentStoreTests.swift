import Foundation
import Testing

@testable import EdiroCore

private func makeStore() -> DocumentStore {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "ediro-tests/\(UUID().uuidString)")
  return DocumentStore(fileURL: directory.appending(path: "draft.md"))
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
    DocumentStore.directoryName(bundleName: "Ediro", bundleIdentifier: "com.gin0606.ediro")
      != DocumentStore.directoryName(
        bundleName: "Ediro Dev", bundleIdentifier: "com.gin0606.ediro.dev"))
}

@Test func バンドル名が無ければ識別子を使う() {
  #expect(
    DocumentStore.directoryName(bundleName: nil, bundleIdentifier: "com.gin0606.ediro.dev")
      == "com.gin0606.ediro.dev")
  #expect(DocumentStore.directoryName(bundleName: "", bundleIdentifier: "x") == "x")
}

@Test func どちらも無ければ既定の名前になる() {
  #expect(DocumentStore.directoryName(bundleName: nil, bundleIdentifier: nil) == "Ediro")
}
