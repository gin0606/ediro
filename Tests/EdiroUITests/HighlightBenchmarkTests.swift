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
      let links = { (_: Int) in
        "# Heading\n本文と**太字**と*斜体*。\n> 引用文です。\n- item [link](https://example.com)\n`code`\n\n"
      }
      // 和文の段落の途中に空白なしで続く素の URL を、リンクと同じ頻度で含める。URL の後ろにも
      // 段落が続く。URL はそれぞれ違い、検出結果を使い回せない。
      let bareURLs = { (index: Int) in
        "# Heading\n本文と**太字**と*斜体*。詳しくはhttps://example.com/docs/page-\(index)を参照してください。この段落はさらに続き、URL の後ろにも和文が並ぶ様子を確かめるための文章を書いておきます。\n> 引用文です。\n- item [link](https://example.com)\n`code`\n\n"
      }
      let state = makeState()
      let attributer = MarkdownAttributer(theme: state.theme, preferences: state.preferences)
      for (name, unit) in [("links", links), ("bareURLs", bareURLs)] {
        for size in [2500, 25000] {
          var body = ""
          var index = 0
          while body.count < size {
            body += unit(index)
            index += 1
          }
          body = String(body.prefix(size))
          let opened = ContinuousClock.now
          _ = Document(id: "open", text: body, lineTokenizer: MarkdownTokenizer())
          let openMs = opened.duration(to: .now) / .milliseconds(1)
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
          // 素の URL の中への打鍵。毎回違う文字を打ち、検出結果を使い回せないようにする。
          let urlColumn = try (snapshot.line(middleLine) as NSString).range(of: "docs").location
          let inURL =
            urlColumn == NSNotFound
            ? nil : try opening.measure(at: Position(middleLine, urlColumn), distinct: true)
          let open = try opening.measure(at: Position(0, 2), "`")
          let close = try closing.measure(at: Position(1, 2), "`")
          // 本文をまだ一度も本文としてトークン化していない状態で、フェンスを閉じる 1 打鍵。
          var coldCloses: [Double] = []
          for _ in 0..<5 {
            let cold = try Editing(text: "```\n``\n" + body, attributer: attributer)
            defer { cold.observation?.cancel() }
            coldCloses.append(try cold.time(at: Position(1, 2), "`"))
          }
          #expect(middle.lines == 1)
          #expect(open.lines == opening.document.snapshot.lineCount)
          #expect(close.lines == closing.document.snapshot.lineCount - 1)
          print(
            "BENCH \(name) utf16=\(opening.document.snapshot.utf16Count) lines=\(opening.document.snapshot.lineCount) openDocumentMs=\(openMs) middleMedianMs=\(median(middle.times)) inURLMedianMs=\(inURL.map { median($0.times) } ?? .nan) inURLMaxMs=\(inURL.map { $0.times.max()! } ?? .nan) fenceMedianMs=\(median(open.times)) fenceMaxMs=\(open.times.max()!) closeMedianMs=\(median(close.times)) closeMaxMs=\(close.times.max()!) coldCloseMedianMs=\(median(coldCloses)) coldCloseMaxMs=\(coldCloses.max()!)"
          )
        }
      }
    }

    /// 素の URL を多く含む 1 行。longLine は和文と URL が空白なしで混ざる 2.2 万字ほどの行。
    /// dense は空白で区切った URL が並ぶ行、notes は URL の直後に `(注n）` が続く行。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDIRO_BENCHMARK"] == "1"))
    func measureLongLine() throws {
      let prose = String(repeating: "日本語の文章がここに続きますが途中に句読点を含めない長い文になっています", count: 5)
      let lines: [(String, (Int) -> String, Int)] = [
        ("longLine", { prose + "https://example.com/docs/page-\($0)を参照し、" }, 22000),
        ("dense", { "https://example.com/docs/page-\($0) " }, 22000),
        ("notes", { "本文の続きhttps://example.com/docs/page-\($0)を参照(注\($0)）し、" }, 22000),
        // 空白なしで URL が並ぶ行 (JSON の配列や、カンマでつないだ URL)。
        ("quoted", { "\"https://example.com/docs/page-\($0)\"," }, 22000),
        ("joined", { "https://example.com/docs/page-\($0)," }, 22000),
      ]
      let state = makeState()
      let attributer = MarkdownAttributer(theme: state.theme, preferences: state.preferences)
      for (name, piece, size) in lines {
        var line = ""
        var count = 0
        while (line as NSString).length < size {
          line += piece(count)
          count += 1
        }
        // 検出結果の使い回しが空の状態で、行全体をトークン化する (ファイルを開いたときに相当)。
        var opens: [Double] = []
        for _ in 0..<5 {
          let opened = ContinuousClock.now
          _ = Document(id: "open", text: line, lineTokenizer: MarkdownTokenizer())
          opens.append(opened.duration(to: .now) / .milliseconds(1))
        }
        let editing = try Editing(text: line, attributer: attributer)
        defer { editing.observation?.cancel() }
        let middle = (line as NSString).range(of: "https://example.com/docs/page-\(count / 2)").location
        // URL の中と、その URL の窓のすぐ手前への打鍵。毎回違う文字を打つ。
        let inURL = try editing.measure(at: Position(0, middle + 20), distinct: true)
        let beforeURL = try editing.measure(at: Position(0, middle - 9), distinct: true)
        #expect(inURL.lines == 1)
        print(
          "BENCH \(name) utf16=\((line as NSString).length) urls=\(count) openDocumentMedianMs=\(median(opens)) openDocumentMaxMs=\(opens.max()!) inURLMedianMs=\(median(inURL.times)) inURLMaxMs=\(inURL.times.max()!) beforeURLMedianMs=\(median(beforeURL.times)) beforeURLMaxMs=\(beforeURL.times.max()!)"
        )
      }
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

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

      /// 打鍵 1 回の時間。
      func time(at position: Position, _ input: String) throws -> Double {
        try session.setSelections([Selection(position)])
        let start = ContinuousClock.now
        try session.type(input)
        return start.duration(to: .now) / .milliseconds(1)
      }

      /// 打鍵 1 回の時間と、属性を当て直した行の数。毎回取り消して同じ本文に戻す。
      /// `distinct` なら、`input` の代わりに毎回違う文字 (ひらがな) を打つ。
      func measure(at position: Position, _ input: String = "", distinct: Bool = false) throws -> (
        times: [Double], lines: Int
      ) {
        var times: [Double] = []
        var lines = 0
        for sample in 0..<60 {
          try session.setSelections([Selection(position)])
          let text = distinct ? String(UnicodeScalar(0x3041 + sample)!) : input
          let start = ContinuousClock.now
          try session.type(text)
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
