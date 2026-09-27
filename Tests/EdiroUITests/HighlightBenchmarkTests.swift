import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

extension AppKitTests {
  struct HighlightBenchmarkTests {
    // EDIRO_BENCHMARK=1 swift test -c release --filter HighlightBenchmarkTests
    // 描画を除く属性反映を測る。CI の合否を実時間の閾値に依存させない。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDIRO_BENCHMARK"] == "1"))
    func measureHighlight() async {
      let unit =
        "# Heading\n本文と**太字**と*斜体*。\n> 引用文です。\n- item [link](https://example.com)\n`code`\n\n"
      func milliseconds(_ duration: Duration) -> Double { duration / .milliseconds(1) }
      func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
      for size in [2500, 25000] {
        let text =
          String(String(repeating: unit, count: size / unit.count + 1).prefix(size)) + "\n> 引用"
        let state = makeState(text: text)
        let controller = EditorTextController(state: state)
        let storage = controller.textView.textStorage!
        let attributer = MarkdownAttributer(theme: state.theme, preferences: state.preferences)
        var highlightTimes: [Double] = []
        for sample in 0..<110 {
          let start = ContinuousClock.now
          attributer.apply(to: storage)
          if sample >= 10 { highlightTimes.append(milliseconds(start.duration(to: .now))) }
        }
        var latencyTimes: [Double] = []
        for _ in 0..<12 {
          let start = ContinuousClock.now
          controller.textView.insertText(
            "a", replacementRange: NSRange(location: storage.length, length: 0))
          let expected = SyntaxPalette(theme: state.theme).style(for: .blockquote).color.nsColor
          let reached = await waitUntil(
            {
              storage.attribute(.foregroundColor, at: storage.length - 1, effectiveRange: nil)
                as? NSColor == expected
            }, timeout: .seconds(2))
          #expect(reached)
          latencyTimes.append(milliseconds(start.duration(to: .now)))
          controller.highlight()
        }
        print(
          "BENCH chars=\(text.count) utf16=\((text as NSString).length) highlightMedianMs=\(median(highlightTimes)) inputAttributeMedianMs=\(median(latencyTimes))"
        )
      }
    }
  }
}
