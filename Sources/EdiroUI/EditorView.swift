import AVFoundation
import AppKit
import EdiroCore
import EditorEngine
import EditorMarkdown

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
  /// 反映に使う。引数は、エンジンが Markdown のトークンを作り直した行。
  var didChangeText: ((_ retokenizedLines: IndexSet) -> Void)?

  let inset = NSSize(width: 8, height: 8)
  var backgroundColor: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }
  var insertionPointColor: NSColor = .textColor { didSet { updateCarets() } }

  private var carets: [NSTextInsertionIndicator] = []
  /// ドラッグ中の選択の起点。単語や段落単位で選んでいるときはその範囲。
  private var dragAnchor: NSRange?
  private var dragGranularity: NSTextSelection.Granularity = .character
  /// Option を押しながらのドラッグでは、それまでの選択を残したまま一つ足す。
  private var dragKept: [Selection] = []

  /// 行や段落の端まで消した文字 (kill buffer)。`yank:` で貼る。消した後のキャレットごとに一つ持つ。
  private var killBuffer: [String] = []
  /// 最後に kill buffer に入れた消去の、繋ぐ向き。次の消去も同じ向きなら、続けて消したものと
  /// して前に消した文字に繋ぐ。間に文字を消すだけのコマンド (`keepingKill` の中の編集) は
  /// 挟んでよいが、ほかの編集や取り消し、選択を置く操作を挟むと続かない。選択を置く操作は、
  /// 選択が変わらなくても続かなくする。NSTextView に近づけた規則で、選択を動かしてから文字を
  /// 消した後の kill など、NSTextView が続けて繋ぐ場合でも続かないことがある。
  private var lastKillAppending: Bool?
  private var keepsKill = false
  /// `setMark:` で印を付けた範囲。選択ごとに一つ持つ。NSTextView と同じく、本文を編集しても
  /// 位置を動かさない。
  private var marks: [NSRange] = []
  /// 折り返し位置を、次の行の先頭ではなく前の表示行の末尾として扱うキャレット。
  private var upstreamLineEnds: Set<Int> = []

  /// 本文が変わるたびに増える。訳文で置き換える前に、本文が変わっていないかを確かめる。
  private(set) var textVersion = 0
  /// 右クリックメニューに、ほかの機能が足す項目。
  var contextMenuAdditions: [ContextMenuAddition] = []
  /// 右クリックメニューの「共有」が使う。メニュー項目は宛先を弱く持つので、ここで持ち続ける。
  var sharingPicker: NSSharingServicePicker?
  /// 読み上げ中の音声。読み上げを始めるまで作らない。
  var speechSynthesizer: AVSpeechSynthesizer?
  /// 翻訳のポップオーバーに渡す内容と、それを本文の上に出す透明なビュー。
  var translation = TranslationRequest()
  var translationAnchor: NSView?
  /// スペルと文法の検査と自動置換。
  private(set) lazy var textChecker = TextChecker(view: self)
  /// 打鍵で文字を入れている間。打鍵で入った文字は、通知の後で自動置換と検査に回す。
  private var isTyping = false
  /// 打鍵で入った文字の範囲。打鍵の後で自動置換と検査に回す。
  private var typedRanges: [NSRange] = []
  /// Writing Tools に渡した本文の範囲と、その動作中の状態。
  var writingTools = WritingToolsState()
  /// ドラッグ＆ドロップと自動スクロールの状態。
  var dragAndDrop = DragAndDropState()
  let inputAssistance = InputAssistanceState()
  private lazy var engineUndoManager = EditorUndoManager(view: self)
  override var undoManager: UndoManager? { engineUndoManager }
  private var accessibilitySelections: [NSRange] = []
  var postAccessibilityNotification: (EditorView, NSAccessibility.Notification) -> Void = {
    NSAccessibility.post(element: $0, notification: $1)
  }

  init(text: String) {
    document = Self.makeDocument(text)
    session = try! EditorSession(document: document)
    super.init(frame: .zero)
    layout.replaceAll(with: document.snapshot.text)
    textChecker.reset(text: document.snapshot.text)
    inputAssistance.alternatives = NSMutableAttributedString(string: text)
    contextMenuAdditions = textCheckingMenuAdditions + [
      ContextMenuAddition(position: .top) { [weak self] request in
        guard let self else { return [] }
        return self.alternativeMenuItems(at: request.clickedIndex ?? self.selectedRange().location)
      }
    ]
    attach()
    setUpWritingTools()
    registerForDraggedTypes(Self.readableTypes)
  }

  /// 本文を持つ Document。Markdown の行トークンはエンジンが編集のたびに作り直す。
  private static func makeDocument(_ text: String) -> Document {
    Document(id: "draft", text: text, lineTokenizer: MarkdownTokenizer())
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// 本文を外から差し替える。取り消し履歴も選択も作り直す。
  func replaceText(_ text: String) {
    stopWritingToolsForReplacement()
    if session.markedRange != nil {
      try? session.cancelComposition()
      inputContext?.discardMarkedText()
    }
    observation?.cancel()
    lastKillAppending = nil
    marks = []
    upstreamLineEnds = []
    try? document.dispose()
    document = Self.makeDocument(text)
    session = try! EditorSession(document: document)
    layout.replaceAll(with: document.snapshot.text)
    textChecker.reset(text: document.snapshot.text)
    inputAssistance.reset()
    inputAssistance.alternatives = NSMutableAttributedString(string: text)
    textVersion += 1
    attach()
    textDidChange(IndexSet(integersIn: 0..<document.snapshot.lineCount))
    postAccessibilityNotification(self, .valueChanged)
    postAccessibilityNotification(self, .selectedTextChanged)
  }

  private func attach() {
    accessibilitySelections = session.selections.map { nsRange(of: $0.range) }
    try? session.setLayout(layout)
    observation = try? document.observe { [weak self] event in self?.handle(event) }
  }

  private func handle(_ event: DocumentEvent) {
    if [.edit, .undo, .redo, .composition, .selection].contains(event.kind) {
      upstreamLineEnds = []
    }
    if !keepsKill, [.edit, .undo, .redo, .composition, .selection].contains(event.kind) {
      lastKillAppending = nil
    }
    // 打鍵の分は打鍵の後で自動置換と検査に回す。変換中の文字は、確定するときに検査に回す。
    let checks = !isTyping && [.edit, .undo, .redo].contains(event.kind)
    for batch in event.batches {
      trackWritingToolsContexts(batch, undoRedo: [.undo, .redo].contains(event.kind))
      inputAssistance.apply(batch)
      layout.apply(batch)
      let changed = textChecker.apply(batch, typed: isTyping)
      if isTyping { typedRanges += changed }
      // 検査を待つ範囲は、後の差分に合わせて注釈と一緒にずれる。
      if checks { changed.forEach(textChecker.checkSpelling(in:)) }
    }
    if event.changes.contains(.text) { textVersion += 1 }
    // 変換を確定しただけの通知は本文を変えないが、未確定だった文字が下書きに加わる。
    if !event.changes.isDisjoint(with: [.text, .composition, .lineTokens]) {
      textDidChange(event.retokenizedLines)
    }
    if !event.changes.isDisjoint(with: [.text, .selection, .composition]) {
      inputAssistance.revision += 1
      inputContext?.invalidateCharacterCoordinates()
    }
    if event.changes.contains(.selection) {
      inputAssistance.wordSelection = false
      textChecker.controller.didChangeSelectedRange()
      inputContext?.textInputClientDidUpdateSelection()
    }
    if event.changes.contains(.text) || event.changes.contains(.selection) {
      needsDisplay = true
      updateCarets()
      if scrollsToSelection { scrollToPrimary() }
    }
    sendWritingToolsUpdates()
    let selections = session.selections.map { nsRange(of: $0.range) }
    // 行・列が同じでも、前の行の編集で AX の UTF-16 範囲は移動する。
    let selectionChanged = event.changes.contains(.selection) || selections != accessibilitySelections
    accessibilitySelections = selections
    if event.changes.contains(.text) { postAccessibilityNotification(self, .valueChanged) }
    if selectionChanged { postAccessibilityNotification(self, .selectedTextChanged) }
  }

  private var scrollsToSelection = true

  /// 選択を変えても、表示を主の選択まで送らない。
  func withoutScrolling(_ body: () -> Void) {
    let scrolls = scrollsToSelection
    scrollsToSelection = false
    defer { scrollsToSelection = scrolls }
    body()
  }

  private func textDidChange(_ retokenizedLines: IndexSet) {
    didChangeText?(retokenizedLines)
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

  func containerPoint(_ event: NSEvent) -> CGPoint {
    containerPoint(window: event.locationInWindow)
  }

  /// ウィンドウの座標の点を、本文の配置の座標にする。
  func containerPoint(window point: NSPoint) -> CGPoint {
    let point = convert(point, from: nil)
    return CGPoint(x: point.x - textOrigin.x, y: point.y - textOrigin.y)
  }

  // MARK: - 寸法と描画

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  /// 幅は外から与えられ、高さは本文から決まる。表示領域より短い本文でも、余白の
  /// クリックを受けられるよう表示領域いっぱいまで伸ばす。
  override func setFrameSize(_ newSize: NSSize) {
    let width = layout.container.size.width
    layout.setWidth(max(newSize.width - inset.width * 2, 0))
    let visible = enclosingScrollView?.contentSize.height ?? 0
    let height = max(layout.usedHeight + inset.height * 2, visible)
    super.setFrameSize(NSSize(width: newSize.width, height: height))
    if layout.container.size.width != width { writingToolsLayoutDidChange() }
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
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    func drawSelectionAndText() {
      (isActive ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor)
        .setFill()
      // 変換中の選択はいま変換している文節を指す。背景ではなく太い下線で示す。
      // Writing Tools が書き換えを流し込んでいる間は、選択を見せない (NSTextView と同じ)。
      let showsSelection =
        session.markedRange == nil && writingTools.state != .interactiveStreaming
      for selection in session.selections where !selection.isEmpty && showsSelection {
        for rect in layout.selectionRects(nsRange(of: selection.range)) {
          rect.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
      }
      drawText(in: context, dirtyRect: dirtyRect)
    }

    // Writing Tools がアニメーションで本文の画像を重ねている所は本文と選択を消し、待機中の
    // 所は薄くする。本文と選択を別の層に描いて、その層から消す。
    let (hidden, dimmed) = writingToolsHiddenRects(in: dirtyRect)
    if hidden.isEmpty && dimmed.isEmpty {
      drawSelectionAndText()
    } else {
      context.saveGState()
      context.beginTransparencyLayer(auxiliaryInfo: nil)
      drawSelectionAndText()
      context.setBlendMode(.destinationOut)
      context.setFillColor(gray: 0, alpha: 0.5)
      context.fill(dimmed)
      context.setBlendMode(.clear)
      context.fill(hidden)
      context.endTransparencyLayer()
      context.restoreGState()
    }

    drawMarkedText(origin: origin)
    drawDropCaret()
  }

  /// `dirtyRect` (ビューの座標) に掛かる本文を描く。
  func drawText(in context: CGContext, dirtyRect: NSRect) {
    let origin = textOrigin
    layout.layoutManager.enumerateTextLayoutFragments(
      from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]
    ) { fragment in
      let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
      let surface = fragment.renderingSurfaceBounds.offsetBy(dx: frame.minX, dy: frame.minY)
      if surface.minY > dirtyRect.maxY { return false }
      if surface.intersects(dirtyRect) { fragment.draw(at: frame.origin, in: context) }
      return true
    }
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

  /// `offset` の位置に描くキャレットの枠 (ビューの座標)。
  func caretFrame(at offset: Int) -> CGRect {
    let rect = layout.caretRect(at: min(offset, layout.storage.length))
    return CGRect(
      x: rect.minX + textOrigin.x - 1, y: rect.minY + textOrigin.y, width: 2, height: rect.height)
  }

  /// 空の選択ごとにキャレットを置く。点滅はシステムの表示に任せる。
  func updateCarets() {
    let points = session.selections.filter(\.isEmpty).map { caretFrame(at: offset(of: $0.head)) }
    while carets.count < points.count {
      let caret = NSTextInsertionIndicator(frame: .zero)
      addSubview(caret)
      carets.append(caret)
    }
    while carets.count > points.count { carets.removeLast().removeFromSuperview() }
    // Writing Tools が書き換えを流し込んでいる間と、アニメーションで本文を隠している所では、
    // キャレットを見せない。
    let hidden = writingToolsHiddenRects(in: bounds).hidden
    for (caret, rect) in zip(carets, points) {
      caret.frame = rect
      caret.color = insertionPointColor
      // 隠している文字に接しているだけのキャレットは隠さない。
      let center = CGPoint(x: rect.midX, y: rect.midY)
      let covered = hidden.contains { $0.insetBy(dx: 0.5, dy: 0).contains(center) }
      caret.displayMode =
        isActive && writingTools.state != .interactiveStreaming && !covered ? .automatic : .hidden
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
    if let scroll = enclosingScrollView {
      NotificationCenter.default.addObserver(self, selector: #selector(inputScrollStarted),
        name: NSScrollView.willStartLiveScrollNotification, object: scroll)
      NotificationCenter.default.addObserver(self, selector: #selector(inputScrollEnded),
        name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(keyStateDidChange), name: name, object: window)
    }
  }

  @objc private func inputScrollStarted() { inputContext?.textInputClientWillStartScrollingOrZooming() }
  @objc private func inputScrollEnded() { inputContext?.textInputClientDidEndScrollingOrZooming() }

  @objc private func keyStateDidChange() {
    needsDisplay = true
    updateCarets()
  }

  // MARK: - エンジンへの操作

  /// 続けて消している途中の kill を終わらせずに、文字を消すだけのコマンドを実行する。
  @discardableResult
  private func keepingKill<T>(_ body: () -> T) -> T {
    let kept = keepsKill
    keepsKill = true
    defer { keepsKill = kept }
    return body()
  }

  /// エンジンが断った操作は警告音で知らせる。変換中の移動などは、ここで断られる。
  @discardableResult
  func perform(_ operation: () throws -> Void) -> Bool {
    do {
      try operation()
      return true
    } catch {
      NSSound.beep()
      return false
    }
  }

  /// 範囲を選択に変える。本文の外や文字の途中を指す範囲は受け付けない。
  private func selection(_ range: NSRange) throws -> Selection {
    let snapshot = document.snapshot
    return Selection(
      anchor: try snapshot.position(at: range.location),
      head: try snapshot.position(at: NSMaxRange(range)))
  }

  /// 選択を置き換え、`primary` 番目を主にする。
  /// `beepsOnFailure` が false なら、断られても警告音を鳴らさない (利用者の操作でない選択)。
  func select(_ ranges: [NSRange], primary: Int, beepsOnFailure: Bool = true) {
    inputAssistance.wordSelection = false
    inputAssistance.revision += 1
    let change = { try self.session.setSelections(ranges.map(self.selection), primary: primary) }
    if beepsOnFailure { perform(change) } else { try? change() }
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
  private func boundary(of offset: Int, paragraph: Bool, end: Bool, upstream: Bool = false) -> Int {
    let range =
      paragraph ? layout.paragraphRange(containing: offset)
      : layout.lineRange(containing: offset, upstream: upstream)
    return end ? NSMaxRange(range) : range.location
  }

  private func moveToBoundary(paragraph: Bool, end: Bool, extending: Bool) {
    let moved = perform {
      try session.move(extendingSelection: extending) { selection in
        let origin =
          extending || selection.isEmpty
          ? selection.head : end ? selection.range.end : selection.range.start
        let from = offset(of: origin)
        return position(of: boundary(
          of: from, paragraph: paragraph, end: end, upstream: upstreamLineEnds.contains(from)))
      }
    }
    if moved, !paragraph, end {
      upstreamLineEnds = Set(session.selections.filter(\.isEmpty).map { offset(of: $0.head) })
    }
  }

  private func delete(
    _ direction: NSTextSelectionNavigation.Direction,
    to destination: NSTextSelectionNavigation.Destination
  ) {
    keepingKill {
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
  }

  /// 行か段落の端まで消し、消した文字を kill buffer に入れる。行末にいるときは、次の行と
  /// 繋げる改行を消す。行頭にいるときは何もしない (NSTextView と同じ)。
  ///
  /// 続けて消した文字は、段落の末尾まで消したときだけ後ろに繋ぎ、ほかは前に繋ぐ。行の末尾まで
  /// 消したときも前に繋ぐのは、参照 NSTextView がそうするため。
  private func deleteToBoundary(paragraph: Bool, end: Bool) {
    func target(_ from: Int) -> Int {
      let target = boundary(of: from, paragraph: paragraph, end: end)
      return end && target == from ? min(from + 1, layout.storage.length) : target
    }
    let ranges = session.selections.map { selection -> NSRange in
      guard selection.isEmpty else { return nsRange(of: selection.range) }
      let from = offset(of: selection.head)
      let to = target(from)
      return NSRange(location: min(from, to), length: abs(to - from))
    }
    kill(ranges, appending: paragraph && end)
  }

  func type(_ text: String) {
    withUndoName(standardUndoName(for: .typing)) {
      perform { try session.type(text, historyGroup: "typing") }
    }
  }

  /// 改行して、各キャレットの行頭の空白をそれぞれ引き継ぐ。
  func insertNewlineKeepingIndent() {
    let text = self.text
    let texts = session.selections.map { selection in
      "\n" + Indentation.leadingWhitespace(in: text, at: offset(of: selection.range.start))
    }
    typing {
      try session.type(texts, historyGroup: "typing")
    }
  }

  // MARK: - キー入力

  override func keyDown(with event: NSEvent) {
    if inputContext?.handleEvent(event) != true { interpretKeyEvents([event]) }
  }

  override func doCommand(by selector: Selector) {
    if responds(to: selector) {
      perform(selector, with: nil)
    } else {
      super.doCommand(by: selector)
    }
  }

  override func cancelOperation(_ sender: Any?) {
    guard session.selections.count > 1 else { return complete(sender) }
    let primary = session.primarySelection
    perform { try session.setSelections([primary]) }
  }

  override func complete(_ sender: Any?) { showCompletions() }

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
    withUndoName(standardUndoName(for: .typing)) {
      if !smartDeleteSelection(forward: false) {
        keepingKill { perform { try session.deleteBackward(historyGroup: "deleting") } }
      }
    }
  }
  override func deleteForward(_ sender: Any?) {
    withUndoName("") {
      if !smartDeleteSelection(forward: true) {
        keepingKill { perform { try session.deleteForward(historyGroup: "deleting") } }
      }
    }
  }
  /// 直前の文字を正準分解し、最後の符号点だけを消す。`é` は `e` に、`한` は `하` になる。
  /// 分解しても符号点が一つなら、文字ごと消す。結果は合成し直さない (NSTextView と同じ)。
  override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
    let string = layout.storage.mutableString
    keepingKill {
      replaceEach(historyGroup: "deleting") { _, range in
        guard range.length == 0 else { return (range, "") }
        // 合成文字の途中のキャレットは、その文字の前にあるものとして扱う。
        let caret = string.characterStart(at: range.location)
        guard caret > 0 else { return nil }
        let previous = string.rangeOfComposedCharacterSequence(at: caret - 1)
        let scalars = string.substring(with: previous).decomposedStringWithCanonicalMapping
          .unicodeScalars
        return (previous, String(String.UnicodeScalarView(scalars.dropLast())))
      }
    }
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
  override func insertTab(_ sender: Any?) { typeTab() }
  override func insertTabIgnoringFieldEditor(_ sender: Any?) { typeTab() }

  /// タブも打鍵で入った文字として、自動置換と検査に回す。
  private func typeTab() {
    typing { try session.type("\t", historyGroup: "typing") }
  }

  override func selectAll(_ sender: Any?) {
    select([NSRange(location: 0, length: layout.storage.length)], primary: 0)
  }

  // MARK: - 標準キーバインドの編集コマンド
  //
  // どれも選択ごとに適用する。単一の選択での結果は、参照 NSTextView と同じにする。

  struct Replacement {
    let range: NSRange
    let text: String
    let length: Int

    init(_ range: NSRange, _ text: String) {
      self.range = range
      self.text = text
      length = (text as NSString).length
    }
  }

  /// 重ならない置き換えを位置の順に当てた後の本文での、`offset` の位置。置き換えた範囲の
  /// 中の位置は、入れた文字の後ろに移る。
  func offset(_ offset: Int, after replacements: [Replacement]) -> Int {
    var delta = 0
    for replacement in replacements {
      if NSMaxRange(replacement.range) <= offset {
        delta += replacement.length - replacement.range.length
      } else if replacement.range.location < offset {
        return replacement.range.location + delta + replacement.length
      } else {
        break
      }
    }
    return offset + delta
  }

  /// 重ならない置き換えを位置の順に当てた後の、今の選択の位置。
  func selections(after replacements: [Replacement]) -> [(anchor: Int, head: Int)] {
    session.selections.map { selection in
      (
        offset(offset(of: selection.anchor), after: replacements),
        offset(offset(of: selection.head), after: replacements)
      )
    }
  }

  /// 重ならない置き換えを位置の順に当て、選択を `selecting` に置く。一回の取り消しで、本文と
  /// 選択を元に戻す。
  /// `beepsOnFailure` が false なら、断られても警告音を鳴らさない (利用者の操作でない置き換え)。
  @discardableResult
  func replace(
    _ replacements: [Replacement], selecting: [(anchor: Int, head: Int)],
    historyGroup: String? = nil, beepsOnFailure: Bool = true
  ) -> Bool {
    let edit = {
      try self.session.replace(
        replacements.map { TextEdit(self.textRange(of: $0.range), $0.text) },
        selecting: selecting, historyGroup: historyGroup)
    }
    guard beepsOnFailure else { return (try? edit()) != nil }
    return perform(edit)
  }

  /// 選択ごとに、`edit` が選択の番号と範囲から返す範囲を文字列で置き換える。nil を返した
  /// 選択と、前の範囲やほかの選択と重なる範囲は置き換えない。置き換えた選択は、入れた文字の
  /// 後ろのキャレットになる。
  func replaceEach(
    historyGroup: String? = nil, _ edit: (Int, NSRange) -> (range: NSRange, text: String)?
  ) {
    let edits = session.selections.indices.compactMap { index in
      edit(index, nsRange(of: session.selections[index].range)).map {
        (index: index, replacement: Replacement($0.range, $0.text))
      }
    }.sorted { $0.replacement.range.location < $1.replacement.range.location }
    let selected = session.selections.map { nsRange(of: $0.range) }
    var kept: [(index: Int, replacement: Replacement)] = []
    for edit in edits {
      let range = edit.replacement.range
      guard range.length > 0 || edit.replacement.length > 0 else { continue }
      if let last = kept.last?.replacement.range,
        range.location < NSMaxRange(last) || range.location == last.location
      {
        continue
      }
      // ほかの選択に掛かる置き換えは、その選択を広げたり消したりしないよう行わない。
      let overlaps = selected.indices.contains { other in
        let range2 = selected[other]
        return other != edit.index
          && (NSIntersectionRange(range, range2).length > 0
            || (range.location < range2.location && range2.location < NSMaxRange(range)))
      }
      if !overlaps { kept.append(edit) }
    }
    guard !kept.isEmpty else { return }
    let replacements = kept.map(\.replacement)
    let edited = Dictionary(uniqueKeysWithValues: kept.map { ($0.index, $0.replacement.range) })
    let selections = session.selections.indices.map { index -> (anchor: Int, head: Int) in
      if let range = edited[index] {
        let caret = offset(NSMaxRange(range), after: replacements)
        return (caret, caret)
      }
      let selection = session.selections[index]
      return (
        offset(offset(of: selection.anchor), after: replacements),
        offset(offset(of: selection.head), after: replacements)
      )
    }
    replace(replacements, selecting: selections, historyGroup: historyGroup)
  }

  /// キャレットの前後の文字を入れ替えて、キャレットを一つ進める。段落の末尾では、
  /// キャレットの前の二文字を入れ替えて動かない。範囲を選んでいるときは何もしない。
  override func transpose(_ sender: Any?) {
    let string = layout.storage.mutableString
    replaceEach { _, range in
      guard range.length == 0 else { return nil }
      let caret = string.characterStart(at: range.location)
      guard caret > 0 else { return nil }
      var first = string.rangeOfComposedCharacterSequence(at: caret - 1)
      var second: NSRange
      if caret < range.location {
        // 合成文字の途中のキャレットは、その文字の前にあるものとして扱う。
        second = string.rangeOfComposedCharacterSequence(at: caret)
      } else if caret == string.length || string.isLineBreak(at: caret) {
        // 段落の末尾では、キャレットの前の二文字を入れ替える。前の文字が複数の符号単位から
        // なるときは何もしない (NSTextView と同じ)。
        second = first
        guard second.length == 1, second.location > 0 else { return nil }
        first = string.rangeOfComposedCharacterSequence(at: second.location - 1)
      } else {
        second = string.rangeOfComposedCharacterSequence(at: caret)
      }
      return (
        NSRange(location: first.location, length: NSMaxRange(second) - first.location),
        string.substring(with: second) + string.substring(with: first)
      )
    }
  }

  /// 選択ごとに `ranges` の範囲を消して kill buffer に入れ、各キャレットを消した位置に置く。
  /// kill buffer には、消した後のキャレットごとに、そこで消えた文字を一つ入れる。消した後に
  /// 一つにまとまるキャレットの分は、本文の順に繋いだ一つになる。続けて同じ向きに繋ぐ消し方を
  /// したときは、前に消した文字の後ろ (`appending`) か前に繋ぐ。何も消さなければ false。
  @discardableResult
  private func kill(_ ranges: [NSRange], appending: Bool) -> Bool {
    // 重なる範囲や接する範囲は、一つの範囲として消す。
    var merged: [NSRange] = []
    for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
      if let last = merged.last, range.location <= NSMaxRange(last) {
        merged[merged.count - 1] = NSUnionRange(last, range)
      } else {
        merged.append(range)
      }
    }
    guard !merged.isEmpty else { return false }
    let replacements = merged.map { Replacement($0, "") }
    let carets = ranges.map { offset($0.location, after: replacements) }
    // 重なる部分は先に始まる範囲の分として、選択ごとに消える文字を求める。
    let string = layout.storage.mutableString
    let order = ranges.indices.sorted { (ranges[$0].location, $0) < (ranges[$1].location, $1) }
    var pieces = Array(repeating: "", count: ranges.count)
    var end = 0
    for index in order {
      let range = ranges[index]
      let start = max(range.location, end)
      end = max(end, NSMaxRange(range))
      if start < NSMaxRange(range) {
        pieces[index] = string.substring(
          with: NSRange(location: start, length: NSMaxRange(range) - start))
      }
    }
    let continuing = lastKillAppending == appending
    let previous = killBuffer
    if continuing, previous.count == ranges.count {
      pieces = zip(previous, pieces).map { appending ? $0 + $1 : $1 + $0 }
    }
    // NSTextView と同じく、消すごとに一回の取り消しで戻る。
    guard keepingKill({ replace(replacements, selecting: carets.map { ($0, $0) }) }) else {
      return false
    }
    killBuffer = Set(carets).sorted().map { caret in
      order.filter { carets[$0] == caret }.map { pieces[$0] }.joined()
    }
    // 間の消去でキャレットがまとまり、前に消した文字とキャレットの対応が分からないときは、
    // まとめて一つに繋ぐ。
    if continuing, previous.count != ranges.count {
      let earlier = previous.joined()
      let text = killBuffer.joined()
      killBuffer = [appending ? earlier + text : text + earlier]
    }
    lastKillAppending = appending
    return true
  }

  /// kill buffer の文字を選択の位置に入れる。消したときと選択の数が揃っていれば、一つずつ
  /// 各選択に配り、何も消さなかった分の選択はそのままにする。揃わなければ、改行で繋いで
  /// 各選択に入れる。
  override func yank(_ sender: Any?) {
    let killed = killBuffer.filter { !$0.isEmpty }
    guard !killed.isEmpty else { return NSSound.beep() }
    let texts =
      killBuffer.count == session.selections.count
      ? killBuffer
      : Array(repeating: killed.joined(separator: "\n"), count: session.selections.count)
    replaceEach { index, range in texts[index].isEmpty ? nil : (range, texts[index]) }
  }

  override func setMark(_ sender: Any?) {
    marks = session.selections.map { nsRange(of: $0.range) }
  }

  /// 選択と、同じ順番の印の組。本文が縮んで外にはみ出した印は本文の末尾に寄せ、文字の
  /// 途中を指す端はその文字の前に寄せる。印が無ければ nil。選択と印の数が違えば、警告音を
  /// 鳴らして nil を返す。
  private func markPairs() -> [(selection: NSRange, mark: NSRange)]? {
    guard !marks.isEmpty else { return nil }
    guard marks.count == session.selections.count else {
      NSSound.beep()
      return nil
    }
    let string = layout.storage.mutableString
    return zip(session.selections, marks).map { selection, mark in
      let start = string.characterStart(at: min(mark.location, string.length))
      let end = string.characterStart(at: min(NSMaxRange(mark), string.length))
      return (nsRange(of: selection.range), NSRange(location: start, length: max(end - start, 0)))
    }
  }

  /// 印と選択を合わせた範囲を選ぶ。
  override func selectToMark(_ sender: Any?) {
    guard let pairs = markPairs() else { return }
    select(pairs.map { NSUnionRange($0.selection, $0.mark) }, primary: session.primaryIndex)
  }

  /// 印の範囲を選び、それまでの選択に印を付け替える。
  override func swapWithMark(_ sender: Any?) {
    guard let pairs = markPairs() else { return }
    let primary = session.primaryIndex
    guard
      perform({ try session.setSelections(pairs.map { try selection($0.mark) }, primary: primary) })
    else { return }
    // 印の範囲が重なって選択が一つにまとまったときは、どの選択に付け替えるか決まらないので
    // 印を消す。
    marks = session.selections.count == pairs.count ? pairs.map(\.selection) : []
  }

  /// 印と選択を合わせた範囲を消して kill buffer に入れ、消した位置に印を付け直す。印が
  /// 無ければ選択を消す。NSTextView と同じく、続けて消したときは前に消した文字の前に繋ぐ。
  override func deleteToMark(_ sender: Any?) {
    let ranges: [NSRange]
    if marks.isEmpty {
      ranges = session.selections.map { nsRange(of: $0.range) }
    } else {
      guard let pairs = markPairs() else { return }
      ranges = pairs.map { NSUnionRange($0.selection, $0.mark) }
    }
    if kill(ranges, appending: false) {
      marks = session.selections.map { NSRange(location: offset(of: $0.head), length: 0) }
    }
  }

  /// キャレットのある単語を選ぶ。キャレットは直前の文字に属するものとして扱い、行頭では
  /// 直後の文字に属する。範囲を選んでいるときは、両端をそれぞれ単語の境界まで広げる。
  override func selectWord(_ sender: Any?) {
    select(
      session.selections.map { wordRange(around: nsRange(of: $0.range)) },
      primary: session.primaryIndex)
    inputAssistance.wordSelection = true
  }

  /// `selectWord:` が選ぶ範囲。単語の変換も同じ範囲に掛ける。
  func wordRange(around range: NSRange) -> NSRange {
    let storage = layout.storage
    let string = storage.mutableString
    if range.length > 0 {
      return NSUnionRange(
        storage.doubleClick(at: range.location), storage.doubleClick(at: NSMaxRange(range) - 1))
    }
    let caret = range.location
    guard caret > 0 else { return caret < string.length ? storage.doubleClick(at: 0) : range }
    // 文書の末尾では、直前が改行でも直前の文字に属する (NSTextView と同じ)。
    return storage.doubleClick(
      at: caret == string.length || !string.isLineBreak(at: caret - 1) ? caret - 1 : caret)
  }

  /// 選択の先頭がある表示上の行を選ぶ。段落の最後の行なら、段落を区切る文字も含める。
  /// 改ページなど、行だけを終える文字は含めない (文書の末尾の改ページを除く)。
  override func selectLine(_ sender: Any?) {
    let string = layout.storage.mutableString
    let ranges = session.selections.map { selection -> NSRange in
      let start = offset(of: selection.range.start)
      var line = layout.lineRange(
        containing: start, upstream: selection.isEmpty && upstreamLineEnds.contains(start))
      while line.length > 0, layout.endsLine(at: NSMaxRange(line) - 1) {
        line.length -= 1
      }
      let end = NSMaxRange(line)
      // NSTextView は先頭で空行が続くときだけ、空行の選択に改行を含める。
      let leadingEmptyLines = line.location == 0 && string.length > 1
        && EditorLayout.paragraphSeparators.contains(string.character(at: 1))
      if line.length > 0 || leadingEmptyLines, end < string.length,
        EditorLayout.paragraphSeparators.contains(string.character(at: end))
      {
        line.length += 1
      }
      return line
    }
    select(ranges, primary: session.primaryIndex)
  }

  /// 選択に掛かる段落を、末尾の改行まで含めて選ぶ。
  override func selectParagraph(_ sender: Any?) {
    let string = layout.storage.mutableString
    select(
      session.selections.map { string.paragraphRange(for: nsRange(of: $0.range)) },
      primary: session.primaryIndex)
  }

  /// 主の選択を表示領域の縦の中央に置く。表示領域より高い選択は、先頭を表示領域の上端に置く。
  override func centerSelectionInVisibleArea(_ sender: Any?) {
    let range = nsRange(of: session.primarySelection.range)
    let rects =
      range.length > 0 ? layout.selectionRects(range) : [layout.caretRect(at: range.location)]
    guard let first = rects.first else { return }
    let target = rects.dropFirst().reduce(first) { $0.union($1) }
      .offsetBy(dx: textOrigin.x, dy: textOrigin.y)
    let visible = visibleRect
    let y = target.height > visible.height ? target.minY : target.midY - visible.height / 2
    scroll(CGPoint(x: visible.minX, y: y))
  }

  /// 参照 NSTextView は、書体の大きさやスクロールビューの設定によらず 20pt ずつ送る。
  private static let lineScrollDistance: CGFloat = 20

  override func scrollLineUp(_ sender: Any?) { scrollLine(by: -Self.lineScrollDistance) }
  override func scrollLineDown(_ sender: Any?) { scrollLine(by: Self.lineScrollDistance) }

  private func scrollLine(by distance: CGFloat) {
    let visible = visibleRect
    scroll(CGPoint(x: visible.minX, y: visible.minY + distance))
  }

  /// 引用符の自動置換を通さずに入れる。打鍵ではない入力として入れるので、自動置換は掛からない。
  override func insertSingleQuoteIgnoringSubstitution(_ sender: Any?) { type("'") }
  override func insertDoubleQuoteIgnoringSubstitution(_ sender: Any?) { type("\"") }

  /// NSTextView と同じく改ページの文字 (U+000C) を入れる。
  override func insertContainerBreak(_ sender: Any?) { type("\u{0C}") }

  /// フィールドエディタではないので何もしない。NSTextView も本文の編集では何もしない。
  override func insertBacktab(_ sender: Any?) {}

  /// 選択した範囲を消す。kill buffer にもクリップボードにも入れない。
  @objc func delete(_ sender: Any?) {
    guard session.selections.contains(where: { !$0.isEmpty }) else { return }
    if !smartDeleteSelection() { keepingKill { perform { try session.type("") } } }
  }

  // MARK: - 取り消しとクリップボード

  @objc func undo(_ sender: Any?) { perform { try document.undo() } }
  @objc func redo(_ sender: Any?) { perform { try document.redo() } }

  var selectedTexts: [String] {
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
    if inputAssistance.wordSelection { pasteboard.setString("", forType: Self.smartPasteType) }
  }

  @objc func cut(_ sender: Any?) {
    // 変換中は消せないので、クリップボードも書き換えない。
    guard !hasMarkedText(), !selectedTexts.isEmpty else { return NSSound.beep() }
    writeSelection(to: .general)
    withUndoName(standardUndoName(for: .cut)) {
      if !smartDeleteSelection() { perform { try session.type("") } }
    }
  }

  @objc func paste(_ sender: Any?) {
    paste(from: .general)
  }

  /// 行数とキャレットの数が揃っていれば、一行ずつ各キャレットに配る。文字列の型が無ければ、
  /// HTML などから取り出した文字を入れる (`plainText(from:)`)。
  func paste(from pasteboard: NSPasteboard) {
    guard let pasted = Self.plainText(from: pasteboard) else { return }
    let string = Self.normalizingLineEndings(pasted)
    let count = session.selections.count
    let lines = string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    withUndoName(standardUndoName(for: .paste)) {
      if smartInsertDeleteEnabled, pasteboard.types?.contains(Self.smartPasteType) == true {
        let helper = inputReference()
        replaceEach { index, range in
          let inserted = count > 1 && lines.count == count ? lines[index] : string
          var before: NSString?
          var after: NSString?
          helper.smartInsert(for: inserted, replacing: range, before: &before, after: &after)
          return (range, (before as String? ?? "") + inserted + (after as String? ?? ""))
        }
      } else {
        perform {
          if count > 1, lines.count == count { try session.type(lines) }
          else { try session.type(string) }
        }
      }
    }
  }

  /// 改行を LF に揃える。Swift の文字列では CRLF が一文字なので、揃えてから行に分ける。
  static func normalizingLineEndings(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
  }

  func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if let action = item.action, let enabled = textCheckingToggles[action] {
      (item as? NSMenuItem)?.state = enabled ? .on : .off
      return true
    }
    switch item.action {
    case #selector(undo(_:)):
      (item as? NSMenuItem)?.title = engineUndoManager.undoMenuItemTitle
      return document.canUndo
    case #selector(redo(_:)):
      (item as? NSMenuItem)?.title = engineUndoManager.redoMenuItemTitle
      return document.canRedo
    case #selector(copy(_:)): return !selectedTexts.isEmpty
    case #selector(cut(_:)), #selector(delete(_:)):
      return !hasMarkedText() && session.selections.contains { !$0.isEmpty }
    case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
      return Self.canPaste(from: .general)
    case #selector(startSpeaking(_:)): return layout.storage.length > 0
    // 変換中の文字は、確定するまで変換も調べるも翻訳もしない。
    case #selector(uppercaseWord(_:)), #selector(lowercaseWord(_:)), #selector(capitalizeWord(_:)),
      #selector(convertToFullWidth(_:)), #selector(convertToHalfWidth(_:)),
      #selector(convertToTraditionalChinese(_:)), #selector(convertToSimplifiedChinese(_:)),
      #selector(lookUpFromMenu(_:)), #selector(translateFromMenu(_:)):
      return !hasMarkedText()
    case #selector(stopSpeaking(_:)): return speechSynthesizer?.isSpeaking == true
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
    let wasKey = window?.isKeyWindow == true
    window?.makeFirstResponder(self)
    commitCompositionForPointer()
    dragAndDrop.pressedOnSelection = nil
    // 選択の上を押したときは、ドラッグを始めるか分かるまで選択を変えない。動かさずに離したら
    // キャレットを置く。
    if event.clickCount == 1, !event.modifierFlags.contains(.shift),
      selectionContains(containerPoint(event))
    {
      dragAndDrop.pressedOnSelection = event
      dragAndDrop.pressedWhileInactive = !wasKey
      return
    }
    click(event)
  }

  /// マウスで本文を操作する前に、変換中の文字を確定する。先に確定してから IME に知らせる。
  /// 逆だと IME の確定と二重になる。
  func commitCompositionForPointer() {
    guard session.markedRange != nil else { return }
    commitComposition()
    inputContext?.discardMarkedText()
  }

  /// 押した位置にキャレットを置くか、押した回数に応じて単語や段落を選び、ドラッグで広げる起点にする。
  private func click(_ event: NSEvent) {
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
    inputAssistance.wordSelection = dragGranularity == .word
  }

  override func mouseDragged(with event: NSEvent) {
    if let pressed = dragAndDrop.pressedOnSelection {
      let start = pressed.locationInWindow
      let point = event.locationInWindow
      guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return }
      dragAndDrop.pressedOnSelection = nil
      beginDraggingSelection(with: event)
      return
    }
    guard dragAnchor != nil else { return }
    // 表示を送るのは自動スクロールに任せる。マウスが表示の外で止まっても、選択を広げながら
    // 表示を送り続ける。
    withoutScrolling { extendDrag(to: layout.offset(at: containerPoint(event))) }
    updateAutoscroll(at: event.locationInWindow, mode: .selecting)
  }

  override func mouseUp(with event: NSEvent) {
    stopAutoscroll()
    if let pressed = dragAndDrop.pressedOnSelection {
      dragAndDrop.pressedOnSelection = nil
      // キーでないウィンドウへの押下は、ウィンドウを前に出すだけにする。
      if !dragAndDrop.pressedWhileInactive { click(pressed) }
    }
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
  func extendDrag(to offset: Int) {
    guard let anchor = dragAnchor else { return }
    let current = granularRange(at: offset)
    let start = min(anchor.location, current.location)
    let end = max(NSMaxRange(anchor), NSMaxRange(current))
    let backward = current.location < anchor.location
    let selection = Selection(
      anchor: position(of: backward ? end : start), head: position(of: backward ? start : end))
    perform { try session.setSelections(dragKept + [selection], primary: dragKept.count) }
    inputAssistance.wordSelection = dragGranularity == .word
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
      if commitComposition(text) { retainAlternatives(from: string, insertedText: text) }
      return
    }
    let primary = nsRange(of: session.primarySelection.range)
    let inserted = typing {
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
    if inserted {
      retainAlternatives(from: string, insertedText: text)
      requestInlineCandidates()
    }
  }

  override func insertText(_ insertString: Any) {
    insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let text = self.string(from: string)
    let updated = perform {
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
    }
    // 全て消した変換は終える。空の未確定文字を残すと IME と食い違う。
    if updated, text.isEmpty, session.markedRange != nil { commitComposition() }
  }

  func unmarkText() {
    guard session.markedRange != nil else { return }
    commitComposition()
  }

  /// 変換中の文字を確定する。`text` を渡すと、未確定の文字をそれに置き換えてから確定する。
  /// 確定した文字は、NSTextView と同じく自動置換せず、入力中の検査だけに回す。
  @discardableResult
  func commitComposition(_ text: String? = nil) -> Bool {
    let marked = session.markedRanges.map { nsRange(of: $0) }
    guard perform({ try session.commitComposition(text, historyActionName: standardUndoName(for: .typing)) }) else { return false }
    requestInlineCandidates()
    // 確定した後の各キャレットは、確定した文字の後ろにある。確定した文字は、変換していた範囲の
    // 先頭からキャレットまで。前の範囲で長さが変わった分だけ、後ろの範囲の先頭がずれる。
    let heads = session.selections.map { offset(of: $0.head) }
    guard marked.count == heads.count else {
      // 確定でキャレットがまとまると、範囲とキャレットの対応が分からない。最初の範囲から
      // 最後のキャレットまでをまとめて検査する。
      if let start = marked.first?.location, let end = heads.last {
        textChecker.checkSpelling(in: NSRange(location: min(start, end), length: abs(end - start)))
      }
      return true
    }
    var delta = 0
    for (range, head) in zip(marked, heads) {
      let start = range.location + delta
      let end = max(head, start)
      textChecker.checkSpelling(in: NSRange(location: start, length: end - start))
      delta += end - start - range.length
    }
    return true
  }

  /// 打鍵で文字を入れる。入った文字を、打鍵で入った文字として自動置換と検査に回す。
  @discardableResult
  private func typing(_ operation: () throws -> Void) -> Bool {
    isTyping = true
    typedRanges = []
    let typed = perform(operation)
    isTyping = false
    let ranges = typedRanges
    typedRanges = []
    guard typed else { return false }
    if !ranges.isEmpty { document.setUndoActionName(standardUndoName(for: .typing)) }
    textChecker.insertedText(in: ranges.filter { $0.length > 0 })
    // 打鍵の経路で文字を消しただけの範囲 (入力メソッドが空の文字を入れた場合など) は検査し直す。
    ranges.filter { $0.length == 0 }.forEach(textChecker.checkSpelling(in:))
    return true
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
    return attributedString().attributedSubstring(from: clamped)
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
}

extension NSString {
  /// `index` を含む文字の先頭。合成文字の途中を指す位置を、その文字の前に寄せる。
  fileprivate func characterStart(at index: Int) -> Int {
    index < length ? rangeOfComposedCharacterSequence(at: index).location : index
  }

  /// `index` の文字が行を終えるか。NSTextView の入れ替えと単語の選択は、改行のほかに
  /// 改ページや U+2028 なども行の区切りとして扱う。
  fileprivate func isLineBreak(at index: Int) -> Bool {
    EditorLayout.lineBreaks.contains(character(at: index))
  }
}
