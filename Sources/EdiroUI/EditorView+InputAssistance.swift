import AppKit
import EditorEngine

// NSTextCheckingResult は不変。AppKit が背景キューで返す候補をメインアクターへ渡す。
nonisolated private struct InputCandidates: @unchecked Sendable {
  let values: [NSTextCheckingResult]
}

protocol InputAssistanceService {
  func showCompletions(_ candidates: [String], in rect: NSRect, view: EditorView,
    accepted: @escaping @MainActor (String?) -> Void)
  func requestCandidates(selection: NSRange, text: String, predicts: Bool, tag: Int,
    completion: @escaping @MainActor ([NSTextCheckingResult]) -> Void)
  func showPredictions(_ candidates: [NSTextCheckingResult], client: EditorView)
}

struct SystemInputAssistanceService: InputAssistanceService {
  func showCompletions(_ candidates: [String], in rect: NSRect, view: EditorView,
    accepted: @escaping @MainActor (String?) -> Void) {
    guard let first = candidates.first else { return }
    NSSpellChecker.shared.showCorrectionIndicator(of: .guesses, primaryString: first,
      alternativeStrings: Array(candidates.dropFirst()), forStringIn: rect, view: view) { value in
      Task { @MainActor in accepted(value) }
    }
  }

  func requestCandidates(selection: NSRange, text: String, predicts: Bool, tag: Int,
    completion: @escaping @MainActor ([NSTextCheckingResult]) -> Void) {
    NSSpellChecker.shared.requestCandidates(forSelectedRange: selection, in: text,
      types: NSTextCheckingAllSystemTypes, options: [.generateInlinePredictionsKey: predicts],
      inSpellDocumentWithTag: tag) { @Sendable _, candidates in
        let result = InputCandidates(values: candidates)
        Task { @MainActor in completion(result.values) }
      }
  }

  func showPredictions(_ candidates: [NSTextCheckingResult], client: EditorView) {
    NSSpellChecker.shared.showInlinePrediction(forCandidates: candidates, client: client)
  }
}

final class InputAssistanceState {
  var service: any InputAssistanceService = SystemInputAssistanceService()
  var revision = 0
  var wordSelection = false
  var alternatives = NSMutableAttributedString()
  var completionCandidates: [String] = []
  var inlinePredictionType: NSTextInputTraitType = .default
  var mathExpressionCompletionType: NSTextInputTraitType = .default
  var textCompletionType: NSTextInputTraitType = .default

  func reset() {
    revision += 1
    alternatives = NSMutableAttributedString()
    completionCandidates = []
    wordSelection = false
  }

  func apply(_ batch: [ContentChange]) {
    for change in batch.reversed() {
      let range = NSRange(location: change.offset, length: change.removedLength)
      guard NSMaxRange(range) <= alternatives.length else { continue }
      var invalidated: [NSRange] = []
      alternatives.enumerateAttribute(.textAlternatives, in: NSRange(location: 0, length: alternatives.length)) { value, run, _ in
        guard value != nil else { return }
        if NSIntersectionRange(range, run).length > 0
          || (range.length == 0 && run.location < range.location && range.location < NSMaxRange(run)) {
          invalidated.append(run)
        }
      }
      for run in invalidated { alternatives.removeAttribute(.textAlternatives, range: run) }
      alternatives.replaceCharacters(in: range, with: NSAttributedString(string: change.insertedText))
    }
  }
}

/// AppKit のメニューにも、本文の正本が持つ履歴を見せる。
final class EditorUndoManager: UndoManager {
  weak var view: EditorView?
  init(view: EditorView) { self.view = view; super.init() }
  override var canUndo: Bool { view?.document.canUndo ?? false }
  override var canRedo: Bool { view?.document.canRedo ?? false }
  override var undoActionName: String { view?.document.undoActionName ?? "" }
  override var redoActionName: String { view?.document.redoActionName ?? "" }
  override var undoMenuItemTitle: String { undoMenuTitle(forUndoActionName: undoActionName) }
  override var redoMenuItemTitle: String { redoMenuTitle(forUndoActionName: redoActionName) }
  override func undo() { view?.undo(nil) }
  override func redo() { view?.redo(nil) }
}

extension EditorView: NSTextInputTraits {}

extension EditorView {
  static let smartPasteType = NSPasteboard.PasteboardType("NeXT smart paste pasteboard type")

  /// 空白の規則と辞書の候補は AppKit に任せる。本文への適用はエンジンだけが行う。
  func inputReference() -> NSTextView {
    let reference = NSTextView()
    reference.isRichText = false
    reference.string = text
    reference.smartInsertDeleteEnabled = smartInsertDeleteEnabled
    reference.setSelectedRange(selectedRange())
    return reference
  }

  @discardableResult
  func smartDeleteSelection(forward: Bool? = nil) -> Bool {
    guard smartInsertDeleteEnabled, inputAssistance.wordSelection,
      session.selections.contains(where: { !$0.isEmpty }) else { return false }
    let reference = inputReference()
    let string = layout.storage.mutableString
    let ranges = session.selections.compactMap { selection -> NSRange? in
      let range = nsRange(of: selection.range)
      if range.length > 0 { return reference.smartDeleteRange(forProposedRange: range) }
      guard let forward else { return nil }
      let caret = range.location
      if caret < string.length {
        let character = string.rangeOfComposedCharacterSequence(at: caret)
        if forward || character.location < caret { return character }
      }
      return !forward && caret > 0 ? string.rangeOfComposedCharacterSequence(at: caret - 1) : nil
    }.sorted { $0.location < $1.location }
    var merged: [NSRange] = []
    for range in ranges {
      if let last = merged.last, range.location <= NSMaxRange(last) {
        merged[merged.count - 1] = NSUnionRange(last, range)
      } else { merged.append(range) }
    }
    let replacements = merged.map { Replacement($0, "") }
    replace(replacements, selecting: selections(after: replacements))
    return true
  }

  enum UndoOperation: Hashable { case typing, cut, paste }
  private static var undoNames: [UndoOperation: String] = [:]

  func standardUndoName(for operation: UndoOperation) -> String {
    if let name = Self.undoNames[operation] { return name }
    let reference = NSTextView()
    let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = reference
    reference.allowsUndo = true
    reference.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    // AppKit のローカライズ済みの名前を取得する。クリップボードを変える操作はしない。
    let typing = reference.undoManager?.undoActionName ?? "Typing"
    let name: String
    switch operation {
    case .typing: name = typing
    case .cut: name = NSLocalizedString("Cut", tableName: nil, bundle: Bundle(for: NSTextView.self), comment: "")
    case .paste: name = NSLocalizedString("Paste", tableName: nil, bundle: Bundle(for: NSTextView.self), comment: "")
    }
    window.close()
    Self.undoNames[operation] = name
    return name
  }

  func withUndoName(_ name: String, _ body: () -> Void) {
    let version = textVersion
    body()
    if textVersion != version { document.setUndoActionName(name) }
  }

  @objc var rangeForUserCompletion: NSRange { inputReference().rangeForUserCompletion }

  @objc func completions(forPartialWordRange range: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
    guard range.location != NSNotFound, range.location <= layout.storage.length,
      range.length <= layout.storage.length - range.location else { return nil }
    var selected = 0
    let values = inputReference().completions(forPartialWordRange: range, indexOfSelectedItem: &selected)
    index?.pointee = selected
    return values
  }

  func showCompletions() {
    guard !hasMarkedText() else { return }
    let range = rangeForUserCompletion
    guard let candidates = completions(forPartialWordRange: range, indexOfSelectedItem: nil),
      !candidates.isEmpty else { inputAssistance.completionCandidates = []; return }
    inputAssistance.completionCandidates = candidates
    inputAssistance.revision += 1
    let revision = inputAssistance.revision
    guard window != nil else { return }
    inputAssistance.service.showCompletions(candidates, in: firstRectInView(for: range), view: self) { [weak self] accepted in
      guard let self, let accepted, self.inputAssistance.revision == revision,
        !self.hasMarkedText() else { return }
      self.insertText(accepted, replacementRange: range)
    }
  }

  var inlinePredictionType: NSTextInputTraitType {
    get { inputAssistance.inlinePredictionType }
    set { inputAssistance.inlinePredictionType = newValue; inputAssistance.revision += 1 }
  }
  var mathExpressionCompletionType: NSTextInputTraitType {
    get { inputAssistance.mathExpressionCompletionType }
    set { inputAssistance.mathExpressionCompletionType = newValue; inputAssistance.revision += 1 }
  }
  var textCompletionType: NSTextInputTraitType {
    get { inputAssistance.textCompletionType }
    set { inputAssistance.textCompletionType = newValue; inputAssistance.revision += 1 }
  }

  func requestInlineCandidates() {
    guard !hasMarkedText(), session.selections.count == 1, selectedRange().length == 0,
      inlinePredictionType != .no || mathExpressionCompletionType != .no else { return }
    let revision = inputAssistance.revision
    let selection = selectedRange()
    let predicts = inlinePredictionType == .yes
      || (inlinePredictionType == .default && NSSpellChecker.isAutomaticInlinePredictionEnabled)
    inputAssistance.service.requestCandidates(selection: selection, text: text, predicts: predicts,
      tag: textChecker.controller.spellCheckerDocumentTag) { [weak self] candidates in
        guard let self, self.inputAssistance.revision == revision,
          !self.hasMarkedText(), self.window?.firstResponder === self else { return }
        self.inputAssistance.service.showPredictions(candidates, client: self)
      }
  }

  func retainAlternatives(from value: Any, insertedText: String) {
    guard let attributed = value as? NSAttributedString,
      attributed.string == Self.normalizingLineEndings(insertedText) else { return }
    if inputAssistance.alternatives.string != text {
      inputAssistance.alternatives = NSMutableAttributedString(string: text)
    }
    let length = attributed.length
    for selection in session.selections {
      let start = offset(of: selection.head) - length
      guard start >= 0 else { continue }
      attributed.enumerateAttribute(.textAlternatives, in: NSRange(location: 0, length: length)) { value, range, _ in
        guard let alternatives = value as? NSTextAlternatives else { return }
        inputAssistance.alternatives.addAttribute(.textAlternatives, value: alternatives,
          range: NSRange(location: start + range.location, length: range.length))
      }
    }
  }

  func alternatives(at index: Int) -> (NSTextAlternatives, NSRange)? {
    guard index >= 0, index < inputAssistance.alternatives.length else { return nil }
    var range = NSRange()
    guard let alternatives = inputAssistance.alternatives.attribute(.textAlternatives, at: index,
      effectiveRange: &range) as? NSTextAlternatives else { return nil }
    return (alternatives, range)
  }

  func replaceAlternative(at index: Int, with string: String) {
    guard let (alternatives, range) = alternatives(at: index),
      alternatives.alternativeStrings.contains(string), !hasMarkedText() else { return }
    let replacement = Replacement(range, string)
    withUndoName(standardUndoName(for: .typing)) {
      if replace([replacement], selecting: selections(after: [replacement])) {
        alternatives.noteSelectedAlternativeString(string)
      }
    }
  }

  func alternativeMenuItems(at index: Int) -> [NSMenuItem] {
    guard let (alternatives, _) = alternatives(at: index) else { return [] }
    return alternatives.alternativeStrings.map { string in
      let item = NSMenuItem(title: string, action: #selector(chooseAlternative(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = ["index": index, "version": textVersion, "string": string]
      return item
    }
  }

  @objc private func chooseAlternative(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? [String: Any],
      let index = value["index"] as? Int, let version = value["version"] as? Int,
      let string = value["string"] as? String, version == textVersion else { return }
    replaceAlternative(at: index, with: string)
  }

  func attributedString() -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: layout.storage)
    let alternatives = inputAssistance.alternatives
    if alternatives.string == text {
      alternatives.enumerateAttribute(.textAlternatives, in: NSRange(location: 0, length: alternatives.length)) { value, range, _ in
        if let value { result.addAttribute(.textAlternatives, value: value, range: range) }
      }
    }
    return result
  }

  private func screenRect(_ rect: NSRect) -> NSRect {
    guard let window else { return rect }
    return window.convertToScreen(convert(rect, to: nil))
  }

  var documentVisibleRect: NSRect { screenRect(visibleRect) }
  var unionRectInVisibleSelectedRange: NSRect {
    let range = selectedRange()
    if range.length == 0 {
      var caret = layout.caretRect(at: range.location)
      caret.size.width = 0
      return screenRect(caret.offsetBy(dx: textOrigin.x, dy: textOrigin.y))
    }
    let rects = layout.selectionRects(range).map { $0.offsetBy(dx: textOrigin.x, dy: textOrigin.y) }
      .filter { $0.intersects(visibleRect) }
    guard let first = rects.first else { return .zero }
    return screenRect(rects.dropFirst().reduce(first) { $0.union($1) })
  }
  func preferredTextAccessoryPlacement() -> NSTextCursorAccessoryPlacement { .unspecified }
  func windowLevel() -> Int { window?.level.rawValue ?? NSWindow.Level.normal.rawValue }
  func baselineDeltaForCharacter(at index: Int) -> CGFloat {
    let offset = min(max(index, 0), layout.storage.length)
    let baseline = layout.baselineOrigin(at: offset)
    let local = NSPoint(x: baseline.x + textOrigin.x, y: baseline.y + textOrigin.y)
    let screen = window.map { $0.convertPoint(toScreen: convert(local, to: nil)) } ?? local
    return screen.y - firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil).minY
  }
  func fractionOfDistanceThroughGlyph(for point: NSPoint) -> CGFloat {
    guard let window else { return 0 }
    let local = convert(window.convertPoint(fromScreen: point), from: nil)
    let container = CGPoint(x: local.x - textOrigin.x, y: local.y - textOrigin.y)
    guard let index = layout.characterIndex(at: container), index < layout.storage.length else { return 0 }
    let range = layout.storage.mutableString.rangeOfComposedCharacterSequence(at: index)
    let rect = firstRect(forCharacterRange: range, actualRange: nil)
    guard rect.width != 0 else { return 0 }
    return min(max((point.x - rect.minX) / rect.width, 0), 1)
  }
}
