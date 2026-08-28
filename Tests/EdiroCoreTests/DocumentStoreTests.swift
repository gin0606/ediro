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
