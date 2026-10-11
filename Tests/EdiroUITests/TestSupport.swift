import AppKit
import EdiroCore
import EditorEngine
import EditorMarkdown
import Foundation
import TestSupport

@testable import EdiroUI

/// 一時ディレクトリとメモリ上の設定を持つ状態。テスト同士が実際の下書きや
/// 設定に触れないようにする。
func makeState(text: String = "") -> AppState {
  let state = AppState(
    documentStore: DocumentStore(fileURL: TestArtifacts.directory().appending(path: "draft.md")),
    defaults: InMemoryStore())
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

/// Markdown の装飾を本文全体に掛けた NSTextStorage。エディタと同じく、エンジンが作った
/// 行トークンから属性を付ける。
@MainActor func highlighted(
  _ text: String, theme: Theme = .fallback, preferences: Preferences = .default
) -> NSTextStorage {
  let document = Document(id: "highlighted", text: text, lineTokenizer: MarkdownTokenizer())
  let storage = NSTextStorage(string: document.snapshot.text)
  MarkdownAttributer(theme: theme, preferences: preferences).applyAll(of: document, to: storage)
  return storage
}
