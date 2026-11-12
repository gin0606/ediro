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

/// 下線が付いている範囲。隣り合う範囲は一つにまとめる。
func underlinedRanges(_ storage: NSAttributedString) -> [NSRange] {
  var ranges: [NSRange] = []
  storage.enumerateAttribute(.underlineStyle, in: NSRange(location: 0, length: storage.length)) {
    value, range, _ in
    guard let style = value as? Int, style != 0 else { return }
    if let last = ranges.last, NSMaxRange(last) == range.location {
      ranges[ranges.count - 1].length += range.length
    } else {
      ranges.append(range)
    }
  }
  return ranges
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

/// システムの文法チェッカーが、テストで使う英語の文法の誤りを、テストが前提にする範囲 (動詞の
/// "go" と "is" だけ) で返さない環境では、文法の印を確かめられないので打ち切る。結果を返さない
/// 環境 (CI の VM など) のほか、OS の判定の粒度が変わったときも、Ediro の誤りとせずに打ち切る。
/// エディタと同じく言語を指定せずに問い合わせ、準備が済むまでしばらく待つ。文法だけを求めると
/// 結果が返らないので、スペルと一緒に求める。
@MainActor func requireGrammarCheckingAvailable() async throws {
  if Environment.grammar == nil {
    let types =
      NSTextCheckingResult.CheckingType.spelling.rawValue
      | NSTextCheckingResult.CheckingType.grammar.rawValue
    /// `text` の文法の結果に、`issue` の文字だけを指す誤りがあるか。誤りの範囲は文の先頭から
    /// 数え、無ければ文全体を指す。
    func flags(_ issue: String, in text: String) -> Bool {
      let target = (text as NSString).range(of: issue)
      return NSSpellChecker.shared.check(
        text, range: NSRange(location: 0, length: (text as NSString).length), types: types,
        options: [:], inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil
      ).contains { result in
        result.resultType == .grammar
          && (result.grammarDetails ?? []).contains { detail in
            guard let range = (detail[NSGrammarRange] as? NSValue)?.rangeValue else {
              return result.range == target
            }
            return NSRange(location: result.range.location + range.location, length: range.length)
              == target
          }
      }
    }
    Environment.grammar = await waitUntil({
      flags("go", in: "He go to school yesterday. ") && flags("is", in: "They is happy. ")
    }, timeout: .seconds(3))
  }
  if Environment.grammar != true {
    try Test.cancel("文法チェッカーが前提の範囲で誤りを返さない環境なので、文法の印を確かめられない")
  }
}
