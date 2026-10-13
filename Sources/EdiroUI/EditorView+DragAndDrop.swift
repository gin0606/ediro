import AppKit

struct DragAndDropState {
  /// 選択の上で押したマウスのイベント。ドラッグを始めずに離したら、このイベントでクリックする。
  var pressedOnSelection: NSEvent?
  /// 選択の上で押したときに、ウィンドウがキーでなかったか。その押下はウィンドウを前に出す
  /// だけにして、離してもキャレットを置かない。
  var pressedWhileInactive = false
  /// このビューから始めたドラッグで運んでいる範囲と、そのときの本文の版。
  var dragged: (ranges: [NSRange], textVersion: Int)?
  var beginSession: (EditorView, [NSDraggingItem], NSEvent) -> Void = { view, items, event in
    _ = view.beginDraggingSession(with: items, event: event, source: view)
  }
  var dropOffset: Int?

  /// 自動スクロールで、表示を送った後に合わせるもの。
  enum AutoscrollMode {
    /// ドラッグで広げている選択。マウスが表示の外にあるときに送る。
    case selecting
    /// ドロップ先。マウスが表示の端の近くに少しの間とどまったら送る。
    case dropping
  }

  var autoscrollMode: AutoscrollMode?
  /// 自動スクロールの基にするマウスの位置 (ウィンドウの座標)。
  var autoscrollPoint: NSPoint?
  var autoscrollTicks = 0
  var autoscrollTimer: AutoscrollTimer?
  /// 処理が false を返したら、タイマーを止める。
  var makeAutoscrollTimer:
    (_ interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Bool) -> AutoscrollTimer =
    { interval, tick in
      let timer = Timer(timeInterval: interval, repeats: true) { timer in
        // タイマーはメインの実行ループに載せているので、メインスレッドで呼ばれる。
        nonisolated(unsafe) let timer = timer
        MainActor.assumeIsolated { if !tick() { timer.invalidate() } }
      }
      // ドラッグ中はイベントを追う実行ループのモードで回るので、どのモードでも呼ぶ。
      RunLoop.main.add(timer, forMode: .common)
      return timer
    }
}

protocol AutoscrollTimer: AnyObject {
  func invalidate()
}

extension Timer: AutoscrollTimer {}

extension EditorView: NSDraggingSource {
  static let dragThreshold: CGFloat = 3
  static let autoscrollInterval: TimeInterval = 1.0 / 30
  /// ドロップ中に、表示の端からこの距離に入ったら送る。
  static let dropAutoscrollMargin: CGFloat = 16
  /// ドロップ中に、表示の端の近くにこの回数のタイマーの間とどまったら送り始める。端の近くの
  /// 文字を少しだけ動かすドラッグで、すぐに表示が流れないようにする。
  static let dropAutoscrollDelayTicks = 10

  // MARK: - ペーストボードから読む文字

  /// NSTextView の書式なしの本文と同じく、ファイル名の旧来の型も受け付ける。
  static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

  static let readableTypes: [NSPasteboard.PasteboardType] = [
    .string, .rtf, .rtfd, .html, .URL, .fileURL, legacyFilenamesType,
  ]

  /// ペーストボードの内容を、本文に入れる文字にする。書式なしの NSTextView と同じ順に型を選ぶ。
  /// - 文字列の型があれば、それをそのまま使う。
  /// - RTF、RTFD、HTML は書式と画像を捨てた文字にする。
  /// - URL は文字列にする。ファイルの URL はパスにし、複数あれば改行で繋ぐ。
  /// 文字にできる型が無いか、文字が空なら nil (NSTextView も受け付けない)。
  static func plainText(from pasteboard: NSPasteboard) -> String? {
    guard let text = readText(from: pasteboard), !text.isEmpty else { return nil }
    return text
  }

  static func canPaste(from pasteboard: NSPasteboard) -> Bool {
    pasteboard.availableType(from: readableTypes) != nil
  }

  private static func readText(from pasteboard: NSPasteboard) -> String? {
    if let string = pasteboard.string(forType: .string) { return string }
    let documents: [(NSPasteboard.PasteboardType, NSAttributedString.DocumentType)] = [
      (.rtf, .rtf), (.rtfd, .rtfd), (.html, .html),
    ]
    for (type, documentType) in documents {
      guard let data = pasteboard.data(forType: type) else { continue }
      let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
      if let text = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
        // 画像は書式なしの本文に入らないので、その置き場の文字を除く。
        return text.string.replacingOccurrences(of: "\u{FFFC}", with: "")
      }
    }
    // NSTextView と同じく、最初の URL が Web の URL ならそれだけを、ファイルの URL ならすべての
    // ファイルのパスを入れる。
    guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
      let first = urls.first
    else { return nil }
    guard first.isFileURL else { return first.absoluteString }
    return urls.filter(\.isFileURL).map { url in
      let path = url.path(percentEncoded: false)
      // フォルダの URL は末尾にスラッシュを持つが、NSTextView はスラッシュを付けずに入れる。
      return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }.joined(separator: "\n")
  }

  // MARK: - ドラッグ元

  /// 範囲を選んでいる選択のどれかが、本文の配置の座標の `point` を含むか。Writing Tools が
  /// 書き換えを流し込んでいる間は、選択を見せていないので含まない。
  func selectionContains(_ point: CGPoint) -> Bool {
    guard writingTools.state != .interactiveStreaming else { return false }
    return session.selections.contains { selection in
      !selection.isEmpty
        && layout.selectionRects(nsRange(of: selection.range)).contains { $0.contains(point) }
    }
  }

  /// 選択の上の押下は、キーでないウィンドウでも受け取ってドラッグを始められるようにする。
  /// ウィンドウを前に出すのは、ドラッグを始めずに離したときまで待つ (NSTextView と同じ)。
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    guard let event else { return false }
    return selectionContains(containerPoint(event))
  }

  override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
    selectionContains(containerPoint(event))
  }

  /// 選んでいる文字のドラッグを始める。複数の選択は、コピーと同じく改行で繋いで運ぶ。
  func beginDraggingSelection(with event: NSEvent) {
    let ranges = session.selections.filter { !$0.isEmpty }.map { nsRange(of: $0.range) }
    guard !ranges.isEmpty else { return }
    let item = NSDraggingItem(pasteboardWriter: selectedTexts.joined(separator: "\n") as NSString)
    let frame = dragImageFrame(of: ranges)
    item.setDraggingFrame(frame, contents: dragImage(of: ranges, in: frame))
    dragAndDrop.dragged = (ranges, textVersion)
    // キーでないウィンドウから始めたドラッグでは、ウィンドウを前に出さない。
    NSApp.preventWindowOrdering()
    dragAndDrop.beginSession(self, [item], event)
  }

  /// 範囲の選択の矩形 (ビューの座標)。
  private func viewRects(of ranges: [NSRange]) -> [CGRect] {
    ranges.flatMap { layout.selectionRects($0) }
      .map { $0.offsetBy(dx: textOrigin.x, dy: textOrigin.y) }
  }

  /// ドラッグの画像の枠 (ビューの座標)。選択のうち、見えている部分を囲む。
  func dragImageFrame(of ranges: [NSRange]) -> NSRect {
    let rects = viewRects(of: ranges)
    let union = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    let visible = union.intersection(visibleRect)
    return visible.isEmpty ? union : visible
  }

  /// 選んでいる範囲の文字だけを、背景やキャレットを付けずに描いた画像。
  func dragImage(of ranges: [NSRange], in frame: NSRect) -> NSImage? {
    guard !frame.isEmpty, let rep = bitmapImageRepForCachingDisplay(in: frame),
      let bitmap = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }
    let context = bitmap.cgContext
    // ビューと同じく、上を原点にして下へ進む座標にする。
    context.translateBy(x: 0, y: frame.height)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: -frame.minX, y: -frame.minY)
    context.clip(to: viewRects(of: ranges))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    drawText(in: context, dirtyRect: frame)
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: frame.size)
    image.addRepresentation(rep)
    return image
  }

  /// アプリの中へは移動もコピーもでき、ほかのアプリへはコピーにする (NSTextView と同じ)。
  /// ⌥ を押している間は、システムが操作をコピーに絞る。
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    Self.sourceOperationMask(for: context)
  }

  static func sourceOperationMask(for context: NSDraggingContext) -> NSDragOperation {
    context == .withinApplication ? [.copy, .move, .generic] : [.copy, .generic]
  }

  /// このビューの外へ移動したときは、運んだ元の文字を消す。このビューの中への移動は、
  /// ドロップの側で済ませている。
  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    finishDragging(operation: operation)
  }

  func finishDragging(operation: NSDragOperation) {
    guard let dragged = dragAndDrop.dragged else { return }
    dragAndDrop.dragged = nil
    guard operation == .move, dragged.textVersion == textVersion else { return }
    let replacements = dragged.ranges.sorted { $0.location < $1.location }.map { Replacement($0, "") }
    replace(replacements, selecting: selections(after: replacements))
  }

  // MARK: - ドロップ先

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    updateDrop(sender)
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    updateDrop(sender)
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) { endDrop() }
  override func draggingEnded(_ sender: any NSDraggingInfo) { endDrop() }
  override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { endDrop() }
  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

  /// ドロップの操作の種類。このビューから運んだ文字は、移動できれば移動する。ほかから運んだ
  /// ものは、コピーできればコピーする。文字にできないものは受け付けない。
  func dropOperation(for info: any NSDraggingInfo) -> NSDragOperation {
    guard info.draggingPasteboard.availableType(from: Self.readableTypes) != nil else { return [] }
    let mask = info.draggingSourceOperationMask
    if isOwnDrag(info), dragAndDrop.dragged != nil, mask.contains(.move) { return .move }
    if mask.contains(.copy) { return .copy }
    if mask.contains(.generic) { return .generic }
    return []
  }

  private func isOwnDrag(_ info: any NSDraggingInfo) -> Bool {
    (info.draggingSource as AnyObject?) === self
  }

  /// ドロップしたときに文字が入る位置。`point` はウィンドウの座標。
  func dropOffset(at point: NSPoint) -> Int {
    layout.offset(at: containerPoint(window: point))
  }

  private func updateDrop(_ info: any NSDraggingInfo) -> NSDragOperation {
    let operation = dropOperation(for: info)
    guard !operation.isEmpty else {
      endDrop()
      return []
    }
    setDropOffset(dropOffset(at: info.draggingLocation))
    // マウスが表示の端で止まっても、ドロップ先を動かしながら表示を送り続ける。
    updateAutoscroll(at: info.draggingLocation, mode: .dropping)
    return operation
  }

  private func endDrop() {
    stopAutoscroll()
    setDropOffset(nil)
  }

  private func setDropOffset(_ offset: Int?) {
    guard dragAndDrop.dropOffset != offset else { return }
    for old in [dragAndDrop.dropOffset, offset].compactMap({ $0 }) {
      setNeedsDisplay(caretFrame(at: old).insetBy(dx: -1, dy: -1))
    }
    dragAndDrop.dropOffset = offset
  }

  /// ドロップ先のキャレットを、点滅させずに描く。
  func drawDropCaret() {
    guard let offset = dragAndDrop.dropOffset else { return }
    insertionPointColor.setFill()
    caretFrame(at: offset).fill()
  }

  /// 運んできた文字をドロップ先に入れて選ぶ。このビューから運んだ文字を移動するときは、元の
  /// 文字を消して入れる。どちらも一回の取り消しで戻る。
  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let operation = dropOperation(for: sender)
    endDrop()
    guard !operation.isEmpty, let pasted = Self.plainText(from: sender.draggingPasteboard) else {
      return false
    }
    window?.makeFirstResponder(self)
    // 確定で選択が動いても、ドロップ位置の計算までは表示を保つ。
    withoutScrolling { commitCompositionForPointer() }
    let text = Self.normalizingLineEndings(pasted)
    let offset = dropOffset(at: sender.draggingLocation)
    if operation == .move, let dragged = dragAndDrop.dragged, dragged.textVersion == textVersion {
      // 元の文字はここで消すので、ドラッグの終わりには消さない。
      dragAndDrop.dragged = nil
      return move(dragged.ranges, to: offset, text: text)
    }
    return insert(text, at: offset)
  }

  private func insert(_ text: String, at offset: Int) -> Bool {
    let end = offset + (text as NSString).length
    let selecting = Array(repeating: (anchor: offset, head: end), count: session.selections.count)
    return replace([Replacement(NSRange(location: offset, length: 0), text)], selecting: selecting)
  }

  /// `ranges` の文字を消し、`offset` (消す前の本文の位置) に `text` を入れて選ぶ。運んだ範囲の
  /// 中に落としたときは何もしない。範囲の端に落としたときは、その範囲を `text` で置き換える。
  private func move(_ ranges: [NSRange], to offset: Int, text: String) -> Bool {
    if ranges.contains(where: { $0.location < offset && offset < NSMaxRange($0) }) { return false }
    let sorted = ranges.sorted { $0.location < $1.location }
    // 文字を入れる置き換え。範囲の端に落としたときは、その範囲を置き換える。
    let target =
      sorted.first { $0.location == offset || NSMaxRange($0) == offset }
      ?? NSRange(location: offset, length: 0)
    let replacements = (sorted.filter { $0 != target } + [target])
      .sorted { $0.location < $1.location }
      .map { Replacement($0, $0 == target ? text : "") }
    let start =
      target.location
      + replacements.prefix { $0.range.location < target.location }
      .reduce(0) { $0 + $1.length - $1.range.length }
    let end = start + (text as NSString).length
    let selecting = Array(repeating: (anchor: start, head: end), count: session.selections.count)
    return replace(replacements, selecting: selecting)
  }

  // MARK: - 自動スクロール

  /// 選択のドラッグではマウスが表示の外に、ドロップ中は表示の端の近くにあれば、止まっていても
  /// 一定の間隔で表示を送り続ける。送るたびに、選択やドロップ先を新しい表示に合わせる。送る
  /// 位置から外れたら止める。
  func updateAutoscroll(at point: NSPoint, mode: DragAndDropState.AutoscrollMode) {
    dragAndDrop.autoscrollPoint = point
    dragAndDrop.autoscrollMode = mode
    guard autoscrollDistance() != 0 else { return stopAutoscroll() }
    guard dragAndDrop.autoscrollTimer == nil else { return }
    dragAndDrop.autoscrollTicks = 0
    dragAndDrop.autoscrollTimer = dragAndDrop.makeAutoscrollTimer(Self.autoscrollInterval) {
      [weak self] in self?.autoscrollTick() ?? false
    }
  }

  func stopAutoscroll() {
    dragAndDrop.autoscrollTimer?.invalidate()
    dragAndDrop.autoscrollTimer = nil
    dragAndDrop.autoscrollPoint = nil
    dragAndDrop.autoscrollMode = nil
  }

  /// 一回に送る縦の距離。マウスが送る位置に入り込んだ分だけ送るので、深いほど速い。
  private func autoscrollDistance() -> CGFloat {
    guard let windowPoint = dragAndDrop.autoscrollPoint, let mode = dragAndDrop.autoscrollMode
    else { return 0 }
    let point = convert(windowPoint, from: nil)
    let visible = visibleRect
    let margin = mode == .dropping ? min(Self.dropAutoscrollMargin, visible.height / 4) : 0
    if point.y < visible.minY + margin { return min(point.y - (visible.minY + margin), -1) }
    if point.y > visible.maxY - margin { return max(point.y - (visible.maxY - margin), 1) }
    return 0
  }

  /// タイマーの一回分。表示を送り、選択かドロップ先を合わせる。止めたら false を返す。
  @discardableResult
  func autoscrollTick() -> Bool {
    let distance = autoscrollDistance()
    guard distance != 0, let mode = dragAndDrop.autoscrollMode,
      let point = dragAndDrop.autoscrollPoint
    else {
      stopAutoscroll()
      return false
    }
    dragAndDrop.autoscrollTicks += 1
    if mode == .dropping, dragAndDrop.autoscrollTicks <= Self.dropAutoscrollDelayTicks {
      return true
    }
    let visible = visibleRect
    scroll(NSPoint(x: visible.minX, y: visible.minY + distance))
    // 端まで送り切ったら、マウスが外にあっても選択は変わらない。
    guard visibleRect.origin != visible.origin else { return true }
    switch mode {
    case .selecting:
      // 送る距離は自動スクロールに任せ、選択を広げても表示を送らない。
      withoutScrolling { extendDrag(to: layout.offset(at: containerPoint(window: point))) }
    case .dropping:
      setDropOffset(dropOffset(at: point))
    }
    return true
  }
}
