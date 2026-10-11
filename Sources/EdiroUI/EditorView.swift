import AppKit
import EdiroCore
import EditorEngine

/// 本文を表示して入力を受け取るビュー。
///
/// 本文・選択・取り消し履歴・変換中の文字はエンジンの EditorSession が持つ。
/// このビューはキー入力と IME をエンジンの操作に変換し、エンジンが通知した差分を
/// TextKit 2 の写しに当てて描くだけで、本文を自分では書き換えない。
final class EditorView: NSView, NSTextInputClient, NSUserInterfaceValidations {
  let layout = EditorLayout()
  private(set) var document: Document
  private(set) var session: EditorSession
  private var observation: Subscription?

  /// 本文か変換の状態が変わった直後、描画の前に呼ばれる。装飾の付け直しと状態への
  /// 反映に使う。
  var didChangeText: (() -> Void)?

  let inset = NSSize(width: 8, height: 8)
  var backgroundColor: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }
  var insertionPointColor: NSColor = .textColor { didSet { updateCarets() } }

  private var carets: [NSTextInsertionIndicator] = []
  /// ドラッグ中の選択の起点。単語や段落単位で選んでいるときはその範囲。
  private var dragAnchor: NSRange?
  private var dragGranularity: NSTextSelection.Granularity = .character
  /// Option を押しながらのドラッグでは、それまでの選択を残したまま一つ足す。
  private var dragKept: [Selection] = []

  init(text: String) {
    document = Document(id: "draft", text: text)
    session = try! EditorSession(document: document)
    super.init(frame: .zero)
    layout.replaceAll(with: document.snapshot.text)
    attach()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// 本文を外から差し替える。取り消し履歴も選択も作り直す。
  func replaceText(_ text: String) {
    if session.markedRange != nil {
      try? session.cancelComposition()
      inputContext?.discardMarkedText()
    }
    observation?.cancel()
    try? document.dispose()
    document = Document(id: "draft", text: text)
    session = try! EditorSession(document: document)
    layout.replaceAll(with: document.snapshot.text)
    attach()
    textDidChange()
  }

  private func attach() {
    try? session.setLayout(layout)
    observation = try? document.observe { [weak self] event in self?.handle(event) }
  }

  private func handle(_ event: DocumentEvent) {
    for batch in event.batches { layout.apply(batch) }
    // 変換を確定しただけの通知は本文を変えないが、未確定だった文字が下書きに加わる。
    if event.changes.contains(.text) || event.changes.contains(.composition) { textDidChange() }
    if event.changes.contains(.text) || event.changes.contains(.selection) {
      needsDisplay = true
      updateCarets()
      scrollToPrimary()
    }
  }

  private func textDidChange() {
    didChangeText?()
    refreshLayout()
  }

  /// 本文か装飾が変わった後に、組み直して描き直す。
  func refreshLayout() {
    layout.ensureLayout()
    setFrameSize(frame.size)
    needsDisplay = true
    updateCarets()
  }

  var text: String { document.snapshot.text }

  // MARK: - 位置の変換

  var textOrigin: CGPoint { CGPoint(x: inset.width, y: inset.height) }

  func offset(of position: Position) -> Int {
    (try? document.snapshot.offset(at: position)) ?? 0
  }

  func position(of offset: Int) -> Position {
    (try? document.snapshot.position(at: offset)) ?? document.snapshot.fullRange.end
  }

  func nsRange(of range: TextRange) -> NSRange {
    let start = offset(of: range.start)
    return NSRange(location: start, length: offset(of: range.end) - start)
  }

  private func textRange(of range: NSRange) -> TextRange {
    TextRange(position(of: range.location), position(of: NSMaxRange(range)))
  }

  private func containerPoint(_ event: NSEvent) -> CGPoint {
    let point = convert(event.locationInWindow, from: nil)
    return CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y)
  }

  // MARK: - 寸法と描画

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  /// 幅は外から与えられ、高さは本文から決まる。表示領域より短い本文でも、余白の
  /// クリックを受けられるよう表示領域いっぱいまで伸ばす。
  override func setFrameSize(_ newSize: NSSize) {
    layout.setWidth(max(newSize.width - inset.width * 2, 0))
    let visible = enclosingScrollView?.contentSize.height ?? 0
    let height = max(layout.usedHeight + inset.height * 2, visible)
    super.setFrameSize(NSSize(width: newSize.width, height: height))
    updateCarets()
  }

  override func resetCursorRects() {
    addCursorRect(visibleRect, cursor: .iBeam)
  }

  private var isActive: Bool {
    window?.firstResponder === self && window?.isKeyWindow == true
  }

  override func draw(_ dirtyRect: NSRect) {
    backgroundColor.setFill()
    dirtyRect.fill()
    let origin = textOrigin

    (isActive ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor)
      .setFill()
    // 変換中の選択はいま変換している文節を指す。背景ではなく太い下線で示す。
    for selection in session.selections where !selection.isEmpty && session.markedRange == nil {
      for rect in layout.selectionRects(nsRange(of: selection.range)) {
        rect.offsetBy(dx: origin.x, dy: origin.y).fill()
      }
    }

    guard let context = NSGraphicsContext.current?.cgContext else { return }
    layout.layoutManager.enumerateTextLayoutFragments(
      from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]
    ) { fragment in
      let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
      let surface = fragment.renderingSurfaceBounds.offsetBy(dx: frame.minX, dy: frame.minY)
      if surface.minY > dirtyRect.maxY { return false }
      if surface.intersects(dirtyRect) { fragment.draw(at: frame.origin, in: context) }
      return true
    }

    drawMarkedText(origin: origin)
  }

  /// 変換中の文字に下線を引く。いま変換している文節は太くする。
  private func drawMarkedText(origin: CGPoint) {
    guard session.markedRange != nil else { return }
    insertionPointColor.setFill()
    for (index, marked) in session.markedRanges.enumerated() {
      let range = nsRange(of: marked)
      let clause = nsRange(of: session.selections[index].range)
      for rect in layout.selectionRects(range) {
        NSRect(x: rect.minX + origin.x, y: rect.maxY + origin.y - 1, width: rect.width, height: 1)
          .fill()
      }
      for rect in layout.selectionRects(clause) {
        NSRect(x: rect.minX + origin.x, y: rect.maxY + origin.y - 2, width: rect.width, height: 2)
          .fill()
      }
    }
  }

  /// 空の選択ごとにキャレットを置く。点滅はシステムの表示に任せる。
  func updateCarets() {
    let points =
      session.selections.filter(\.isEmpty).map { selection -> CGRect in
        let rect = layout.caretRect(at: offset(of: selection.head))
        return CGRect(
          x: rect.minX + textOrigin.x - 1, y: rect.minY + textOrigin.y, width: 2,
          height: rect.height)
      }
    while carets.count < points.count {
      let caret = NSTextInsertionIndicator(frame: .zero)
      addSubview(caret)
      carets.append(caret)
    }
    while carets.count > points.count { carets.removeLast().removeFromSuperview() }
    for (caret, rect) in zip(carets, points) {
      caret.frame = rect
      caret.color = insertionPointColor
      caret.displayMode = isActive ? .automatic : .hidden
    }
  }

  private func scrollToPrimary() {
    let caret = layout.caretRect(at: offset(of: session.primarySelection.head))
    scrollToVisible(
      caret.offsetBy(dx: textOrigin.x, dy: textOrigin.y).insetBy(dx: -inset.width, dy: -inset.height))
  }

  override func becomeFirstResponder() -> Bool {
    needsDisplay = true
    updateCarets()
    return true
  }

  override func resignFirstResponder() -> Bool {
    needsDisplay = true
    // 第一応答者が入れ替わるのはこの呼び出しから戻った後なので、キャレットを消すのも後にする。
    DispatchQueue.main.async { [weak self] in self?.updateCarets() }
    return true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    guard let window else { return }
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(keyStateDidChange), name: name, object: window)
    }
  }

  @objc private func keyStateDidChange() {
    needsDisplay = true
    updateCarets()
  }

  // MARK: - エンジンへの操作

  /// エンジンが断った操作は警告音で知らせる。変換中の移動などは、ここで断られる。
  private func perform(_ operation: () throws -> Void) {
    do { try operation() } catch { NSSound.beep() }
  }

  /// 範囲を選択に変える。本文の外や文字の途中を指す範囲は受け付けない。
  private func selection(_ range: NSRange) throws -> Selection {
    let snapshot = document.snapshot
    return Selection(
      anchor: try snapshot.position(at: range.location),
      head: try snapshot.position(at: NSMaxRange(range)))
  }

  /// 選択を置き換え、`primary` 番目を主にする。
  func select(_ ranges: [NSRange], primary: Int) {
    perform { try session.setSelections(ranges.map(selection), primary: primary) }
  }

  /// 単語の境界への移動。範囲を選んだまま広げずに動かすと、進む向きの端から動く。
  private func move(
    _ direction: NSTextSelectionNavigation.Direction,
    to destination: NSTextSelectionNavigation.Destination, extending: Bool
  ) {
    let backward = direction == .left || direction == .backward
    perform {
      try session.move(extendingSelection: extending) { selection in
        let origin =
          extending || selection.isEmpty
          ? selection.head : backward ? selection.range.start : selection.range.end
        let from = offset(of: origin)
        return position(
          of: layout.destination(from: from, direction: direction, destination: destination)
            ?? from)
      }
    }
  }

  /// 行か段落の端。TextKit の移動は端にいると隣の行へ進むので、自分の行の範囲から求める。
  private func boundary(of offset: Int, paragraph: Bool, end: Bool) -> Int {
    let range =
      paragraph ? layout.paragraphRange(containing: offset) : layout.lineRange(containing: offset)
    return end ? NSMaxRange(range) : range.location
  }

  private func moveToBoundary(paragraph: Bool, end: Bool, extending: Bool) {
    perform {
      try session.move(extendingSelection: extending) { selection in
        let origin =
          extending || selection.isEmpty
          ? selection.head : end ? selection.range.end : selection.range.start
        return position(of: boundary(of: offset(of: origin), paragraph: paragraph, end: end))
      }
    }
  }

  private func delete(
    _ direction: NSTextSelectionNavigation.Direction,
    to destination: NSTextSelectionNavigation.Destination
  ) {
    perform {
      try session.delete(
        to: { position in
          let from = offset(of: position)
          return self.position(
            of: layout.destination(from: from, direction: direction, destination: destination)
              ?? from)
        }, historyGroup: "deleting")
    }
  }

  /// 行か段落の端まで消す。既に端にいるときは、隣の行と繋げる改行を消す。
  private func deleteToBoundary(paragraph: Bool, end: Bool) {
    perform {
      try session.delete(
        to: { position in
          let from = offset(of: position)
          var target = boundary(of: from, paragraph: paragraph, end: end)
          if target == from { target = end ? min(from + 1, layout.storage.length) : max(from - 1, 0) }
          return self.position(of: target)
        }, historyGroup: "deleting")
    }
  }

  func type(_ text: String) {
    perform { try session.type(text, historyGroup: "typing") }
  }

  /// 改行して、各キャレットの行頭の空白をそれぞれ引き継ぐ。
  func insertNewlineKeepingIndent() {
    let text = self.text
    let texts = session.selections.map { selection in
      "\n" + Indentation.leadingWhitespace(in: text, at: offset(of: selection.range.start))
    }
    perform { try session.type(texts, historyGroup: "typing") }
  }

  // MARK: - キー入力

  override func keyDown(with event: NSEvent) {
    if inputContext?.handleEvent(event) != true { interpretKeyEvents([event]) }
  }

  override func doCommand(by selector: Selector) {
    // 選択が一つなら Esc はウィンドウ側の閉じる操作などに回す。
    // 自分に送り直すと受け取って何もしないので、次の応答者へ直接渡す。
    if selector == #selector(cancelOperation(_:)), session.selections.count == 1 {
      _ = nextResponder?.tryToPerform(selector, with: nil)
    } else if responds(to: selector) {
      perform(selector, with: nil)
    } else {
      super.doCommand(by: selector)
    }
  }

  override func cancelOperation(_ sender: Any?) {
    guard session.selections.count > 1 else { return }
    let primary = session.primarySelection
    perform { try session.setSelections([primary]) }
  }

  override func moveLeft(_ sender: Any?) { perform { try session.move(.backward) } }
  override func moveRight(_ sender: Any?) { perform { try session.move(.forward) } }
  override func moveBackward(_ sender: Any?) { perform { try session.move(.backward) } }
  override func moveForward(_ sender: Any?) { perform { try session.move(.forward) } }
  override func moveUp(_ sender: Any?) { perform { try session.move(.up) } }
  override func moveDown(_ sender: Any?) { perform { try session.move(.down) } }
  override func moveLeftAndModifySelection(_ sender: Any?) {
    perform { try session.move(.backward, extendingSelection: true) }
  }
  override func moveRightAndModifySelection(_ sender: Any?) {
    perform { try session.move(.forward, extendingSelection: true) }
  }
  override func moveBackwardAndModifySelection(_ sender: Any?) {
    perform { try session.move(.backward, extendingSelection: true) }
  }
  override func moveForwardAndModifySelection(_ sender: Any?) {
    perform { try session.move(.forward, extendingSelection: true) }
  }
  override func moveUpAndModifySelection(_ sender: Any?) {
    perform { try session.move(.up, extendingSelection: true) }
  }
  override func moveDownAndModifySelection(_ sender: Any?) {
    perform { try session.move(.down, extendingSelection: true) }
  }

  override func moveWordLeft(_ sender: Any?) { move(.left, to: .word, extending: false) }
  override func moveWordRight(_ sender: Any?) { move(.right, to: .word, extending: false) }
  override func moveWordBackward(_ sender: Any?) { move(.backward, to: .word, extending: false) }
  override func moveWordForward(_ sender: Any?) { move(.forward, to: .word, extending: false) }
  override func moveWordLeftAndModifySelection(_ sender: Any?) {
    move(.left, to: .word, extending: true)
  }
  override func moveWordRightAndModifySelection(_ sender: Any?) {
    move(.right, to: .word, extending: true)
  }
  override func moveWordBackwardAndModifySelection(_ sender: Any?) {
    move(.backward, to: .word, extending: true)
  }
  override func moveWordForwardAndModifySelection(_ sender: Any?) {
    move(.forward, to: .word, extending: true)
  }

  override func moveToBeginningOfLine(_ sender: Any?) {
    moveToBoundary(paragraph: false, end: false, extending: false)
  }
  override func moveToEndOfLine(_ sender: Any?) {
    moveToBoundary(paragraph: false, end: true, extending: false)
  }
  override func moveToLeftEndOfLine(_ sender: Any?) {
    moveToBoundary(paragraph: false, end: false, extending: false)
  }
  override func moveToRightEndOfLine(_ sender: Any?) {
    moveToBoundary(paragraph: false, end: true, extending: false)
  }
  override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
    moveToBoundary(paragraph: false, end: false, extending: true)
  }
  override func moveToEndOfLineAndModifySelection(_ sender: Any?) {
    moveToBoundary(paragraph: false, end: true, extending: true)
  }
  override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
    moveToBoundary(paragraph: false, end: false, extending: true)
  }
  override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) {
    moveToBoundary(paragraph: false, end: true, extending: true)
  }

  override func moveToBeginningOfParagraph(_ sender: Any?) {
    moveToBoundary(paragraph: true, end: false, extending: false)
  }
  override func moveToEndOfParagraph(_ sender: Any?) {
    moveToBoundary(paragraph: true, end: true, extending: false)
  }
  override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) {
    moveToBoundary(paragraph: true, end: false, extending: true)
  }
  override func moveToEndOfParagraphAndModifySelection(_ sender: Any?) {
    moveToBoundary(paragraph: true, end: true, extending: true)
  }
  override func moveParagraphBackwardAndModifySelection(_ sender: Any?) {
    moveToBoundary(paragraph: true, end: false, extending: true)
  }
  override func moveParagraphForwardAndModifySelection(_ sender: Any?) {
    moveToBoundary(paragraph: true, end: true, extending: true)
  }

  override func moveToBeginningOfDocument(_ sender: Any?) {
    perform { try session.move(.documentStart) }
  }
  override func moveToEndOfDocument(_ sender: Any?) { perform { try session.move(.documentEnd) } }
  override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
    perform { try session.move(.documentStart, extendingSelection: true) }
  }
  override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
    perform { try session.move(.documentEnd, extendingSelection: true) }
  }

  override func pageUp(_ sender: Any?) { movePage(up: true, extending: false) }
  override func pageDown(_ sender: Any?) { movePage(up: false, extending: false) }
  override func pageUpAndModifySelection(_ sender: Any?) { movePage(up: true, extending: true) }
  override func pageDownAndModifySelection(_ sender: Any?) {
    movePage(up: false, extending: true)
  }

  /// 表示領域の高さだけキャレットを動かし、表示も同じだけ送る。
  private func movePage(up: Bool, extending: Bool) {
    let distance = (enclosingScrollView?.contentSize.height ?? bounds.height) * (up ? -1 : 1)
    perform {
      try session.move(extendingSelection: extending) { selection in
        let caret = layout.caretRect(at: offset(of: selection.head))
        return position(of: layout.offset(at: CGPoint(x: caret.minX, y: caret.midY + distance)))
      }
    }
  }

  override func scrollPageUp(_ sender: Any?) { scrollPage(by: -1) }
  override func scrollPageDown(_ sender: Any?) { scrollPage(by: 1) }
  override func scrollToBeginningOfDocument(_ sender: Any?) { scroll(.zero) }
  override func scrollToEndOfDocument(_ sender: Any?) {
    scroll(CGPoint(x: 0, y: bounds.height))
  }

  private func scrollPage(by pages: CGFloat) {
    let visible = visibleRect
    scroll(CGPoint(x: visible.minX, y: visible.minY + visible.height * pages))
  }

  override func deleteBackward(_ sender: Any?) {
    perform { try session.deleteBackward(historyGroup: "deleting") }
  }
  override func deleteForward(_ sender: Any?) {
    perform { try session.deleteForward(historyGroup: "deleting") }
  }
  override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
    deleteBackward(sender)
  }
  override func deleteWordBackward(_ sender: Any?) { delete(.backward, to: .word) }
  override func deleteWordForward(_ sender: Any?) { delete(.forward, to: .word) }
  override func deleteToBeginningOfLine(_ sender: Any?) {
    deleteToBoundary(paragraph: false, end: false)
  }
  override func deleteToEndOfLine(_ sender: Any?) {
    deleteToBoundary(paragraph: false, end: true)
  }
  override func deleteToBeginningOfParagraph(_ sender: Any?) {
    deleteToBoundary(paragraph: true, end: false)
  }
  override func deleteToEndOfParagraph(_ sender: Any?) {
    deleteToBoundary(paragraph: true, end: true)
  }

  override func insertNewline(_ sender: Any?) { insertNewlineKeepingIndent() }
  override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewlineKeepingIndent() }
  override func insertLineBreak(_ sender: Any?) { insertNewlineKeepingIndent() }
  override func insertParagraphSeparator(_ sender: Any?) { insertNewlineKeepingIndent() }
  override func insertTab(_ sender: Any?) { type("\t") }
  override func insertTabIgnoringFieldEditor(_ sender: Any?) { type("\t") }

  override func selectAll(_ sender: Any?) {
    select([NSRange(location: 0, length: layout.storage.length)], primary: 0)
  }

  // MARK: - 取り消しとクリップボード

  @objc func undo(_ sender: Any?) { perform { try document.undo() } }
  @objc func redo(_ sender: Any?) { perform { try document.redo() } }

  private var selectedTexts: [String] {
    let snapshot = document.snapshot
    return session.selections.filter { !$0.isEmpty }.compactMap {
      try? snapshot.text(in: $0.range)
    }
  }

  /// 書式を付けずに本文だけを載せる。チャットへ貼ったときに装飾が付いてこない。
  /// 複数の選択は改行で繋ぐ。
  @objc func copy(_ sender: Any?) {
    writeSelection(to: .general)
  }

  func writeSelection(to pasteboard: NSPasteboard) {
    let texts = selectedTexts
    guard !texts.isEmpty else { return }
    pasteboard.clearContents()
    pasteboard.setString(texts.joined(separator: "\n"), forType: .string)
  }

  @objc func cut(_ sender: Any?) {
    // 変換中は消せないので、クリップボードも書き換えない。
    guard !hasMarkedText(), !selectedTexts.isEmpty else { return NSSound.beep() }
    writeSelection(to: .general)
    perform { try session.type("") }
  }

  @objc func paste(_ sender: Any?) {
    paste(from: .general)
  }

  /// 行数とキャレットの数が揃っていれば、一行ずつ各キャレットに配る。
  func paste(from pasteboard: NSPasteboard) {
    guard let pasted = pasteboard.string(forType: .string) else { return }
    // Swift の文字列では CRLF が一文字なので、揃えてから行に分ける。
    let string = pasted.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let count = session.selections.count
    let lines = string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    perform {
      if count > 1, lines.count == count {
        try session.type(lines)
      } else {
        try session.type(string)
      }
    }
  }

  func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(undo(_:)): return document.canUndo
    case #selector(redo(_:)): return document.canRedo
    case #selector(copy(_:)): return !selectedTexts.isEmpty
    case #selector(cut(_:)): return !hasMarkedText() && !selectedTexts.isEmpty
    case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil
    default: return true
    }
  }

  // MARK: - 複数カーソル

  /// 主の選択と同じ文字列で、その後ろにある次の一致を選択に加える。主の選択が空なら、
  /// まずキャレットのある単語を選ぶ。
  @objc func addNextOccurrence(_ sender: Any?) {
    let primary = session.primarySelection
    var ranges = session.selections.map { nsRange(of: $0.range) }
    if primary.isEmpty {
      guard
        let word = layout.enclosingRange(
          of: offset(of: primary.head), granularity: .word), word.length > 0
      else { return NSSound.beep() }
      ranges[session.primaryIndex] = word
      return select(ranges, primary: session.primaryIndex)
    }
    let snapshot = document.snapshot
    guard let query = try? snapshot.text(in: primary.range),
      let matches = try? snapshot.search(query)
    else { return NSSound.beep() }
    let candidates = matches.map { nsRange(of: $0.range) }.filter { match in
      !ranges.contains { NSIntersectionRange($0, match).length > 0 || $0 == match }
    }
    let after = NSMaxRange(nsRange(of: primary.range))
    guard let next = candidates.first(where: { $0.location >= after }) ?? candidates.first else {
      return NSSound.beep()
    }
    select(ranges + [next], primary: ranges.count)
  }

  @objc func addCursorAbove(_ sender: Any?) { addCursor(up: true) }
  @objc func addCursorBelow(_ sender: Any?) { addCursor(up: false) }

  /// 一番上か下のキャレットから一行動いた位置にキャレットを足す。
  private func addCursor(up: Bool) {
    let heads = session.selections.map { offset(of: $0.head) }
    guard let origin = up ? heads.min() : heads.max() else { return }
    let x = layout.caretRect(at: origin).minX
    let target = layout.verticalOffset(from: origin, up: up, x: x)
    guard target != origin else { return NSSound.beep() }
    let ranges = session.selections.map { nsRange(of: $0.range) }
    select(ranges + [NSRange(location: target, length: 0)], primary: ranges.count)
  }

  // MARK: - マウス

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    // 先に確定してから IME に知らせる。逆だと IME の確定と二重になる。
    if session.markedRange != nil {
      perform { try session.commitComposition() }
      inputContext?.discardMarkedText()
    }
    let clicked = layout.offset(at: containerPoint(event))
    dragGranularity =
      switch event.clickCount {
      case 2: .word
      case 3...: .paragraph
      default: .character
      }
    let range = granularRange(at: clicked)
    let current = session.selections.map { nsRange(of: $0.range) }
    if event.modifierFlags.contains(.shift) {
      let anchor = offset(of: session.primarySelection.anchor)
      dragAnchor = NSRange(location: anchor, length: 0)
      dragKept = []
      extendDrag(to: clicked)
      return
    }
    dragAnchor = range
    dragKept = event.modifierFlags.contains(.option) ? session.selections : []
    if event.modifierFlags.contains(.option) {
      select(current + [range], primary: current.count)
    } else {
      select([range], primary: 0)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    autoscroll(with: event)
    extendDrag(to: layout.offset(at: containerPoint(event)))
  }

  override func mouseUp(with event: NSEvent) {
    dragAnchor = nil
    dragKept = []
  }

  private func granularRange(at offset: Int) -> NSRange {
    guard dragGranularity != .character,
      let range = layout.enclosingRange(of: offset, granularity: dragGranularity)
    else { return NSRange(location: offset, length: 0) }
    return range
  }

  /// ドラッグの起点から現在位置までを選ぶ。単語単位なら両端を単語の境界まで広げる。
  private func extendDrag(to offset: Int) {
    guard let anchor = dragAnchor else { return }
    let current = granularRange(at: offset)
    let start = min(anchor.location, current.location)
    let end = max(NSMaxRange(anchor), NSMaxRange(current))
    let backward = current.location < anchor.location
    let selection = Selection(
      anchor: position(of: backward ? end : start), head: position(of: backward ? start : end))
    perform { try session.setSelections(dragKept + [selection], primary: dragKept.count) }
  }

  // MARK: - NSTextInputClient

  private func string(from value: Any) -> String {
    (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
  }

  /// IME が指す置換範囲を、主の範囲からのはみ出しとして表す。全てのキャレットに同じだけ
  /// 当てるため。主の範囲を含まない置換範囲なら nil。
  private func widening(of replacement: NSRange, around range: NSRange) -> (before: Int, after: Int)? {
    guard replacement.location != NSNotFound else { return (0, 0) }
    let before = range.location - replacement.location
    let after = NSMaxRange(replacement) - NSMaxRange(range)
    guard before >= 0, after >= 0 else { return nil }
    return (before, after)
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = self.string(from: string)
    if session.markedRange != nil {
      perform { try session.commitComposition(text) }
      return
    }
    let primary = nsRange(of: session.primarySelection.range)
    perform {
      if let widening = widening(of: replacementRange, around: primary) {
        if widening != (0, 0) {
          // 本文の端や文字の途中にはみ出すキャレットは広げずに置く。
          let selections = session.selections.map { current in
            let range = nsRange(of: current.range)
            let widened = NSRange(
              location: range.location - widening.before,
              length: range.length + widening.before + widening.after)
            return (try? selection(widened)) ?? current
          }
          try session.setSelections(selections, primary: session.primaryIndex)
        }
      } else {
        try session.setSelections([try selection(replacementRange)])
      }
      try session.type(text, historyGroup: "typing")
    }
  }

  override func insertText(_ insertString: Any) {
    insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let text = self.string(from: string)
    perform {
      if session.markedRange == nil {
        if text.isEmpty { return }
        try session.beginComposition()
      }
      let base = nsRange(of: session.markedRange ?? session.primarySelection.range)
      let widening = widening(of: replacementRange, around: base) ?? (0, 0)
      let length = (text as NSString).length
      let start = min(max(selectedRange.location, 0), length)
      let end = min(start + max(selectedRange.length, 0), length)
      try session.updateComposition(
        text, markedSelection: start..<end, replacingBefore: widening.before,
        replacingAfter: widening.after)
      // 全て消した変換は終える。空の未確定文字を残すと IME と食い違う。
      if text.isEmpty { try session.commitComposition() }
    }
  }

  func unmarkText() {
    guard session.markedRange != nil else { return }
    perform { try session.commitComposition() }
  }

  func selectedRange() -> NSRange { nsRange(of: session.primarySelection.range) }

  func markedRange() -> NSRange {
    session.markedRange.map { nsRange(of: $0) } ?? NSRange(location: NSNotFound, length: 0)
  }

  func hasMarkedText() -> Bool { session.markedRange != nil }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    let full = NSRange(location: 0, length: layout.storage.length)
    let clamped = NSIntersectionRange(range, full)
    guard range.location != NSNotFound, range.location <= full.length else { return nil }
    actualRange?.pointee = clamped
    return layout.storage.attributedSubstring(from: clamped)
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    let length = layout.storage.length
    let location = min(max(range.location == NSNotFound ? 0 : range.location, 0), length)
    let clamped = NSRange(location: location, length: min(range.length, length - location))
    actualRange?.pointee = clamped
    let rect =
      layout.selectionRects(clamped).first ?? layout.caretRect(at: clamped.location)
    let local = rect.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
    guard let window else { return local }
    return window.convertToScreen(convert(local, to: nil))
  }

  func characterIndex(for point: NSPoint) -> Int {
    guard let window else { return NSNotFound }
    let local = convert(window.convertPoint(fromScreen: point), from: nil)
    return layout.offset(at: CGPoint(x: local.x - textOrigin.x, y: local.y - textOrigin.y))
  }

  // MARK: - アクセシビリティ

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
  override func accessibilityValue() -> Any? { text }
}
