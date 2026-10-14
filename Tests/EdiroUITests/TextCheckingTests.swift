import AppKit
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったウィンドウとコントローラもテストの間は生かしておく。
private var retainedEditors: [(NSWindow, EditorTextController)] = []

/// 自動置換の入切と、打鍵する文字列。
nonisolated struct SubstitutionScenario: CustomTestStringConvertible, Sendable {
  var quotes = false
  var dashes = false
  let input: String

  var testDescription: String {
    "quotes=\(quotes) dashes=\(dashes) \(input.debugDescription)"
  }
}

extension AppKitTests {
  struct TextCheckingTests {
    private func makeEditor(text: String) -> (NSWindow, EditorView) {
      let controller = EditorTextController(state: makeState(text: text))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = controller.scrollView
      controller.editorView.setFrameSize(controller.scrollView.contentSize)
      window.makeFirstResponder(controller.editorView)
      window.orderFront(nil)
      retainedEditors.append((window, controller))
      return (window, controller.editorView)
    }

    /// 参照 NSTextView の `type(_:)` と同じく、一文字ずつ打鍵の経路で入れ、打鍵ごとにメイン
    /// アクターを明け渡す。自動置換はその間にメインキューで行われる。
    private func type(_ text: String, into view: EditorView) async {
      for character in text {
        view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        try? await Task.sleep(for: .milliseconds(20))
      }
    }

    /// 改行とタブをキーと同じくコマンド (`insertNewline:`、`insertTab:`) で入れ、ほかの文字は
    /// 打鍵の経路で入れる。
    private func typeWithCommands(_ text: String, into responder: NSResponder & NSTextInputClient) async {
      for character in text {
        switch character {
        case "\n": responder.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        case "\t": responder.doCommand(by: #selector(NSResponder.insertTab(_:)))
        default:
          responder.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        try? await Task.sleep(for: .milliseconds(20))
      }
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    // MARK: - 参照との差分

    nonisolated static let substitutionScenarios: [SubstitutionScenario] = [
      .init(input: "\"a\" it's a--b "),
      .init(quotes: true, input: "He said \"hi 'there'\" and left. "),
      .init(quotes: true, input: "'90s rock\n\"x\"\n"),
      .init(dashes: true, input: "one -- two --- three - four\n"),
      .init(quotes: true, dashes: true, input: "\"a--b\" it's "),
    ]

    @Test(arguments: substitutionScenarios)
    func 打鍵での自動置換は参照と同じ本文になり一回の取り消しで戻る(scenario: SubstitutionScenario) async {
      let reference = ReferenceTextView()
      defer { reference.close() }
      reference.textView.isAutomaticQuoteSubstitutionEnabled = scenario.quotes
      reference.textView.isAutomaticDashSubstitutionEnabled = scenario.dashes
      await reference.type(scenario.input)
      let expected = reference.textView.string

      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      view.isAutomaticQuoteSubstitutionEnabled = scenario.quotes
      view.isAutomaticDashSubstitutionEnabled = scenario.dashes
      await type(scenario.input, into: view)
      _ = await waitUntil({ view.text == expected }, timeout: .seconds(2))
      #expect(view.text == expected)

      reference.textView.undoManager?.undo()
      view.undo(nil)
      #expect(view.text == reference.textView.string)
    }

    // MARK: - 誤りの下線

    /// 誤りの印 (rendering attribute の `NSSpellingState`) が付いた区間と、その値。
    private func marks(_ view: EditorView) -> [NSRange: Int] {
      let manager = view.layout.layoutManager
      let start = manager.documentRange.location
      var marks: [NSRange: Int] = [:]
      manager.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, range in
        if let state = attributes[.spellingState] as? Int {
          let location = manager.offset(from: start, to: range.location)
          marks[NSRange(location: location, length: manager.offset(from: range.location, to: range.endLocation))] = state
        }
        return true
      }
      return marks
    }

    /// 範囲の下の帯を描いた画素。下線の有無を比べる。
    private func pixels(under range: NSRange, in view: EditorView) throws -> [NSColor] {
      view.layout.ensureLayout()
      let rect = view.firstRectInView(for: range)
      let band = NSRect(x: rect.minX, y: rect.maxY - 4, width: rect.width, height: 8).integral
      let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: rep)
      let scale = CGFloat(rep.pixelsWide) / view.bounds.width
      var colors: [NSColor] = []
      for y in Int(band.minY * scale)..<Int(band.maxY * scale) {
        for x in Int(band.minX * scale)..<Int(band.maxX * scale) {
          colors.append(try #require(rep.colorAt(x: x, y: y)))
        }
      }
      return colors
    }

    @Test func 既定では誤りに下線を引かずオンにすると引く() async throws {
      let text = "This is a mispeled word. "
      let word = (text as NSString).range(of: "mispeled")
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      #expect(!view.isContinuousSpellCheckingEnabled)
      await type(text, into: view)
      // 印が付くのを待つのと同じだけ待っても、付かない。
      try? await Task.sleep(for: .seconds(1))
      #expect(marks(view).isEmpty)
      let plain = try pixels(under: word, in: view)

      view.toggleContinuousSpellChecking(nil)
      #expect(view.isContinuousSpellCheckingEnabled)
      #expect(await waitUntil({ marks(view)[word] != nil }, timeout: .seconds(3)))
      #expect(marks(view) == [word: NSAttributedString.SpellingState.spelling.rawValue])
      // 下線は Markdown の装飾 (本文の写しの属性) を当て直しても消えない。
      await type("x", into: view)
      #expect(marks(view)[word] != nil)
      #expect(try pixels(under: word, in: view) != plain)

      view.toggleContinuousSpellChecking(nil)
      #expect(marks(view).isEmpty)
    }

    /// 注釈の `NSSpellingState` から求めた、描くべき誤りの印。
    private func expectedMarks(_ view: EditorView) -> [NSRange: Int] {
      var marks: [NSRange: Int] = [:]
      let annotations = view.textChecker.annotations
      annotations.enumerateAttribute(
        .spellingState, in: NSRange(location: 0, length: annotations.length)
      ) { value, range, _ in
        if let state = (value as? String).flatMap(Int.init), state & 3 != 0 { marks[range] = state & 3 }
      }
      return marks
    }

    @Test func 誤りの下線は編集しても注釈と同じ文字に付いている() async {
      let text = "teh wrod\nsome mroe text\nlast lien"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([caret((text as NSString).length)], primary: 0)
      view.isContinuousSpellCheckingEnabled = true
      #expect(await waitUntil({ marks(view).count >= 2 }, timeout: .seconds(3)))
      let edits: [(String, () -> Void)] = [
        ("前に挿入", { view.select([self.caret(0)], primary: 0); view.type("xx ") }),
        ("誤りの中に挿入", { view.select([self.caret(5)], primary: 0); view.type("Z") }),
        ("行をまたいで削除", { view.select([NSRange(location: 8, length: 8)], primary: 0); view.delete(nil) }),
        ("複数のキャレットで挿入", { view.select([self.caret(0), self.caret(9)], primary: 0); view.type("yy ") }),
        (
          "複数の範囲を削除",
          { view.select([NSRange(location: 1, length: 2), NSRange(location: 10, length: 2)], primary: 0); view.delete(nil) }
        ),
        ("取り消し", { view.undo(nil) }),
        ("やり直し", { view.redo(nil) }),
        ("本文の差し替え", { view.replaceText("teh new wrod") }),
      ]
      for (name, edit) in edits {
        edit()
        #expect(view.textChecker.annotations.string == view.text, "\(name)")
        #expect(marks(view) == expectedMarks(view), "\(name)")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(marks(view) == expectedMarks(view), "\(name) の後の検査")
      }
      #expect(!marks(view).isEmpty)
    }

    @Test func 文法の誤りは入力中の検査と文法の検査が両方オンのときだけ印を付ける() async throws {
      try await requireGrammarCheckingAvailable()
      let text = "He go to school yesterday and they is happy. "
      let verb = (text as NSString).range(of: "go")
      let grammar = NSAttributedString.SpellingState.grammar.rawValue
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      #expect(view.isGrammarCheckingEnabled)
      // 文法の検査は、キャレットのある文を書き終えるまで待つ。キャレットを文の外に置く。
      view.select([caret((text as NSString).length)], primary: 0)
      view.isContinuousSpellCheckingEnabled = true
      #expect(await waitUntil({ marks(view)[verb] == grammar }, timeout: .seconds(3)))

      view.toggleGrammarChecking(nil)
      #expect(!view.isGrammarCheckingEnabled)
      try? await Task.sleep(for: .seconds(1))
      #expect(!marks(view).values.contains(grammar))

      view.toggleGrammarChecking(nil)
      #expect(await waitUntil({ marks(view)[verb] == grammar }, timeout: .seconds(3)))
      view.isContinuousSpellCheckingEnabled = false
      #expect(marks(view).isEmpty)
    }

    // MARK: - 候補、学習、無視

    /// 右クリックで開いたメニューの、`action` を持つ項目。
    private func menuItem(_ action: String, clicking location: Int, in view: EditorView) throws
      -> NSMenuItem
    {
      let character = NSRange(location: location, length: 1)
      let rect = view.firstRectInView(for: character)
      let event = try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
          modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      let menu = try #require(view.menu(for: event))
      return try #require(menu.items.first { $0.action.map(NSStringFromSelector) == action })
    }

    private func perform(_ item: NSMenuItem) {
      NSApp.sendAction(try! #require(item.action), to: item.target, from: item)
    }

    @Test func 誤りの単語の候補で置き換え一回の取り消しで戻る() throws {
      let text = "This is a mispeled word."
      let word = (text as NSString).range(of: "mispeled")
      let guess = try #require(
        NSSpellChecker.shared.guesses(
          forWordRange: word, in: text, language: nil, inSpellDocumentWithTag: 0)?.first)
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let item = try menuItem("_changeSpellingFromMenu:", clicking: 12, in: view)
      #expect(item.title == guess)
      perform(item)
      let replaced = (text as NSString).replacingCharacters(in: word, with: guess)
      #expect(view.text == replaced)
      view.undo(nil)
      #expect(view.text == text)
      view.redo(nil)
      #expect(view.text == replaced)
    }

    @Test func 候補での置き換えの後ろのキャレットは長さの差だけずれる() {
      let text = "a mispeled word"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([caret(1), caret(15)], primary: 0)
      view.textChecker.replaceCharacters(
        in: NSRange(location: 2, length: 8), withAnnotatedString: NSAttributedString(string: "misspelled"))
      #expect(view.text == "a misspelled word")
      #expect(view.session.selections.map { view.nsRange(of: $0.range) } == [caret(1), caret(17)])
    }

    @Test func 改行を含む置き換えは改行を揃えて当てる() {
      let (window, view) = makeEditor(text: "ab")
      defer { window.close() }
      view.select([caret(2)], primary: 0)
      view.textChecker.replaceCharacters(
        in: NSRange(location: 1, length: 1),
        withAnnotatedString: NSAttributedString(string: "x\r\ny", attributes: [.spellingState: "1"]))
      view.textChecker.replaceCharacters(
        in: NSRange(location: 0, length: 1),
        withAnnotatedString: NSAttributedString(string: "a", attributes: [.spellingState: "1"]))
      #expect(view.text == "ax\ny")
      #expect(view.textChecker.annotations.string == view.text)
      // 入力中の検査がオフなので、置き換えた文字が持つ誤りの印も付けない。
      #expect(marks(view).isEmpty)
      #expect(view.selectedRange() == caret(4))
    }

    @Test func 無視した単語はこの文書で誤りとしない() async throws {
      let word = "zqxwvedirox"
      let text = "Some \(word) here."
      let range = (text as NSString).range(of: word)
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.isContinuousSpellCheckingEnabled = true
      #expect(await waitUntil({ marks(view)[range] != nil }, timeout: .seconds(3)))
      perform(try menuItem("_ignoreSpellingFromMenu:", clicking: range.location + 1, in: view))
      #expect(await waitUntil({ marks(view).isEmpty }, timeout: .seconds(3)))
      let tag = view.textChecker.controller.spellCheckerDocumentTag
      #expect(NSSpellChecker.shared.ignoredWords(inSpellDocumentWithTag: tag)?.contains(word) == true)
      #expect(!NSSpellChecker.shared.hasLearnedWord(word))
    }

    @Test func 学習した単語は誤りとしない() async throws {
      let word = "qzxwvlearnedirox"
      let text = "Some \(word) here."
      let range = (text as NSString).range(of: word)
      let checker = NSSpellChecker.shared
      // 前の実行が途中で止まって学習が残っていても、学習していない状態から始める。
      checker.unlearnWord(word)
      defer { checker.unlearnWord(word) }
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.isContinuousSpellCheckingEnabled = true
      #expect(await waitUntil({ marks(view)[range] != nil }, timeout: .seconds(3)))
      perform(try menuItem("_learnSpellingFromMenu:", clicking: range.location + 1, in: view))
      #expect(checker.hasLearnedWord(word))
      #expect(await waitUntil({ marks(view).isEmpty }, timeout: .seconds(3)))
    }

    /// スペルパネルの代わりの送り手。NSTextView と同じく、`selectedCell` の文字を使う。
    private func spellingPanelStandIn(_ word: String) -> NSTextField { NSTextField(string: word) }

    @Test func スペルパネルの変更は選択を置き換え参照と同じ本文になる() throws {
      let text = "This is a mispeled word."
      let word = (text as NSString).range(of: "mispeled")
      let reference = ReferenceTextView(text: text)
      defer { reference.close() }
      reference.textView.setSelectedRange(word)
      reference.textView.changeSpelling(spellingPanelStandIn("misspelled"))

      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([word], primary: 0)
      view.changeSpelling(spellingPanelStandIn("misspelled"))
      #expect(view.text == reference.textView.string)
      #expect(view.selectedRange() == reference.textView.selectedRange())
      reference.textView.undoManager?.undo()
      view.undo(nil)
      #expect(view.text == text)
      #expect(reference.textView.string == text)
    }

    // MARK: - 入切

    /// NSTextView と同じ名前の入切の値。
    private static let toggles: [(action: Selector, value: ReferenceWritableKeyPath<EditorView, Bool>, reference: ReferenceWritableKeyPath<NSTextView, Bool>)] = [
      (#selector(EditorView.toggleContinuousSpellChecking(_:)), \.isContinuousSpellCheckingEnabled, \.isContinuousSpellCheckingEnabled),
      (#selector(EditorView.toggleGrammarChecking(_:)), \.isGrammarCheckingEnabled, \.isGrammarCheckingEnabled),
      (#selector(EditorView.toggleAutomaticSpellingCorrection(_:)), \.isAutomaticSpellingCorrectionEnabled, \.isAutomaticSpellingCorrectionEnabled),
      (#selector(EditorView.toggleSmartInsertDelete(_:)), \.smartInsertDeleteEnabled, \.smartInsertDeleteEnabled),
      (#selector(EditorView.toggleAutomaticQuoteSubstitution(_:)), \.isAutomaticQuoteSubstitutionEnabled, \.isAutomaticQuoteSubstitutionEnabled),
      (#selector(EditorView.toggleAutomaticDashSubstitution(_:)), \.isAutomaticDashSubstitutionEnabled, \.isAutomaticDashSubstitutionEnabled),
      (#selector(EditorView.toggleAutomaticLinkDetection(_:)), \.isAutomaticLinkDetectionEnabled, \.isAutomaticLinkDetectionEnabled),
      (#selector(EditorView.toggleAutomaticDataDetection(_:)), \.isAutomaticDataDetectionEnabled, \.isAutomaticDataDetectionEnabled),
      (#selector(EditorView.toggleAutomaticTextReplacement(_:)), \.isAutomaticTextReplacementEnabled, \.isAutomaticTextReplacementEnabled),
    ]

    @Test func 入切の既定値は参照と同じで切り替えるとメニューのチェック印も変わる() {
      let reference = ReferenceTextView()
      defer { reference.close() }
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      for toggle in Self.toggles {
        let name = NSStringFromSelector(toggle.action)
        #expect(view[keyPath: toggle.value] == reference.textView[keyPath: toggle.reference], "\(name)")
        let item = NSMenuItem(title: "", action: toggle.action, keyEquivalent: "")
        for _ in 0..<2 {
          let before = view[keyPath: toggle.value]
          view.perform(toggle.action, with: item)
          reference.textView.perform(toggle.action, with: item)
          #expect(view[keyPath: toggle.value] == !before, "\(name)")
          #expect(view[keyPath: toggle.value] == reference.textView[keyPath: toggle.reference], "\(name)")
          #expect(view.validateUserInterfaceItem(item))
          #expect(item.state == (view[keyPath: toggle.value] ? .on : .off), "\(name)")
        }
      }
    }

    @Test func 効果を実装した検査と置換だけをコントローラに伝える() {
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      let checker = view.textChecker
      for toggle in Self.toggles { view[keyPath: toggle.value] = true }
      #expect(checker.spellCheckingType == .yes)
      #expect(checker.grammarCheckingType == .yes)
      #expect(checker.smartQuotesType == .yes)
      #expect(checker.smartDashesType == .yes)
      #expect(checker.textReplacementType == .yes)
      #expect(checker.autocorrectionType == .no)
      #expect(checker.smartInsertDeleteType == .yes)
      #expect(checker.linkDetectionType == .yes)
      #expect(checker.dataDetectionType == .yes)
      #expect(checker.textCompletionType == .default)
      view.isGrammarCheckingEnabled = true
      view.isContinuousSpellCheckingEnabled = false
      // 文法は入力中のスペルチェックと合わせて検査する (NSTextView と同じ)。
      #expect(checker.grammarCheckingType == .no)
      for toggle in Self.toggles { view[keyPath: toggle.value] = false }
      for type in [
        checker.spellCheckingType, checker.grammarCheckingType, checker.smartQuotesType,
        checker.smartDashesType, checker.textReplacementType,
      ] {
        #expect(type == .no)
      }
    }

    @Test func テキスト置換の結果はエンジン経由で当て一回の取り消しで戻る() {
      // システムのテキスト置換の一覧はテストのプロセスから空に見えるので、コントローラが
      // 置換の結果を当てるときの呼び出しを直接行う。
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      view.isAutomaticTextReplacementEnabled = true
      for character in "say omw now" {
        view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
      }
      view.textChecker.replaceCharacters(
        in: NSRange(location: 4, length: 3),
        withAnnotatedString: NSAttributedString(
          string: "On my way!", attributes: [NSAttributedString.Key("NSReplacedString"): "omw"]))
      #expect(view.text == "say On my way! now")
      #expect(view.selectedRange() == caret(18))
      #expect(
        view.textChecker.annotations.attribute(
          NSAttributedString.Key("NSReplacedString"), at: 4, effectiveRange: nil) as? String == "omw")
      view.undo(nil)
      #expect(view.text == "say omw now")
    }

    // MARK: - 打鍵以外の入力、変換中、複数のキャレット

    @Test func 貼り付けた文字は参照と同じく自動置換しない() async {
      let pasteboard = NSPasteboard(name: NSPasteboard.Name("ediro.test.substitution"))
      defer { pasteboard.releaseGlobally() }
      pasteboard.clearContents()
      pasteboard.setString("\"a--b\" ", forType: .string)
      let reference = ReferenceTextView()
      defer { reference.close() }
      reference.textView.isAutomaticQuoteSubstitutionEnabled = true
      reference.textView.isAutomaticDashSubstitutionEnabled = true
      reference.textView.readSelection(from: pasteboard, type: .string)
      await reference.type("x ")

      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      view.isAutomaticQuoteSubstitutionEnabled = true
      view.isAutomaticDashSubstitutionEnabled = true
      view.paste(from: pasteboard)
      await type("x ", into: view)
      try? await Task.sleep(for: .milliseconds(500))
      #expect(view.text == reference.textView.string)
    }

    @Test func 引用符の置換を通さないコマンドで入れた引用符は参照と同じく置き換えない() async {
      let reference = ReferenceTextView()
      defer { reference.close() }
      reference.textView.isAutomaticQuoteSubstitutionEnabled = true
      await reference.type("a ")
      reference.textView.insertDoubleQuoteIgnoringSubstitution(nil)
      await reference.type("b")
      reference.textView.insertSingleQuoteIgnoringSubstitution(nil)
      await reference.type("s \"c\" ")

      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      view.isAutomaticQuoteSubstitutionEnabled = true
      await type("a ", into: view)
      view.insertDoubleQuoteIgnoringSubstitution(nil)
      await type("b", into: view)
      view.insertSingleQuoteIgnoringSubstitution(nil)
      await type("s \"c\" ", into: view)
      _ = await waitUntil({ view.text == reference.textView.string }, timeout: .seconds(2))
      #expect(view.text == reference.textView.string)
    }

    @Test func 変換中の文字は確定しても参照と同じく自動置換しない() async {
      let reference = ReferenceTextView()
      defer { reference.close() }
      reference.textView.isAutomaticQuoteSubstitutionEnabled = true
      await reference.type("a ")
      reference.textView.setMarkedText(
        "\"x", selectedRange: caret(2), replacementRange: NSRange(location: NSNotFound, length: 0))
      try? await Task.sleep(for: .milliseconds(300))
      let referenceMarked = reference.textView.string
      reference.textView.insertText(
        "\"x\"", replacementRange: NSRange(location: NSNotFound, length: 0))
      await reference.type(" ")

      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      view.isAutomaticQuoteSubstitutionEnabled = true
      await type("a ", into: view)
      view.setMarkedText(
        "\"x", selectedRange: caret(2), replacementRange: NSRange(location: NSNotFound, length: 0))
      try? await Task.sleep(for: .milliseconds(300))
      #expect(view.hasMarkedText())
      #expect(view.text == referenceMarked)
      view.insertText("\"x\"", replacementRange: NSRange(location: NSNotFound, length: 0))
      await type(" ", into: view)
      _ = await waitUntil({ view.text == reference.textView.string }, timeout: .seconds(2))
      #expect(view.text == reference.textView.string)
    }

    @Test func 変換中はコントローラからの置き換えを当てない() {
      let (window, view) = makeEditor(text: "a--b")
      defer { window.close() }
      view.select([caret(4)], primary: 0)
      view.setMarkedText("か", selectedRange: caret(1), replacementRange: caret(NSNotFound))
      view.textChecker.replaceCharacters(
        in: NSRange(location: 1, length: 2), withAnnotatedString: NSAttributedString(string: "—"))
      #expect(view.text == "a--bか")
      #expect(view.hasMarkedText())
    }

    @Test func 複数のキャレットではキャレットごとに打鍵した文字を置き換える() async {
      let (window, view) = makeEditor(text: "one\ntwo")
      defer { window.close() }
      view.isAutomaticQuoteSubstitutionEnabled = true
      view.isAutomaticDashSubstitutionEnabled = true
      view.select([caret(3), caret(7)], primary: 0)
      await type(" \"a--b\" ", into: view)
      let expected = "one “a—b” \ntwo “a—b” "
      #expect(await waitUntil({ view.text == expected }, timeout: .seconds(2)))
      #expect(view.session.selections.map { view.nsRange(of: $0.range) } == [caret(10), caret(21)])
      // 同じ検査で行った両方のキャレットの置き換えを、一回で取り消す。
      view.undo(nil)
      #expect(view.text == "one \"a--b\" \ntwo \"a--b\" ")
    }

    // MARK: - 打鍵以外で入った文字の検査と置換

    @Test func 貼り付けた誤りの単語は参照と同じく検査して下線を引く() async {
      let pasteboard = NSPasteboard(name: NSPasteboard.Name("ediro.test.spelling"))
      defer { pasteboard.releaseGlobally() }
      pasteboard.clearContents()
      pasteboard.setString("some mispeled text", forType: .string)
      let word = NSRange(location: 5, length: 8)
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      view.isContinuousSpellCheckingEnabled = true
      view.paste(from: pasteboard)
      #expect(await waitUntil({ marks(view)[word] != nil }, timeout: .seconds(3)))
      // 取り消しで戻った誤りも検査する。
      view.select([NSRange(location: 0, length: (view.text as NSString).length)], primary: 0)
      view.delete(nil)
      #expect(marks(view).isEmpty)
      view.undo(nil)
      #expect(await waitUntil({ marks(view)[word] != nil }, timeout: .seconds(3)))
    }

    @Test func 確定した変換の文字は自動置換せず検査して下線を引く() async throws {
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      view.isContinuousSpellCheckingEnabled = true
      view.isAutomaticQuoteSubstitutionEnabled = true
      let none = NSRange(location: NSNotFound, length: 0)
      // unmarkText での確定、違う文字での確定、クリックでの確定。
      view.setMarkedText("zqxwa", selectedRange: caret(5), replacementRange: none)
      view.unmarkText()
      view.insertText(" ", replacementRange: none)
      view.setMarkedText("zqx", selectedRange: caret(3), replacementRange: none)
      view.insertText("zqxwb", replacementRange: none)
      view.insertText(" ", replacementRange: none)
      view.setMarkedText("\"zqxwc\"", selectedRange: caret(7), replacementRange: none)
      let click = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: view.convert(NSPoint(x: 1, y: 1), to: nil),
          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
          eventNumber: 0, clickCount: 1, pressure: 1))
      view.mouseDown(with: click)
      #expect(!view.hasMarkedText())
      // キャレットに接する単語は、キャレットが離れるまで誤りとしない (NSTextView と同じ)。
      view.select([caret((view.text as NSString).length)], primary: 0)
      let words = ["zqxwa", "zqxwb", "zqxwc"].map { (view.text as NSString).range(of: $0) }
      #expect(await waitUntil({ words.allSatisfy { marks(view)[$0] != nil } }, timeout: .seconds(3)))
      #expect(view.text == "zqxwa zqxwb \"zqxwc\"")
    }

    @Test func 複数のキャレットで確定した変換の文字をそれぞれ検査する() async {
      let (window, view) = makeEditor(text: "a\nb")
      defer { window.close() }
      view.isContinuousSpellCheckingEnabled = true
      view.select([caret(1), caret(3)], primary: 0)
      let none = NSRange(location: NSNotFound, length: 0)
      view.setMarkedText(" zqxwd", selectedRange: caret(6), replacementRange: none)
      view.unmarkText()
      #expect(view.text == "a zqxwd\nb zqxwd")
      // キャレットのある単語は、キャレットが離れるまで誤りとしない (NSTextView と同じ)。
      view.select([caret(0)], primary: 0)
      let first = NSRange(location: 2, length: 5)
      let second = NSRange(location: 10, length: 5)
      #expect(await waitUntil({ marks(view)[first] != nil && marks(view)[second] != nil }, timeout: .seconds(3)))
    }

    @Test func 前からある文字と打鍵した文字にまたがる自動置換は参照と同じく当てる() async {
      let reference = ReferenceTextView(text: "a-")
      defer { reference.close() }
      reference.textView.isAutomaticDashSubstitutionEnabled = true
      reference.textView.setSelectedRange(caret(2))
      await reference.type("-b ")

      let (window, view) = makeEditor(text: "a-")
      defer { window.close() }
      view.isAutomaticDashSubstitutionEnabled = true
      view.select([caret(2)], primary: 0)
      await type("-b ", into: view)
      _ = await waitUntil({ view.text == reference.textView.string }, timeout: .seconds(2))
      #expect(view.text == reference.textView.string)
    }

    @Test func 自動置換を取り消した後に打鍵を続けても参照と同じく置き換え直さない() async {
      let reference = ReferenceTextView()
      defer { reference.close() }
      reference.textView.isAutomaticQuoteSubstitutionEnabled = true
      reference.textView.isAutomaticDashSubstitutionEnabled = true
      await reference.type("\"a--b\" ")
      reference.textView.undoManager?.undo()
      await reference.type("c ")

      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      view.isAutomaticQuoteSubstitutionEnabled = true
      view.isAutomaticDashSubstitutionEnabled = true
      await type("\"a--b\" ", into: view)
      _ = await waitUntil({ view.text.contains("—") }, timeout: .seconds(2))
      view.undo(nil)
      await type("c ", into: view)
      try? await Task.sleep(for: .milliseconds(500))
      #expect(view.text == reference.textView.string)
    }

    @Test func 打鍵した文字を含まない範囲への自動置換は当てない() {
      let (window, view) = makeEditor(text: "a--b \"c\"")
      defer { window.close() }
      let substitution: (String, String) -> NSAttributedString = {
        NSAttributedString(string: $0, attributes: [TextChecker.replacedString: $1])
      }
      view.textChecker.replaceCharacters(
        in: NSRange(location: 1, length: 2), withAnnotatedString: substitution("—", "--"))
      view.textChecker.replaceCharacters(
        in: NSRange(location: 5, length: 1), withAnnotatedString: substitution("“", "\""))
      #expect(view.text == "a--b \"c\"")
      // 候補での置き換えは、打鍵したかによらず当てる。
      view.textChecker.replaceCharacters(
        in: NSRange(location: 0, length: 1), withAnnotatedString: NSAttributedString(string: "A"))
      #expect(view.text == "A--b \"c\"")
    }

    @Test func 置換のパネルで変えた値をメニューと同じ入切に入れる() {
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      let checker = view.textChecker
      checker.smartQuotesType = .yes
      checker.smartDashesType = .yes
      checker.textReplacementType = .yes
      checker.linkDetectionType = .yes
      checker.spellCheckingType = .yes
      #expect(view.isAutomaticQuoteSubstitutionEnabled)
      #expect(view.isAutomaticDashSubstitutionEnabled)
      #expect(view.isAutomaticTextReplacementEnabled)
      #expect(view.isAutomaticLinkDetectionEnabled)
      #expect(view.isContinuousSpellCheckingEnabled)
      checker.smartQuotesType = .default
      #expect(view.isAutomaticQuoteSubstitutionEnabled)
      checker.smartQuotesType = .no
      #expect(!view.isAutomaticQuoteSubstitutionEnabled)
    }

    @Test func 改行とタブのコマンドでも打鍵と同じく参照と同じに自動置換する() async {
      let input = "\"x\"\ta--b\n'y'\n"
      let reference = ReferenceTextView()
      defer { reference.close() }
      reference.textView.isAutomaticQuoteSubstitutionEnabled = true
      reference.textView.isAutomaticDashSubstitutionEnabled = true
      await typeWithCommands(input, into: reference.textView)
      try? await Task.sleep(for: .milliseconds(500))

      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      view.isAutomaticQuoteSubstitutionEnabled = true
      view.isAutomaticDashSubstitutionEnabled = true
      await typeWithCommands(input, into: view)
      _ = await waitUntil({ view.text == reference.textView.string }, timeout: .seconds(2))
      #expect(view.text == reference.textView.string)
      #expect(view.text != input)
    }

    @Test func 打鍵以外の編集で誤りが直れば下線を外す() async {
      let text = "Some wordd here."
      let word = (text as NSString).range(of: "wordd")
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([caret((text as NSString).length)], primary: 0)
      view.isContinuousSpellCheckingEnabled = true
      #expect(await waitUntil({ marks(view)[word] != nil }, timeout: .seconds(3)))
      view.select([NSRange(location: NSMaxRange(word) - 1, length: 1)], primary: 0)
      view.delete(nil)
      view.select([caret((view.text as NSString).length)], primary: 0)
      #expect(await waitUntil({ marks(view).isEmpty }, timeout: .seconds(3)))
      view.undo(nil)
      view.select([caret((view.text as NSString).length)], primary: 0)
      #expect(await waitUntil({ marks(view)[word] != nil }, timeout: .seconds(3)))
    }

    @Test func 入切をオフにした後に届いた結果の印は付けない() {
      let (window, view) = makeEditor(text: "teh wrod")
      defer { window.close() }
      let checker = view.textChecker
      let range = NSRange(location: 4, length: 4)
      // 入力中の検査がオフなら、スペルの印も文法の印も付けない。
      checker.addAnnotations([.spellingState: "1"], range: range)
      checker.setAnnotations([.spellingState: "2"], range: NSRange(location: 0, length: 3))
      #expect(marks(view).isEmpty)
      #expect(expectedMarks(view).isEmpty)
      // 文法の検査だけがオフなら、文法の印だけを外す。
      view.isContinuousSpellCheckingEnabled = true
      view.isGrammarCheckingEnabled = false
      checker.addAnnotations(
        [.spellingState: "3", NSAttributedString.Key("NSGrammarCorrections"): "word"], range: range)
      #expect(marks(view) == [range: NSAttributedString.SpellingState.spelling.rawValue])
      #expect(
        checker.annotations.attribute(NSAttributedString.Key("NSGrammarCorrections"), at: 4, effectiveRange: nil)
          == nil)
      checker.setAnnotations([.spellingState: "2"], range: NSRange(location: 0, length: 3))
      #expect(marks(view) == [range: NSAttributedString.SpellingState.spelling.rawValue])
    }

    @Test func 置き換えを頼んだ範囲には打鍵していない文字でも自動置換を当てる() {
      let (window, view) = makeEditor(text: "a--b c--d")
      defer { window.close() }
      let dash = NSAttributedString(string: "—", attributes: [TextChecker.replacedString: "--"])
      view.select([NSRange(location: 0, length: 4)], primary: 0)
      view.textChecker.allowSubstitutions(in: NSRange(location: 0, length: 4))
      view.textChecker.replaceCharacters(in: NSRange(location: 1, length: 2), withAnnotatedString: dash)
      #expect(view.text == "a—b c--d")
      // 頼まれていない範囲と、利用者が編集した後の範囲には当てない。
      view.textChecker.replaceCharacters(in: NSRange(location: 6, length: 2), withAnnotatedString: dash)
      view.textChecker.allowSubstitutions(in: NSRange(location: 0, length: 8))
      view.select([caret(0)], primary: 0)
      view.type("x")
      view.textChecker.replaceCharacters(in: NSRange(location: 7, length: 2), withAnnotatedString: dash)
      #expect(view.text == "xa—b c--d")
    }

    @Test func スペルパネルで無視した単語は本文を差し替えてもこの文書で誤りとしない() async throws {
      let word = "zqxwvresetirox"
      let text = "Some \(word) here."
      let range = (text as NSString).range(of: word)
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.isContinuousSpellCheckingEnabled = true
      #expect(await waitUntil({ marks(view)[range] != nil }, timeout: .seconds(3)))
      view.select([range], primary: 0)
      view.ignoreSpelling(spellingPanelStandIn(word))
      let tag = view.textChecker.controller.spellCheckerDocumentTag
      #expect(NSSpellChecker.shared.ignoredWords(inSpellDocumentWithTag: tag)?.contains(word) == true)
      #expect(await waitUntil({ marks(view).isEmpty }, timeout: .seconds(3)))
      view.replaceText("Other \(word) and wrod.")
      let other = ("Other \(word) and wrod." as NSString).range(of: "wrod")
      #expect(await waitUntil({ marks(view)[other] != nil }, timeout: .seconds(3)))
      #expect(marks(view).count == 1)
    }

    // MARK: - メニューのコマンド

    @Test func 選択の中の引用符とダッシュの置き換えは参照と同じ本文になる() async {
      let text = "say \"hi\" -- it's \"x\""
      for action in [
        #selector(EditorView.replaceQuotesInSelection(_:)),
        #selector(EditorView.replaceDashesInSelection(_:)),
      ] {
        let reference = ReferenceTextView(text: text)
        defer { reference.close() }
        reference.textView.setSelectedRange(NSRange(location: 0, length: 18))
        reference.textView.perform(action, with: nil)
        try? await Task.sleep(for: .milliseconds(300))

        let (window, view) = makeEditor(text: text)
        defer { window.close() }
        view.select([NSRange(location: 0, length: 18)], primary: 0)
        view.perform(action, with: nil)
        _ = await waitUntil({ view.text == reference.textView.string }, timeout: .seconds(2))
        #expect(view.text == reference.textView.string, "\(action)")
        #expect(view.text != text, "\(action)")
        #expect(view.selectedRange() == reference.textView.selectedRange(), "\(action)")
        view.undo(nil)
        #expect(view.text == text, "\(action)")
      }
    }

    @Test func 文書の検査は参照と同じく次の誤りの単語を選んで下線を引く() async {
      let text = "Fine wrods here and mroe."
      let reference = ReferenceTextView(text: text)
      defer { reference.close() }
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      reference.textView.setSelectedRange(caret(0))
      view.select([caret(0)], primary: 0)
      for _ in 0..<2 {
        reference.textView.checkSpelling(nil)
        view.checkSpelling(nil)
        #expect(view.selectedRange() == reference.textView.selectedRange())
      }
      // 入力中の検査がオフでも、見つけた誤りには下線を引く (NSTextView と同じ)。
      #expect(!view.isContinuousSpellCheckingEnabled)
      let found = NSRange(location: 5, length: 5)
      #expect(await waitUntil({ marks(view)[found] != nil }, timeout: .seconds(3)))
      let other = NSRange(location: 20, length: 4)
      #expect(await waitUntil({ marks(view)[other] != nil }, timeout: .seconds(3)))
      // 文法の検査の入切を変えても、見つけた誤りの印は残る (NSTextView と同じ)。
      view.toggleGrammarChecking(nil)
      view.toggleGrammarChecking(nil)
      try? await Task.sleep(for: .milliseconds(300))
      #expect(marks(view)[found] != nil)
      // 入力中の検査がオフなので検査し直さない。編集した単語の印だけを外す。
      view.select([NSRange(location: 6, length: 2)], primary: 0)
      view.insertText("or", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(view.text == "Fine words here and mroe.")
      #expect(marks(view) == [other: NSAttributedString.SpellingState.spelling.rawValue])
    }
  }
}
