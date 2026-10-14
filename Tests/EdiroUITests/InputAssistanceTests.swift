import AppKit
import Testing
@testable import EdiroUI

@Suite(.serialized)
struct InputAssistanceTests {
  @Test func completionCandidatesMatchReference() async throws {
    try await requireCompletionsAvailable()
    let reference = ReferenceTextView(text: "hel")
    defer { reference.close() }
    let view = EditorView(text: "hel")
    view.select([NSRange(location: 3, length: 0)], primary: 0)
    reference.textView.setSelectedRange(NSRange(location: 3, length: 0))
    var expectedIndex = 0
    var actualIndex = 0
    let range = reference.textView.rangeForUserCompletion
    #expect(view.rangeForUserCompletion == range)
    let expected = reference.textView.completions(forPartialWordRange: range, indexOfSelectedItem: &expectedIndex)
    #expect(expected?.isEmpty == false)
    #expect(view.completions(forPartialWordRange: range, indexOfSelectedItem: &actualIndex) == expected)
    #expect(actualIndex == expectedIndex)
    view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    #expect(view.inputAssistance.completionCandidates == expected)
    #expect(view.text == "hel")
  }

  @Test func cancelWithMultipleSelectionsKeepsOnlyThePrimary() {
    let view = EditorView(text: "hel")
    // 主を真ん中に置き、先頭や末尾の選択を残す誤りでも落ちるようにする。
    view.select(
      [0, 1, 3].map { NSRange(location: $0, length: 0) }, primary: 1)
    view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    #expect(view.session.selections.count == 1)
    #expect(view.selectedRange() == NSRange(location: 1, length: 0))
    // 選択を減らすだけで、補完は出さない。
    #expect(view.inputAssistance.completionCandidates.isEmpty)
  }

  @Test func completionKeyBindings() async throws {
    try await requireCompletionsAvailable()
    let view = EditorView(text: "hel")
    view.select([NSRange(location: 3, length: 0)], primary: 0)
    for (characters, keyCode, modifiers) in [("\u{1b}", UInt16(53), NSEvent.ModifierFlags()),
      ("\u{1b}", UInt16(53), NSEvent.ModifierFlags.option),
      (String(UnicodeScalar(NSF5FunctionKey)!), UInt16(96), NSEvent.ModifierFlags.function)] {
      view.inputAssistance.completionCandidates = []
      let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
      view.interpretKeyEvents([event])
      #expect(!view.inputAssistance.completionCandidates.isEmpty)
    }
  }

  @Test(arguments: [true, false]) func smartDeleteMatchesReference(enabled: Bool) {
    for byWord in [true, false] {
      for action in ["deleteBackward:", "deleteForward:", "delete:"] {
        let reference = ReferenceTextView(text: "hello world foo")
        defer { reference.close() }
        let view = EditorView(text: "hello world foo")
        view.smartInsertDeleteEnabled = enabled
        reference.textView.smartInsertDeleteEnabled = enabled
        if byWord {
          view.select([NSRange(location: 8, length: 0)], primary: 0)
          view.selectWord(nil)
        } else { view.select([NSRange(location: 6, length: 5)], primary: 0) }
        reference.textView.setSelectedRange(NSRange(location: 6, length: 5))
        reference.textView.selectionGranularity = byWord ? .selectByWord : .selectByCharacter
        reference.textView.doCommand(by: NSSelectorFromString(action))
        view.doCommand(by: NSSelectorFromString(action))
        #expect(view.text == reference.textView.string, "\(action) word=\(byWord)")
        view.undo(nil)
        #expect(view.text == "hello world foo")
      }
    }
  }

  @Test(arguments: [true, false]) func smartPasteMatchesReference(enabled: Bool) {
    for marked in [true, false] {
      let reference = ReferenceTextView(text: "hellofoo")
      defer { reference.close() }
      let view = EditorView(text: "hellofoo")
      view.smartInsertDeleteEnabled = enabled
      reference.textView.smartInsertDeleteEnabled = enabled
      view.select([NSRange(location: 5, length: 0)], primary: 0)
      reference.textView.setSelectedRange(NSRange(location: 5, length: 0))
      let board = NSPasteboard.withUniqueName()
      defer { board.releaseGlobally() }
      board.setString("world", forType: .string)
      if marked { board.setString("", forType: EditorView.smartPasteType) }
      #expect(reference.textView.readSelection(from: board))
      view.paste(from: board)
      #expect(view.text == reference.textView.string)
      view.undo(nil)
      #expect(view.text == "hellofoo")
    }
  }

  @Test func smartCopyAndSelectionReset() {
    let view = EditorView(text: "hello world foo")
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    view.select([NSRange(location: 8, length: 0)], primary: 0)
    view.selectWord(nil)
    view.writeSelection(to: board)
    #expect(board.types?.contains(EditorView.smartPasteType) == true)
    view.select([NSRange(location: 6, length: 5)], primary: 0)
    view.writeSelection(to: board)
    #expect(board.types?.contains(EditorView.smartPasteType) == false)
  }

  @Test func undoNamesMatchReferenceAndTravelWithHistory() {
    for action in ["insertText:", "deleteBackward:", "deleteForward:", "delete:", "cut:", "paste:"] {
      let reference = ReferenceTextView(text: "hello")
      defer { reference.close() }
      let view = EditorView(text: "hello")
      let range = NSRange(location: 0, length: 5)
      if action == "paste:" {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("world", forType: .string)
        NSPasteboard.general.setString("", forType: EditorView.smartPasteType)
      }
      reference.textView.setSelectedRange(range)
      view.select([range], primary: 0)
      if action == "insertText:" {
        reference.textView.insertText("hi", replacementRange: range)
        view.insertText("hi", replacementRange: range)
      } else {
        reference.textView.doCommand(by: NSSelectorFromString(action))
        view.doCommand(by: NSSelectorFromString(action))
      }
      let expected = reference.textView.undoManager?.undoActionName
      #expect(view.undoManager?.undoActionName == expected, "\(action)")
      #expect(view.undoManager?.canUndo == true)
      view.undoManager?.undo()
      #expect(view.undoManager?.redoActionName == expected)
      #expect(view.text == "hello")
      view.undoManager?.redo()
      #expect(view.undoManager?.undoActionName == expected)
    }
  }

  @Test func dictationAlternativesSurviveEditsAndCanBeReplaced() throws {
    let view = EditorView(text: "prefix ")
    view.select([NSRange(location: 7, length: 0)], primary: 0)
    let alternatives = NSTextAlternatives(primaryString: "there", alternativeStrings: ["their", "they're"])
    view.insertText(NSAttributedString(string: "there", attributes: [.textAlternatives: alternatives]),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.alternatives(at: 8)?.0 === alternatives)
    #expect(view.attributedSubstring(forProposedRange: NSRange(location: 7, length: 5), actualRange: nil)?
      .attribute(.textAlternatives, at: 0, effectiveRange: nil) as? NSTextAlternatives === alternatives)
    view.select([NSRange(location: 0, length: 0)], primary: 0)
    view.insertText("👩🏽‍💻 ", replacementRange: NSRange(location: NSNotFound, length: 0))
    let index = ("👩🏽‍💻 prefix " as NSString).length
    #expect(view.alternatives(at: index)?.0 === alternatives)
    let items = view.alternativeMenuItems(at: index)
    #expect(items.map(\.title) == ["their", "they're"])
    view.replaceAlternative(at: index, with: "they're")
    #expect(view.text == "👩🏽‍💻 prefix they're")
    view.undo(nil)
    #expect(view.text == "👩🏽‍💻 prefix there")
    view.replaceText("new")
    #expect(view.alternatives(at: 0) == nil)
  }

  @Test func inputAccessoryGeometryIsInScreenCoordinates() {
    let view = EditorView(text: "hello\nworld")
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    scroll.documentView = view
    view.setFrameSize(NSSize(width: 300, height: 200))
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    defer { window.close() }
    view.select([NSRange(location: 2, length: 0)], primary: 0)
    let caret = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
    #expect(view.unionRectInVisibleSelectedRange == caret)
    #expect(view.documentVisibleRect == window.convertToScreen(view.convert(view.visibleRect, to: nil)))
    #expect(view.preferredTextAccessoryPlacement() == .unspecified)
    #expect(view.windowLevel() == window.level.rawValue)
    #expect(view.baselineDeltaForCharacter(at: 2) > 0)
    view.select([NSRange(location: 0, length: 8)], primary: 0)
    #expect(view.unionRectInVisibleSelectedRange.height >= caret.height)
  }

  @Test func predictionTraitsMatchReferenceAndPropagate() {
    let reference = ReferenceTextView()
    defer { reference.close() }
    let view = EditorView(text: "")
    #expect(view.inlinePredictionType == reference.textView.inlinePredictionType)
    #expect(view.mathExpressionCompletionType == reference.textView.mathExpressionCompletionType)
    view.textChecker.inlinePredictionType = .no
    view.textChecker.mathExpressionCompletionType = .yes
    #expect(view.inlinePredictionType == .no)
    #expect(view.mathExpressionCompletionType == .yes)
    view.mathExpressionCompletionType = .no
    #expect(view.textChecker.mathExpressionCompletionType == .no)
  }

  @Test func linksAndDataDetectionApplyWhenEnabled() async {
    let state = makeState()
    let controller = EditorTextController(state: state)
    let view = controller.editorView
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = controller.scrollView
    window.makeFirstResponder(view)
    defer { window.close() }
    view.isAutomaticLinkDetectionEnabled = true
    view.isAutomaticDataDetectionEnabled = true
    for character in "https://example.com +1 (415) 555-1234 " {
      view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
      try? await Task.sleep(for: .milliseconds(20))
    }
    let link = await waitUntil({ view.textChecker.annotations.attribute(.link, at: 0, effectiveRange: nil) != nil }, timeout: .seconds(3))
    let dataKey = NSAttributedString.Key("NSDataDetection")
    let data = await waitUntil({ view.textChecker.annotations.attribute(dataKey, at: 25, effectiveRange: nil) != nil }, timeout: .seconds(3))
    #expect(link)
    #expect(data)
    var rendered = Set<NSAttributedString.Key>()
    view.layout.layoutManager.enumerateRenderingAttributes(from: view.layout.layoutManager.documentRange.location,
      reverse: false) { _, attributes, _ in
        rendered.formUnion(attributes.keys)
        return true
      }
    #expect(rendered.contains(.link))
    #expect(rendered.contains(dataKey))
    view.isAutomaticLinkDetectionEnabled = false
    view.isAutomaticDataDetectionEnabled = false
    view.replaceText("")
    for character in "https://example.com +1 (415) 555-1234 " {
      view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
      try? await Task.sleep(for: .milliseconds(20))
    }
    try? await Task.sleep(for: .milliseconds(200))
    #expect(view.textChecker.annotations.attribute(.link, at: 0, effectiveRange: nil) == nil)
    #expect(view.textChecker.annotations.attribute(dataKey, at: 25, effectiveRange: nil) == nil)
    #expect(view.text == "https://example.com +1 (415) 555-1234 ")
  }
}

private final class CandidateService: InputAssistanceService {
  var accept: (@MainActor (String?) -> Void)?
  var requests: [(selection: NSRange, text: String, predicts: Bool, reply: @MainActor ([NSTextCheckingResult]) -> Void)] = []
  var predictions = 0
  var shownCandidates: [NSTextCheckingResult] = []
  weak var shownClient: EditorView?
  func showCompletions(_ candidates: [String], in rect: NSRect, view: EditorView,
    accepted: @escaping @MainActor (String?) -> Void) { accept = accepted }
  func requestCandidates(selection: NSRange, text: String, predicts: Bool, tag: Int,
    completion: @escaping @MainActor ([NSTextCheckingResult]) -> Void) {
    requests.append((selection, text, predicts, completion))
  }
  func showPredictions(_ candidates: [NSTextCheckingResult], client: EditorView) {
    predictions += 1
    shownCandidates = candidates
    shownClient = client
  }
}

extension InputAssistanceTests {
  private func mounted(_ view: EditorView) -> NSWindow {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
    scroll.documentView = view
    view.setFrameSize(NSSize(width: 300, height: 150))
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    window.makeFirstResponder(view)
    return window
  }

  @Test func completionAcceptanceAndStaleResults() async throws {
    try await requireCompletionsAvailable()
    for change in ["accept", "cancel", "edit", "selection", "composition"] {
      let view = EditorView(text: "hel world")
      let window = mounted(view)
      defer { window.close() }
      let service = CandidateService()
      view.inputAssistance.service = service
      view.select([NSRange(location: 3, length: 0)], primary: 0)
      view.complete(nil)
      let accept = try #require(service.accept)
      switch change {
      case "edit": view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
      case "selection":
        view.select([NSRange(location: 0, length: 0)], primary: 0)
        view.select([NSRange(location: 3, length: 0)], primary: 0)
      case "composition": view.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
      default: break
      }
      let before = view.text
      accept(change == "cancel" ? nil : "hello")
      if change == "accept" {
        #expect(view.text == "hello world")
        view.undo(nil)
        #expect(view.text == "hel world")
      } else { #expect(view.text == before) }
    }
  }

  @Test func predictionRequestsAndStaleReplies() throws {
    let view = EditorView(text: "")
    let window = mounted(view)
    defer { window.close() }
    let service = CandidateService()
    view.inputAssistance.service = service
    view.inlinePredictionType = .yes
    view.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(service.requests.count == 1)
    #expect(service.requests[0].text == "hello")
    #expect(service.requests[0].selection == NSRange(location: 5, length: 0))
    #expect(service.requests[0].predicts)
    let candidate = NSTextCheckingResult.replacementCheckingResult(range: NSRange(location: 0, length: 5), replacementString: "hello world")
    service.requests[0].reply([candidate])
    #expect(service.predictions == 1)
    #expect(service.shownCandidates.count == 1)
    #expect(service.shownCandidates.first?.range == candidate.range)
    #expect(service.shownCandidates.first?.replacementString == "hello world")
    #expect(service.shownClient === view)
    view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
    service.requests[0].reply([])
    #expect(service.predictions == 1)
    let reply = try #require(service.requests.last?.reply)
    view.select([NSRange(location: 0, length: 0)], primary: 0)
    view.select([NSRange(location: 6, length: 0)], primary: 0)
    reply([])
    #expect(service.predictions == 1)
    view.inlinePredictionType = .no
    view.mathExpressionCompletionType = .no
    view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(service.requests.count == 2)
    view.mathExpressionCompletionType = .yes
    view.insertText("1+1=", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(service.requests.count == 3)
    #expect(service.requests.last?.predicts == false)
    view.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    view.requestInlineCandidates()
    #expect(service.requests.count == 3)
    view.unmarkText()
    #expect(service.requests.count == 4)
    view.select([NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)], primary: 0)
    view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(service.requests.count == 4)
  }

  @Test func compositionNamesAndAlternatives() {
    for method in ["insert", "unmark", "pointer"] {
      let view = EditorView(text: "")
      view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
      let alternatives = NSTextAlternatives(primaryString: "日本", alternativeStrings: ["二本"])
      switch method {
      case "insert": view.insertText(NSAttributedString(string: "日本", attributes: [.textAlternatives: alternatives]), replacementRange: NSRange(location: NSNotFound, length: 0))
      case "unmark": view.unmarkText()
      default: view.commitCompositionForPointer()
      }
      #expect(view.undoManager?.undoActionName == view.standardUndoName(for: .typing))
      if method == "insert" { #expect(view.alternatives(at: 0)?.0 === alternatives) }
      view.undo(nil)
      #expect(view.text.isEmpty)
    }
  }

  @Test func alternativesInvalidatePartialEditsAndReplaceOnlyTheirRange() {
    let view = EditorView(text: "abcdef ")
    view.select([NSRange(location: 7, length: 0)], primary: 0)
    let attributed = NSAttributedString(string: "there", attributes: [.textAlternatives:
      NSTextAlternatives(primaryString: "there", alternativeStrings: ["their"])])
    view.insertText(attributed, replacementRange: NSRange(location: NSNotFound, length: 0))
    view.select([NSRange(location: 2, length: 0), NSRange(location: 9, length: 0)], primary: 1)
    view.replaceAlternative(at: 7, with: "their")
    #expect(view.text == "abcdef their")
    view.undo(nil)
    #expect(view.text == "abcdef there")
    view.select([NSRange(location: 7, length: 5)], primary: 0)
    view.insertText(attributed, replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.alternatives(at: 7) != nil)
    view.select([NSRange(location: 9, length: 0)], primary: 0)
    view.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(view.alternatives(at: 7) == nil)
    #expect(view.alternatives(at: 10) == nil)
    view.replaceAlternative(at: 7, with: "their")
    #expect(view.text == "abcdef thXere")
  }

  @Test func glyphFractionsBaselineAndScrolledSelection() {
    let view = EditorView(text: "MMMM\n" + String(repeating: "line\n", count: 80))
    let window = mounted(view)
    defer { window.close() }
    let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
    for fraction in [0.25, 0.75] {
      let actual = view.fractionOfDistanceThroughGlyph(for: NSPoint(x: rect.minX + fraction * rect.width, y: rect.midY))
      #expect(abs(actual - fraction) < 0.01)
    }
    let baseline = view.layout.baselineOrigin(at: 0)
    let screen = window.convertPoint(toScreen: view.convert(NSPoint(x: baseline.x + view.textOrigin.x, y: baseline.y + view.textOrigin.y), to: nil))
    #expect(abs(view.baselineDeltaForCharacter(at: 0) - (screen.y - rect.minY)) < 0.01)
    view.select([NSRange(location: 0, length: 100)], primary: 0)
    view.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 150))
    let rects = view.layout.selectionRects(view.selectedRange()).map { $0.offsetBy(dx: view.textOrigin.x, dy: view.textOrigin.y) }
      .filter { $0.intersects(view.visibleRect) }
    if let first = rects.first {
      let expected = window.convertToScreen(view.convert(rects.dropFirst().reduce(first) { $0.union($1) }, to: nil))
      #expect(view.unionRectInVisibleSelectedRange == expected)
    } else { Issue.record("Expected a partially visible selection") }
    view.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 800))
    #expect(view.unionRectInVisibleSelectedRange == .zero)
  }
}

extension InputAssistanceTests {
  @Test func overlappingSmartDeletionsRemoveAllSelectedWords() {
    for action in ["deleteBackward:", "deleteForward:", "delete:", "cut:"] {
      let view = EditorView(text: "one two three")
      let reference = ReferenceTextView(text: "one two three")
      defer { reference.close() }
      view.select([NSRange(location: 1, length: 0), NSRange(location: 5, length: 0)], primary: 1)
      view.selectWord(nil)
      let before = view.session.selections
      reference.textView.selectedRanges = view.session.selections.map { NSValue(range: view.nsRange(of: $0.range)) }
      reference.textView.selectionGranularity = .selectByWord
      reference.textView.doCommand(by: NSSelectorFromString(action))
      view.doCommand(by: NSSelectorFromString(action))
      #expect(view.text == reference.textView.string)
      view.undo(nil)
      #expect(view.text == "one two three")
      #expect(view.session.selections == before)
    }
  }

  @Test func wordDragRetainsSmartCopyAndDeleteAcrossSelectionUpdates() throws {
    let view = EditorView(text: "one two three")
    let window = mounted(view)
    defer { window.close() }
    let rect = view.firstRectInView(for: NSRange(location: 0, length: 1))
    let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 0, clickCount: 2, pressure: 1))
    view.mouseDown(with: event)
    // タイマーの自動スクロールも、mouseDragged を経由せずここから選択を伸ばす。
    view.extendDrag(to: 5)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    view.writeSelection(to: board)
    #expect(board.types?.contains(EditorView.smartPasteType) == true)
    view.deleteBackward(nil)
    #expect(view.text == "three")
  }

  @Test func smartDeletionAlsoEditsUnselectedCarets() {
    let view = EditorView(text: "abc one two")
    view.select([NSRange(location: 2, length: 0), NSRange(location: 4, length: 3)], primary: 1)
    view.inputAssistance.wordSelection = true
    view.deleteBackward(nil)
    #expect(view.text == "ac two")
    view.undo(nil)
    #expect(view.text == "abc one two")
  }
}
