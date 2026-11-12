import AppKit
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったウィンドウとコントローラもテストの間は生かしておく。
private var retainedEditors: [(NSWindow, EditorTextController)] = []

extension AppKitTests {
  /// 補完、スマートな挿入と削除、スペルチェック、自動置換の結果を、同じ操作をした参照 NSTextView と
  /// 比べる。既定のテストは Ediro の仕様を値で確かめるので、OS を更新したときにこの suite を手で回し、
  /// 標準のテキストビューの振る舞いが変わっていないかを見る。
  ///
  /// EDIRO_INVENTORY=1 swift test --filter InputReferenceTests
  /// 参照の振る舞いは OS の版やシステム設定で変わるので、既定の `swift test` では走らせない。
  @Suite(.enabled(if: ProcessInfo.processInfo.environment["EDIRO_INVENTORY"] == "1"))
  struct InputReferenceTests {
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
    /// アクターを明け渡す。
    private func type(_ text: String, into view: EditorView) async {
      for character in text {
        view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        try? await Task.sleep(for: .milliseconds(20))
      }
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    // MARK: - 補完とスマートな挿入・削除

    @Test func 補完の範囲と候補は参照と同じ() async throws {
      try await requireCompletionsAvailable()
      let reference = ReferenceTextView(text: "hel")
      defer { reference.close() }
      let view = EditorView(text: "hel")
      view.select([caret(3)], primary: 0)
      reference.textView.setSelectedRange(caret(3))
      var expectedIndex = 0
      var actualIndex = 0
      let range = reference.textView.rangeForUserCompletion
      #expect(view.rangeForUserCompletion == range)
      let expected = reference.textView.completions(
        forPartialWordRange: range, indexOfSelectedItem: &expectedIndex)
      #expect(expected?.isEmpty == false)
      #expect(view.completions(forPartialWordRange: range, indexOfSelectedItem: &actualIndex) == expected)
      #expect(actualIndex == expectedIndex)
      view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
      #expect(view.inputAssistance.completionCandidates == expected)
    }

    @Test(arguments: [true, false]) func スマートな削除は参照と同じ本文になる(enabled: Bool) {
      for byWord in [true, false] {
        for action in ["deleteBackward:", "deleteForward:", "delete:"] {
          let reference = ReferenceTextView(text: "hello world foo")
          defer { reference.close() }
          let view = EditorView(text: "hello world foo")
          view.smartInsertDeleteEnabled = enabled
          reference.textView.smartInsertDeleteEnabled = enabled
          if byWord {
            view.select([caret(8)], primary: 0)
            view.selectWord(nil)
          } else { view.select([NSRange(location: 6, length: 5)], primary: 0) }
          reference.textView.setSelectedRange(NSRange(location: 6, length: 5))
          reference.textView.selectionGranularity = byWord ? .selectByWord : .selectByCharacter
          reference.textView.doCommand(by: NSSelectorFromString(action))
          view.doCommand(by: NSSelectorFromString(action))
          #expect(view.text == reference.textView.string, "\(action) word=\(byWord)")
        }
      }
    }

    @Test(arguments: [true, false]) func スマートな貼り付けは参照と同じ本文になる(enabled: Bool) {
      for marked in [true, false] {
        let reference = ReferenceTextView(text: "hellofoo")
        defer { reference.close() }
        let view = EditorView(text: "hellofoo")
        view.smartInsertDeleteEnabled = enabled
        reference.textView.smartInsertDeleteEnabled = enabled
        view.select([caret(5)], primary: 0)
        reference.textView.setSelectedRange(caret(5))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("world", forType: .string)
        if marked { board.setString("", forType: EditorView.smartPasteType) }
        #expect(reference.textView.readSelection(from: board))
        view.paste(from: board)
        #expect(view.text == reference.textView.string, "marked=\(marked)")
      }
    }

    @Test func 重なる単語のスマートな削除は参照と同じ本文になる() {
      for action in ["deleteBackward:", "deleteForward:", "delete:", "cut:"] {
        let view = EditorView(text: "one two three")
        let reference = ReferenceTextView(text: "one two three")
        defer { reference.close() }
        view.select([caret(1), caret(5)], primary: 1)
        view.selectWord(nil)
        reference.textView.selectedRanges = view.session.selections.map {
          NSValue(range: view.nsRange(of: $0.range))
        }
        reference.textView.selectionGranularity = .selectByWord
        reference.textView.doCommand(by: NSSelectorFromString(action))
        view.doCommand(by: NSSelectorFromString(action))
        #expect(view.text == reference.textView.string, "\(action)")
      }
    }

    @Test func 予測と数式の補完の既定値は参照と同じ() {
      let reference = ReferenceTextView()
      defer { reference.close() }
      let view = EditorView(text: "")
      #expect(view.inlinePredictionType == reference.textView.inlinePredictionType)
      #expect(view.mathExpressionCompletionType == reference.textView.mathExpressionCompletionType)
    }

    // MARK: - 入切

    @Test func 入切の既定値と切り替えた後の値は参照と同じ() {
      let toggles:
        [(action: Selector, value: KeyPath<EditorView, Bool>, reference: KeyPath<NSTextView, Bool>)] = [
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
      let reference = ReferenceTextView()
      defer { reference.close() }
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      for toggle in toggles {
        let name = NSStringFromSelector(toggle.action)
        #expect(view[keyPath: toggle.value] == reference.textView[keyPath: toggle.reference], "\(name)")
        let item = NSMenuItem(title: "", action: toggle.action, keyEquivalent: "")
        for _ in 0..<2 {
          view.perform(toggle.action, with: item)
          reference.textView.perform(toggle.action, with: item)
          #expect(view[keyPath: toggle.value] == reference.textView[keyPath: toggle.reference], "\(name)")
        }
      }
    }

    // MARK: - スペルチェック

    @Test func スペルパネルの変更は参照と同じ本文と選択になる() {
      let text = "This is a mispeled word."
      let word = (text as NSString).range(of: "mispeled")
      let reference = ReferenceTextView(text: text)
      defer { reference.close() }
      reference.textView.setSelectedRange(word)
      reference.textView.changeSpelling(NSTextField(string: "misspelled"))

      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([word], primary: 0)
      view.changeSpelling(NSTextField(string: "misspelled"))
      #expect(view.text == reference.textView.string)
      #expect(view.selectedRange() == reference.textView.selectedRange())
      reference.textView.undoManager?.undo()
      view.undo(nil)
      #expect(view.text == reference.textView.string)
    }

    @Test func 文書の検査は参照と同じ誤りの単語を選ぶ() {
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
    }

    // MARK: - 自動置換

    @Test func 貼り付けた文字と後から打鍵した文字の自動置換は参照と同じ() async {
      let pasteboard = NSPasteboard.withUniqueName()
      defer { pasteboard.releaseGlobally() }
      pasteboard.setString("\"a--b\" ", forType: .string)
      let reference = ReferenceTextView()
      defer { reference.close() }
      reference.textView.isAutomaticQuoteSubstitutionEnabled = true
      reference.textView.isAutomaticDashSubstitutionEnabled = true
      reference.textView.readSelection(from: pasteboard, type: .string)
      await reference.type("x--y ")

      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      view.isAutomaticQuoteSubstitutionEnabled = true
      view.isAutomaticDashSubstitutionEnabled = true
      view.paste(from: pasteboard)
      await type("x--y ", into: view)
      _ = await waitUntil({ view.text == reference.textView.string }, timeout: .seconds(2))
      #expect(view.text == reference.textView.string)
    }

    @Test func 確定した変換の文字と後から打鍵した文字の自動置換は参照と同じ() async {
      let reference = ReferenceTextView()
      defer { reference.close() }
      reference.textView.isAutomaticQuoteSubstitutionEnabled = true
      reference.textView.isAutomaticDashSubstitutionEnabled = true
      await reference.type("a ")
      reference.textView.setMarkedText(
        "\"x", selectedRange: caret(2), replacementRange: NSRange(location: NSNotFound, length: 0))
      try? await Task.sleep(for: .milliseconds(300))
      let referenceMarked = reference.textView.string
      reference.textView.insertText("\"x\"", replacementRange: NSRange(location: NSNotFound, length: 0))
      await reference.type(" c--d ")

      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      view.isAutomaticQuoteSubstitutionEnabled = true
      view.isAutomaticDashSubstitutionEnabled = true
      await type("a ", into: view)
      view.setMarkedText(
        "\"x", selectedRange: caret(2), replacementRange: NSRange(location: NSNotFound, length: 0))
      try? await Task.sleep(for: .milliseconds(300))
      #expect(view.text == referenceMarked)
      view.insertText("\"x\"", replacementRange: NSRange(location: NSNotFound, length: 0))
      await type(" c--d ", into: view)
      _ = await waitUntil({ view.text == reference.textView.string }, timeout: .seconds(2))
      #expect(view.text == reference.textView.string)
    }

    @Test func 前からある文字と打鍵した文字にまたがる自動置換は参照と同じ() async {
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

    @Test func 自動置換を取り消した後に打鍵を続けた本文は参照と同じ() async {
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
  }
}
