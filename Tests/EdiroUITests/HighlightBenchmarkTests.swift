import AppKit
import EdiroCore
import EditorEngine
import EditorMarkdown
import Testing

@testable import EdiroUI

extension AppKitTests {
  struct HighlightBenchmarkTests {
    // EDIRO_BENCHMARK=1 swift test -c release --filter HighlightBenchmarkTests
    // 打鍵 1 回の同期処理 (エンジンの編集、行の再トークン化、本文の写しへの反映、属性の反映) を
    // 測る。レイアウトと描画は含めない。CI の合否を実時間の閾値に依存させない。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDIRO_BENCHMARK"] == "1"))
    func measureKeystroke() throws {
      let unit =
        "# Heading\n本文と**太字**と*斜体*。\n> 引用文です。\n- item [link](https://example.com)\n`code`\n\n"
      func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
      let state = makeState()
      let attributer = MarkdownAttributer(theme: state.theme, preferences: state.preferences)
      for size in [2500, 25000] {
        let body = String(String(repeating: unit, count: size / unit.count + 1).prefix(size))
        // 先頭は、もう 1 文字でフェンスになる行にしておく。開く向きは本文の前に置き、閉じる
        // 向きは開いたフェンスの次に置く。
        let opening = try Editing(text: "``\n" + body, attributer: attributer)
        defer { opening.observation?.cancel() }
        let closing = try Editing(text: "```\n``\n" + body, attributer: attributer)
        defer { closing.observation?.cancel() }
        let snapshot = opening.document.snapshot
        let middleLine = try #require(
          (snapshot.lineCount / 2..<snapshot.lineCount).first {
            (try? snapshot.line($0).hasPrefix("本文")) == true
          })
        let middle = try opening.measure(at: Position(middleLine, 3), "a")
        let open = try opening.measure(at: Position(0, 2), "`")
        let close = try closing.measure(at: Position(1, 2), "`")
        #expect(middle.lines == 1)
        #expect(open.lines == opening.document.snapshot.lineCount)
        #expect(close.lines == closing.document.snapshot.lineCount - 1)
        print(
          "BENCH utf16=\(opening.document.snapshot.utf16Count) lines=\(opening.document.snapshot.lineCount) middleMedianMs=\(median(middle.times)) fenceMedianMs=\(median(open.times)) fenceMaxMs=\(open.times.max()!) closeMedianMs=\(median(close.times)) closeMaxMs=\(close.times.max()!)"
        )
      }
    }

    /// 本文を写した表示側と、打鍵の計測。
    private final class Editing {
      let document: Document
      let session: EditorSession
      let layout = EditorLayout()
      var observation: Subscription?
      var restyled = IndexSet()

      init(text: String, attributer: MarkdownAttributer) throws {
        document = Document(id: "bench", text: text, lineTokenizer: MarkdownTokenizer())
        session = try EditorSession(document: document)
        layout.setWidth(600)
        layout.replaceAll(with: document.snapshot.text)
        attributer.applyAll(of: document, to: layout.storage)
        layout.ensureLayout()
        observation = try document.observe { [unowned self] event in
          for batch in event.batches { self.layout.apply(batch) }
          attributer.apply(lines: event.retokenizedLines, of: self.document, to: self.layout.storage)
          self.restyled = event.retokenizedLines
        }
      }

      /// 打鍵 1 回の時間と、属性を当て直した行の数。毎回取り消して同じ本文に戻す。
      func measure(at position: Position, _ input: String) throws -> (times: [Double], lines: Int) {
        var times: [Double] = []
        var lines = 0
        for sample in 0..<60 {
          try session.setSelections([Selection(position)])
          let start = ContinuousClock.now
          try session.type(input)
          let time = start.duration(to: .now) / .milliseconds(1)
          lines = restyled.count
          try document.undo()
          if sample >= 10 { times.append(time) }
        }
        return (times, lines)
      }
    }
  }
}
