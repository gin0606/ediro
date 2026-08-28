import AppKit
import EdiroCore
import Foundation

@testable import EdiroUI

/// 一時ディレクトリと専用の UserDefaults を持つ状態。テスト同士が
/// 実際の下書きや設定に触れないようにする。
func makeState(text: String = "") -> AppState {
  let directory = URL(filePath: NSTemporaryDirectory())
    .appending(path: "ediro-tests/\(UUID().uuidString)")
  let state = AppState(
    documentStore: DocumentStore(fileURL: directory.appending(path: "draft.md")),
    defaults: UserDefaults(suiteName: "ediro.tests.\(UUID().uuidString)")!)
  state.text = text
  return state
}

/// 状態の購読はメインアクターの次の実行まで反映されないので、条件が立つまで待つ。
func waitUntil(_ condition: () -> Bool, timeout: Duration = .milliseconds(500)) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}
