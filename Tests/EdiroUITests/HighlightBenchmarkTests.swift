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
      func milliseconds(_ duration: Duration) -> Double { duration / .milliseconds(1) }
      func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
      let state = makeState()
      let attributer = MarkdownAttributer(theme: state.theme, preferences: state.preferences)
      for size in [2500, 25000] {
        // 先頭は、もう 1 文字でフェンスになる行にしておく。
        let text = "``\n" + String(String(repeating: unit, count: size / unit.count + 1).prefix(size))
        let document = Document(id: "bench", text: text, lineTokenizer: MarkdownTokenizer())
        let session = try EditorSession(document: document)
        let layout = EditorLayout()
        layout.setWidth(600)
        layout.replaceAll(with: document.snapshot.text)
        attributer.applyAll(of: document, to: layout.storage)
        layout.ensureLayout()
        var restyled = IndexSet()
        let observation = try document.observe { event in
          for batch in event.batches { layout.apply(batch) }
          attributer.apply(lines: event.retokenizedLines, of: document, to: layout.storage)
          restyled = event.retokenizedLines
        }
        defer { observation.cancel() }

        /// 打鍵 1 回の時間と、属性を当て直した行の数。毎回取り消して同じ本文に戻す。
        func measure(at position: Position, _ input: String) throws -> (times: [Double], lines: Int) {
          var times: [Double] = []
          var lines = 0
          for sample in 0..<60 {
            try session.setSelections([Selection(position)])
            let start = ContinuousClock.now
            try session.type(input)
            let time = milliseconds(start.duration(to: .now))
            lines = restyled.count
            try document.undo()
            if sample >= 10 { times.append(time) }
          }
          return (times, lines)
        }
        let snapshot = document.snapshot
        let middleLine = try #require(
          (snapshot.lineCount / 2..<snapshot.lineCount).first {
            (try? snapshot.line($0).hasPrefix("本文")) == true
          })
        let middle = try measure(at: Position(middleLine, 3), "a")
        let fence = try measure(at: Position(0, 2), "`")
        #expect(middle.lines == 1)
        #expect(fence.lines == document.snapshot.lineCount)
        print(
          "BENCH utf16=\(document.snapshot.utf16Count) lines=\(document.snapshot.lineCount) middleMedianMs=\(median(middle.times)) fenceMedianMs=\(median(fence.times)) fenceMaxMs=\(fence.times.max()!)"
        )
      }
    }
  }
}
