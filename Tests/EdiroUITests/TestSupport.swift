import AppKit
import EdiroCore
import EditorEngine
import EditorMarkdown
import Foundation
import TestSupport
import Testing

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

/// テストを通して変わらない環境の判定。待つ判定もあるので、最初の結果を使い回す。
@MainActor private enum Environment {
  static var completions: Bool?
  static var grammar: Bool?
}

/// NSTextView が補完候補を出せない環境 (CI の VM など) では、補完を確かめられないので打ち切る。
/// 最初の問い合わせは準備が済むまで空になることがあるので、しばらく待つ。
@MainActor func requireCompletionsAvailable() async throws {
  if Environment.completions == nil {
    let probe = NSTextView()
    probe.string = "hel"
    probe.setSelectedRange(NSRange(location: 3, length: 0))
    Environment.completions = await waitUntil({
      var index = 0
      return probe.completions(
        forPartialWordRange: probe.rangeForUserCompletion, indexOfSelectedItem: &index)?
        .isEmpty == false
    }, timeout: .seconds(3))
  }
  if Environment.completions != true {
    try Test.cancel("NSTextView が補完候補を出さない環境なので、補完を確かめられない")
  }
}

/// システムの文法チェッカーがテストで使う英語の文法の誤りを返さない環境 (CI の VM など) では、
/// 文法の印を確かめられないので打ち切る。エディタと同じく言語を指定せずに問い合わせ、
/// 準備が済むまでしばらく待つ。文法だけを求めると結果が返らないので、スペルと一緒に求める。
@MainActor func requireGrammarCheckingAvailable() async throws {
  if Environment.grammar == nil {
    let types =
      NSTextCheckingResult.CheckingType.spelling.rawValue
      | NSTextCheckingResult.CheckingType.grammar.rawValue
    func flagged(_ text: String) -> Bool {
      NSSpellChecker.shared.check(
        text, range: NSRange(location: 0, length: (text as NSString).length), types: types,
        options: [:], inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil
      ).contains { $0.resultType == .grammar }
    }
    Environment.grammar = await waitUntil({
      flagged("He go to school yesterday. ") && flagged("They is happy. ")
    }, timeout: .seconds(3))
  }
  if Environment.grammar != true {
    try Test.cancel("文法チェッカーが誤りを返さない環境なので、文法の印を確かめられない")
  }
}
