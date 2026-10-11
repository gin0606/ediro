import AppKit
import EditorEngine

/// Writing Tools に渡した本文の範囲 (コンテキスト) ごとの、本文の中の位置。
struct WritingToolsContextRecord {
  let context: NSWritingToolsCoordinator.Context
  /// コンテキストの文字列の先頭の、本文でのオフセット。
  var start: Int
  /// コンテキストの文字列の、今の長さ。Writing Tools の置き換えと利用者の編集で変わる。
  var length: Int
}

/// アニメーションの間、隠すか薄くする本文。
struct WritingToolsHiddenText {
  /// 準備と終わりを対応させる、アニメーションの種類とコンテキストの中の範囲。
  let animation: NSWritingToolsCoordinator.TextAnimation
  let range: NSRange
  let context: UUID
  /// 隠す本文の範囲。本文の編集に合わせてずらす。
  var documentRange: NSRange
  /// 後ろの文字を動かすアニメーションでは、範囲の先頭から本文の末尾までを隠す。
  var throughEnd: Bool { animation == .translate }
  /// 待機中のアニメーションでは、隠さずに薄くする。
  var dims: Bool { animation == .anticipateInactive }
}

/// 文法の提示で候補を一時的に当てる前の、文法の誤り。退けたら、この誤りを無視させる。
struct GrammarIssue {
  /// 誤りのある文と、文の中の誤りの範囲。
  let sentence: String
  let range: NSRange
  /// 本文の中の誤りの範囲。
  var documentRange: NSRange
}

/// Writing Tools との連携の状態。
struct WritingToolsState {
  var contexts: [UUID: WritingToolsContextRecord] = [:]
  var hidden: [WritingToolsHiddenText] = []
  var state: NSWritingToolsCoordinator.State = .inactive
  /// 文法の誤りを示すアニメーションのために作ったコンテキストと、そのアニメーション。
  /// アニメーションが終わったら捨てる。
  var indications: [UUID: UUID] = [:]
  /// Writing Tools が本文を置き換えているコンテキスト。その変更はコーディネータに知らせ直さない。
  var replacingContext: UUID?
  /// エンジンの通知の間にたまった、コーディネータへの知らせ。本文の配置を更新してから送る。
  var pendingUpdates: [(context: UUID, send: (NSWritingToolsCoordinator) -> Void)] = []
  /// 配置が変わったことを知らせるコンテキスト。一度の通知で同じコンテキストに何度も送らない。
  var pendingReflows: Set<UUID> = []
  /// 今の Writing Tools の一回分の置き換えをまとめる取り消し履歴の名前。
  var historyGroup: String?
  var historyGroupCount = 0
  /// コンテキストの依頼の数。後で止めるときに、その後に新しい依頼が来ていないかを確かめる。
  var contextRequestCount = 0
  /// 編集の途中で取りやめた、文法の誤りを示すアニメーションの誤りの範囲。編集に合わせて
  /// ずらし、編集の通知を全て当てた後に、検査し直したときにまた示せるようにする。
  var pendingForgottenIndications: [NSRange] = []
  /// 編集の通知の中で取りやめた、文法の誤りを示すアニメーション。本文の配置を更新してから
  /// コーディネータに知らせる。
  var pendingCancelledAnimations: [UUID] = []
  /// 文法の提示で候補を一時的に当てた誤り。
  var previewedGrammarIssues: [GrammarIssue] = []
}

/// プレビューの画像に、スペルと文法の誤りの印をどう描くか。
enum TextPreviewMarks {
  /// 表示のとおりに描く。
  case asDisplayed
  /// 文法の誤りの印を描かない (スペルの印は表示のとおり)。
  case none
  /// 範囲全体に文法の誤りの印を付けて描く (スペルの印は表示のとおり)。
  case grammarUnderline
}

/// Writing Tools (校正・書き直しなど)。NSWritingToolsCoordinator の委譲として、本文と選択の
/// 受け渡し、置き換え、アニメーション用の画像と位置を返す。
///
/// 本文の書き換えはエンジン経由で行う。Writing Tools の一回分 (コーディネータが動いている間)
/// の置き換えは、間に選択が変わっても一回の取り消しで戻る。結果は書式なしのテキストで受け取る。
extension EditorView: NSWritingToolsCoordinator.Delegate {
  func setUpWritingTools() {
    let coordinator = NSWritingToolsCoordinator(delegate: self)
    coordinator.preferredBehavior = .complete
    coordinator.preferredResultOptions = .plainText
    writingToolsCoordinator = coordinator
  }

  /// 本文を外から差し替える前に、Writing Tools を止めて渡したコンテキストを捨てる。
  func stopWritingToolsForReplacement() {
    writingToolsCoordinator?.stopWritingTools()
    writingTools.state = .inactive
    endWritingToolsSession()
    updateCarets()
  }

  private func endWritingToolsSession(whileEditing: Bool = false) {
    cancelGrammarIndications(Array(writingTools.indications.keys), whileEditing: whileEditing)
    writingTools.contexts = [:]
    writingTools.hidden = []
    writingTools.previewedGrammarIssues = []
    endWritingToolsHistoryGroup()
    needsDisplay = true
    // 編集の通知の中では、本文の配置を更新した後にキャレットを置き直す。
    if !whileEditing { updateCarets() }
  }

  /// 一回分の取り消しの単位を閉じる。エンジンの通知の中では閉じられないので、通知の後に閉じる。
  private func endWritingToolsHistoryGroup() {
    guard let group = writingTools.historyGroup else { return }
    writingTools.historyGroup = nil
    if (try? document.endHistoryGroup()) == nil {
      DispatchQueue.main.async { [weak self] in
        guard let self, document.heldGroup == group else { return }
        try? document.endHistoryGroup()
      }
    }
  }

  /// Writing Tools の置き換えに使う取り消し履歴の名前。一回分の初めの置き換えで、新しい
  /// 取り消しの単位を始める。始められなければ nil。
  private func writingToolsHistoryGroup() -> String? {
    if let group = writingTools.historyGroup { return group }
    writingTools.historyGroupCount += 1
    let group = "writing-tools-\(writingTools.historyGroupCount)"
    guard (try? document.beginHistoryGroup(group)) != nil else { return nil }
    writingTools.historyGroup = group
    return group
  }

  // MARK: - 位置の対応

  /// コンテキストの中の範囲を、本文の範囲にする。コンテキストを知らないか、範囲が今の
  /// コンテキストの外に出るか、文字の途中を指すなら nil。
  func documentRange(_ range: NSRange, in context: NSWritingToolsCoordinator.Context) -> NSRange? {
    guard let record = writingTools.contexts[context.identifier], range.location != NSNotFound,
      range.location >= 0, range.length >= 0, range.location <= record.length,
      range.length <= record.length - range.location,
      record.start + record.length <= layout.storage.length
    else { return nil }
    let target = NSRange(location: record.start + range.location, length: range.length)
    let snapshot = document.snapshot
    guard (try? snapshot.position(at: target.location)) != nil,
      (try? snapshot.position(at: NSMaxRange(target))) != nil
    else { return nil }
    return target
  }

  /// 範囲を覆う矩形。ビューの座標。空の範囲は、その位置のキャレットの矩形 (幅 1) にする。
  private func viewRects(_ range: NSRange) -> [CGRect] {
    let rects =
      range.length > 0
      ? layout.selectionRects(range)
      : [layout.caretRect(at: range.location).insetBy(dx: -0.5, dy: 0)]
    return rects.map { $0.offsetBy(dx: textOrigin.x, dy: textOrigin.y) }
  }

  /// 本文の範囲 `span` の文字列をコンテキストにして覚える。`range` は本文の範囲で、
  /// コンテキストの中の Writing Tools に扱わせる範囲になる。
  private func makeContext(span: NSRange, range: NSRange) -> NSWritingToolsCoordinator.Context {
    let context = NSWritingToolsCoordinator.Context(
      attributedString: layout.storage.attributedSubstring(from: span),
      range: NSRange(location: range.location - span.location, length: range.length))
    writingTools.contexts[context.identifier] = WritingToolsContextRecord(
      context: context, start: span.location, length: span.length)
    return context
  }


  // MARK: - 本文と選択

  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator,
    requestsContextsFor scope: NSWritingToolsCoordinator.ContextScope,
    completion: @escaping @Sendable ([NSWritingToolsCoordinator.Context]) -> Void
  ) {
    // 変換中の文字は確定してから渡す。確定で表示を送らず、見えている範囲を変えない。
    if session.markedRange != nil {
      withoutScrolling { commitComposition() }
      inputContext?.discardMarkedText()
    }
    let string = layout.storage.mutableString
    let full = NSRange(location: 0, length: string.length)
    // 複数の選択があるときは主の選択を渡す。選択が無ければ本文全体を扱わせる。選択と見えて
    // いる範囲には、それを含む段落を添える。
    let selection = nsRange(of: session.primarySelection.range)
    let range: NSRange
    let span: NSRange
    switch scope {
    case .userSelection where selection.length > 0:
      range = selection
      span = string.paragraphRange(for: selection)
    case .visibleArea:
      range = characterRange(in: visibleRect)
      span = string.paragraphRange(for: range)
    default:
      range = full
      span = full
    }
    // 新しい依頼は新しい一回分になり、前に渡したコンテキストは使われない。
    endWritingToolsSession()
    writingTools.contextRequestCount += 1
    completion([makeContext(span: span, range: range)])
  }

  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator, replace range: NSRange,
    in context: NSWritingToolsCoordinator.Context, proposedText replacementText: NSAttributedString,
    reason: NSWritingToolsCoordinator.TextReplacementReason,
    animationParameters: NSWritingToolsCoordinator.AnimationParameters?,
    completion: @escaping @Sendable (NSAttributedString?) -> Void
  ) {
    guard !hasMarkedText(), let target = documentRange(range, in: context) else {
      return completion(nil)
    }
    // エンジンは改行を LF に揃えて入れる。入れた文字を Writing Tools に返す。
    let text = Self.normalizingLineEndings(replacementText.string)
    let replacement = Replacement(target, text)
    #if canImport(AppKit, _version: 2700)  // macOS 27 SDK
    if #available(macOS 27.0, *), [.temporary, .accepted, .rejected].contains(reason),
      writingTools.previewedGrammarIssues.isEmpty
    {
      writingTools.previewedGrammarIssues = grammarIssues(touching: target)
    }
    #endif
    let group = writingToolsHistoryGroup()
    // このコンテキストの位置は、ここで置き換えに合わせる。コンテキストの端に文字を入れる
    // 置き換えも、コンテキストの中の変更として扱う。
    // Writing Tools が動かしている所を見せたままにするため、置き換えで表示を送らない。
    writingTools.replacingContext = context.identifier
    var replaced = false
    withoutScrolling {
      replaced = replace(
        [replacement], selecting: selections(after: [replacement]), historyGroup: group,
        beepsOnFailure: false)
    }
    writingTools.replacingContext = nil
    // 動いていないときの置き換えは、それだけで一回分にする。文法の提示の一時的な置き換えは、
    // 受け入れるか退けるまで続ける。
    if writingTools.state == .inactive, [.interactive, .noninteractive].contains(reason) {
      endWritingToolsHistoryGroup()
    }
    guard replaced else { return completion(nil) }
    #if canImport(AppKit, _version: 2700)
    if #available(macOS 27.0, *), [.accepted, .rejected].contains(reason) {
      // 文法の提示で候補を退けたときは、その誤りを無視させる。受け入れるか退けたところで、
      // 提示の一回分の取り消しを閉じる。
      if reason == .rejected { ignoreGrammarIssues(writingTools.previewedGrammarIssues) }
      writingTools.previewedGrammarIssues = []
      if writingTools.state == .inactive { endWritingToolsHistoryGroup() }
    }
    #endif
    completion(NSAttributedString(string: text))
  }

  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator, select ranges: [NSValue],
    in context: NSWritingToolsCoordinator.Context, completion: @escaping @Sendable () -> Void
  ) {
    // 変換中は選択を動かせない。
    let targets = ranges.compactMap { documentRange($0.rangeValue, in: context) }
    // 見えている所の選択では表示を送らない。見えていない所なら、その選択まで送る。
    if !targets.isEmpty, !hasMarkedText() {
      let visible = visibleRect
      let shown = viewRects(targets[0]).contains { $0.intersects(visible) }
      if shown {
        withoutScrolling { select(targets, primary: 0, beepsOnFailure: false) }
      } else {
        select(targets, primary: 0, beepsOnFailure: false)
      }
    }
    completion()
  }

  // MARK: - 位置と形

  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator,
    requestsBoundingBezierPathsFor range: NSRange, in context: NSWritingToolsCoordinator.Context,
    completion: @escaping @Sendable ([NSBezierPath]) -> Void
  ) {
    completion(boundingPaths(for: range, in: context))
  }

  /// 範囲の文字を行ごとに囲む形。ビューの座標。
  func boundingPaths(for range: NSRange, in context: NSWritingToolsCoordinator.Context)
    -> [NSBezierPath]
  {
    guard let target = documentRange(range, in: context) else { return [] }
    return viewRects(target).map { NSBezierPath(rect: $0) }
  }

  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator,
    requestsUnderlinePathsFor range: NSRange, in context: NSWritingToolsCoordinator.Context,
    completion: @escaping @Sendable ([NSBezierPath]) -> Void
  ) {
    completion(underlinePaths(for: range, in: context))
  }

  /// 範囲の文字の行ごとの下端に引く線。ビューの座標。
  func underlinePaths(for range: NSRange, in context: NSWritingToolsCoordinator.Context)
    -> [NSBezierPath]
  {
    guard let target = documentRange(range, in: context) else { return [] }
    return viewRects(target).map { rect in
      let path = NSBezierPath()
      path.move(to: NSPoint(x: rect.minX, y: rect.maxY - 1))
      path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - 1))
      path.lineWidth = 2
      return path
    }
  }

  // MARK: - アニメーション

  /// アニメーションの間は、Writing Tools が本文の画像を重ねて動かすので、その範囲の本文を
  /// 隠す。待機中 (`anticipateInactive`) は隠さずに薄くする。後ろの文字を動かすアニメーション
  /// (`translate`) では、範囲の先頭から本文の末尾までを隠す。終わったら戻す。
  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator,
    prepareFor textAnimation: NSWritingToolsCoordinator.TextAnimation, for range: NSRange,
    in context: NSWritingToolsCoordinator.Context, completion: @escaping @Sendable () -> Void
  ) {
    if let target = documentRange(range, in: context) {
      writingTools.hidden.append(
        WritingToolsHiddenText(
          animation: textAnimation, range: range, context: context.identifier,
          documentRange: target))
      needsDisplay = true
      updateCarets()
    }
    completion()
  }

  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator,
    finish textAnimation: NSWritingToolsCoordinator.TextAnimation, for range: NSRange,
    in context: NSWritingToolsCoordinator.Context, completion: @escaping @Sendable () -> Void
  ) {
    // `translate` は準備と終わりで範囲が違う (準備で入れた範囲の後ろの位置、終わりで入れた
    // 範囲を渡す)。
    let sameKind = { (hidden: WritingToolsHiddenText) in
      hidden.animation == textAnimation && hidden.context == context.identifier
    }
    // 準備の後の編集で位置がずれていても対応するよう、`translate` は本文での位置で比べる。
    let finished = textAnimation == .translate ? documentRange(range, in: context) : nil
    if let index = writingTools.hidden.firstIndex(where: { sameKind($0) && $0.range == range })
      ?? writingTools.hidden.firstIndex(where: {
        sameKind($0) && finished.map { NSMaxRange($0) } == $0.documentRange.location
      })
    {
      writingTools.hidden.remove(at: index)
    }
    if writingTools.indications[context.identifier] != nil,
      !writingTools.hidden.contains(where: { $0.context == context.identifier })
    {
      writingTools.indications[context.identifier] = nil
      writingTools.contexts[context.identifier] = nil
    }
    needsDisplay = true
    updateCarets()
    completion()
  }

  /// アニメーションのために隠している本文と、薄くしている本文の矩形。ビューの座標。
  ///
  /// `rect` (ビューの座標) に掛かる行の分だけを求める。
  func writingToolsHiddenRects(in rect: CGRect) -> (hidden: [CGRect], dimmed: [CGRect]) {
    guard !writingTools.hidden.isEmpty else { return ([], []) }
    let length = layout.storage.length
    let lines = lineRange(in: rect)
    var hidden: [CGRect] = []
    var dimmed: [CGRect] = []
    for entry in writingTools.hidden {
      let start = min(entry.documentRange.location, length)
      let end = entry.throughEnd ? length : min(NSMaxRange(entry.documentRange), length)
      // 空の範囲は隠す文字が無い。
      guard end > start else { continue }
      let rects = clipped(NSRange(location: start, length: end - start), to: lines).map(viewRects) ?? []
      if entry.dims { dimmed += rects } else { hidden += rects }
    }
    return (hidden, dimmed)
  }

  /// `range` のうち `lines` に入る部分。重ならなければ nil。空の範囲は、`lines` の中か端に
  /// あればそのまま返す。
  private func clipped(_ range: NSRange, to lines: NSRange) -> NSRange? {
    if range.length == 0 {
      return lines.location <= range.location && range.location <= NSMaxRange(lines) ? range : nil
    }
    let intersection = NSIntersectionRange(range, lines)
    return intersection.length > 0 ? intersection : nil
  }

  /// `rect` (ビューの座標) に掛かる表示上の行の文字の範囲。
  private func characterRange(in rect: CGRect) -> NSRange {
    let start = layout.offset(at: CGPoint(x: 0, y: rect.minY - textOrigin.y))
    let end = layout.offset(at: CGPoint(x: bounds.width, y: rect.maxY - textOrigin.y))
    return NSRange(location: min(start, end), length: abs(end - start))
  }

  /// `rect` (ビューの座標) に掛かる段落の文字の範囲。
  private func lineRange(in rect: CGRect) -> NSRange {
    layout.storage.mutableString.lineRange(for: characterRange(in: rect))
  }

  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator,
    requestsPreviewFor textAnimation: NSWritingToolsCoordinator.TextAnimation, of range: NSRange,
    in context: NSWritingToolsCoordinator.Context,
    completion: @escaping @Sendable ([NSTextPreview]?) -> Void
  ) {
    completion(textPreview(of: range, in: context).map { [$0] })
  }

  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator, requestsPreviewFor rect: NSRect,
    in context: NSWritingToolsCoordinator.Context,
    completion: @escaping @Sendable (NSTextPreview?) -> Void
  ) {
    completion(textPreview(of: rect, in: context))
  }

  /// 範囲の文字だけを描いた、透明な背景の画像。位置は範囲の文字を囲む矩形のうち、表示領域に
  /// 見えている所。見えていなければ nil。
  func textPreview(
    of range: NSRange, in context: NSWritingToolsCoordinator.Context,
    marks: TextPreviewMarks = .asDisplayed
  ) -> NSTextPreview? {
    guard let target = documentRange(range, in: context) else { return nil }
    let visible = visibleRect
    let rects = (clipped(target, to: lineRange(in: visible)).map(viewRects) ?? [])
      .map { $0.intersection(visible) }.filter { !$0.isEmpty }
    guard let first = rects.first else { return nil }
    let frame = rects.dropFirst().reduce(first) { $0.union($1) }
    var image: CGImage?
    if marks != .asDisplayed, let textRange = layout.textRange(target) {
      // 表示の印を外し、下線を描くなら文法の誤りの印を表示と同じ描き方で付けて描く。
      // 文法の誤りの印だけを外すか、範囲全体に付ける。スペルの印は表示のとおりに残す。
      let manager = layout.layoutManager
      let grammar = NSAttributedString.SpellingState.grammar.rawValue
      manager.removeRenderingAttribute(.spellingState, for: textRange)
      let annotations = textChecker.annotations
      if NSMaxRange(target) <= annotations.length {
        annotations.enumerateAttribute(.spellingState, in: target) { value, run, _ in
          let state = (value as? String).flatMap(Int.init) ?? 0
          let shown =
            (state & NSAttributedString.SpellingState.spelling.rawValue)
            | (marks == .grammarUnderline ? grammar : 0)
          guard shown != 0, let runRange = layout.textRange(run) else { return }
          manager.addRenderingAttribute(.spellingState, value: shown, for: runRange)
        }
      }
      image = previewImage(of: frame, clippingTo: rects)
      manager.removeRenderingAttribute(.spellingState, for: textRange)
      textChecker.refreshMarks(in: target)
    } else {
      image = previewImage(of: frame, clippingTo: rects)
    }
    guard let image else { return nil }
    return NSTextPreview(
      snapshotImage: image, presentationFrame: frame,
      candidateRects: rects.map { NSValue(rect: $0) })
  }

  /// ビューの矩形に入る本文を描いた、透明な背景の画像。候補の矩形はコンテキストの文字のうち
  /// 矩形に掛かるもの。
  func textPreview(of rect: NSRect, in context: NSWritingToolsCoordinator.Context)
    -> NSTextPreview?
  {
    let frame = rect.intersection(bounds)
    guard !frame.isEmpty, let record = writingTools.contexts[context.identifier],
      let image = previewImage(of: frame, clippingTo: nil)
    else { return nil }
    let span = clipped(NSRange(location: record.start, length: record.length), to: lineRange(in: frame))
    let candidates = (span.map(viewRects) ?? []).map { $0.intersection(frame) }.filter { !$0.isEmpty }
    return NSTextPreview(
      snapshotImage: image, presentationFrame: frame,
      candidateRects: candidates.map { NSValue(rect: $0) })
  }

  /// `frame` (ビューの座標) の本文を、透明な背景に描く。隠している本文も描く。色はビューの
  /// 外観で決める。
  private func previewImage(of frame: CGRect, clippingTo clip: [CGRect]?) -> CGImage? {
    let scale = window?.backingScaleFactor ?? 2
    let width = Int((frame.width * scale).rounded(.up))
    let height = Int((frame.height * scale).rounded(.up))
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // ビューと同じく上から下へ進む座標にする。
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: frame.height)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: -frame.minX, y: -frame.minY)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    effectiveAppearance.performAsCurrentDrawingAppearance {
      if let clip { context.clip(to: clip) }
      drawText(in: context, dirtyRect: frame)
    }
    return context.makeImage()
  }

  // MARK: - 状態

  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator,
    willChangeTo newState: NSWritingToolsCoordinator.State,
    completion: @escaping @Sendable () -> Void
  ) {
    writingTools.state = newState
    // 終わったら、一回分の取り消しの単位を閉じ、渡したコンテキストを捨てる。動き始めたら、
    // 文法の誤りを示している途中のアニメーションを取りやめる。
    if newState == .inactive {
      endWritingToolsSession()
    } else {
      cancelGrammarIndications(Array(writingTools.indications.keys))
    }
    // 書き換えを流し込んでいる間は、選択とキャレットを見せない (NSTextView と同じ)。
    needsDisplay = true
    updateCarets()
    completion()
  }

  // MARK: - 利用者の編集と配置の変化

  /// 本文の編集を、渡したコンテキストと隠している本文の位置に反映し、Writing Tools 自身の
  /// 置き換え以外の編集 (打鍵、取り消しなど) はコーディネータへの知らせとしてためる。ためた
  /// 知らせは、本文の配置を更新した後に `sendWritingToolsUpdates()` で送る。差分のオフセット
  /// はその差分を当てる直前の本文で数える。
  ///
  /// 文法の誤りを示しているコンテキストの中の編集では、そのアニメーションを取りやめる。動いて
  /// いる Writing Tools のコンテキストの境界をまたぐ編集は、位置を対応させられないので
  /// Writing Tools を止める。
  func trackWritingToolsContexts(_ batch: [ContentChange], undoRedo: Bool) {
    guard
      !writingTools.contexts.isEmpty || !writingTools.hidden.isEmpty
        || !writingTools.previewedGrammarIssues.isEmpty
        || !writingTools.pendingForgottenIndications.isEmpty
    else { return }
    var straddled = false
    var cancelled: [UUID] = []
    // 後ろの差分から当てれば、前の差分のオフセットは変わらない。
    for change in batch.reversed() {
      let start = change.offset
      let end = change.offset + change.removedLength
      let delta = change.insertedLength - change.removedLength
      for index in writingTools.hidden.indices {
        var range = writingTools.hidden[index].documentRange
        // Writing Tools が隠している範囲の端に入れた文字も、その範囲と一緒に隠す。
        let touches = start <= NSMaxRange(range) && end >= range.location
        let overlaps = start < NSMaxRange(range) && end > range.location
        let inserts = change.removedLength == 0
        // 後ろの文字を動かすアニメーションの位置に入れた文字は、その前に入ったものとしてずらす。
        let entry = writingTools.hidden[index]
        let grows =
          writingTools.replacingContext == entry.context && inserts && touches && !entry.throughEnd
        if overlaps || grows {
          let newStart = min(range.location, start)
          range = NSRange(
            location: newStart, length: max(NSMaxRange(range), end) + delta - newStart)
        } else if end <= range.location {
          range.location += delta
        }
        writingTools.hidden[index].documentRange = range
      }
      // 一時的に当てた候補の誤りは、前の編集でずらし、誤りに掛かる編集では捨てる。置き換え
      // 自身はその誤りの文字を書き換えるので、ずらすだけにする。
      writingTools.previewedGrammarIssues = writingTools.previewedGrammarIssues.compactMap {
        var issue = $0
        if end <= issue.documentRange.location {
          issue.documentRange.location += delta
        } else if start < NSMaxRange(issue.documentRange), writingTools.replacingContext == nil {
          return nil
        }
        return issue
      }
      for (id, record) in writingTools.contexts {
        let contextEnd = record.start + record.length
        let isIndication = writingTools.indications[id] != nil
        let issueStart = record.start + record.context.range.location
        let issueEnd = issueStart + record.context.range.length
        if id == writingTools.replacingContext {
          // Writing Tools 自身の置き換えは、コンテキストの端に文字を入れるものも中の変更として
          // 長さを合わせ、知らせない。
          writingTools.contexts[id]?.length += delta
          continue
        } else if isIndication
          && ((start <= issueEnd && end >= issueStart) || (record.start < end && start < issueStart))
        {
          // 示している誤りに接する編集と、段落の中で誤りより前の編集は、誤りの位置や文字を
          // 変えるので、アニメーションを取りやめる。検査し直したときにまた示せるよう、誤りの
          // 位置を控えて、この後の編集に合わせてずらす。
          cancelled.append(id)
          writingTools.pendingForgottenIndications.append(
            NSRange(location: issueStart, length: issueEnd - issueStart))
        } else if end <= record.start && !(record.length == 0 && start == record.start) {
          // コンテキストの前の編集。文字が入る位置がコンテキストの先頭でも前とみなす (空の
          // コンテキストでは中とみなす)。長さが変わらなくても、折り返しが変わりうるので知らせる。
          writingTools.contexts[id]?.start += delta
          writingTools.pendingReflows.insert(id)
        } else if start == contextEnd && end == contextEnd && record.length > 0 {
          // 末尾に入った文字は扱わせないが、最後の行の折り返しが変わりうる。
          if !isIndication { writingTools.pendingReflows.insert(id) }
        } else if start > contextEnd || (start == contextEnd && record.length > 0) {
          continue
        } else if isIndication {
          // 示している誤りより後ろの編集は、誤りの位置を変えない。
          if end <= contextEnd {
            writingTools.contexts[id]?.length += delta
            let range = NSRange(location: start - record.start, length: change.removedLength)
            let text = NSAttributedString(string: change.insertedText)
            let reason: NSWritingToolsCoordinator.TextUpdateReason = undoRedo ? .undoRedo : .typing
            writingTools.pendingUpdates.append(
              (id, { $0.updateRange(range, with: text, reason: reason, forContextWithIdentifier: id) }))
          } else {
            // 段落の外までまたぐ編集では、コンテキストの位置を対応させられないので取りやめる。
            cancelled.append(id)
            writingTools.pendingForgottenIndications.append(
              NSRange(location: issueStart, length: issueEnd - issueStart))
          }
        } else if start >= record.start && end <= contextEnd {
          writingTools.contexts[id]?.length += delta
          let range = NSRange(location: start - record.start, length: change.removedLength)
          let text = NSAttributedString(string: change.insertedText)
          let reason: NSWritingToolsCoordinator.TextUpdateReason = undoRedo ? .undoRedo : .typing
          writingTools.pendingUpdates.append(
            (id, { $0.updateRange(range, with: text, reason: reason, forContextWithIdentifier: id) }))
        } else if writingTools.state == .inactive {
          // 動いていない依頼のコンテキストは、もう使われないので捨てる。
          writingTools.contexts[id] = nil
        } else {
          straddled = true
        }
      }
      writingTools.pendingForgottenIndications = writingTools.pendingForgottenIndications.map {
        var range = $0
        if end <= range.location {
          range.location += delta
        } else if start < NSMaxRange(range) || start == range.location {
          let newStart = min(range.location, start)
          range = NSRange(
            location: newStart, length: max(NSMaxRange(range), end) + delta - newStart)
        }
        return range
      }
    }
    cancelGrammarIndications(cancelled, whileEditing: true)
    guard straddled else { return }
    writingTools.pendingUpdates = []
    writingTools.pendingReflows = []
    writingTools.state = .inactive
    endWritingToolsSession(whileEditing: true)
    // 通知の中ではエンジンを操作できないので、止めるのは通知の後にする。その間に新しい依頼が
    // 来ていたら、その依頼は止めない。
    let request = writingTools.contextRequestCount
    DispatchQueue.main.async { [weak self] in
      guard let self, writingTools.contextRequestCount == request else { return }
      writingToolsCoordinator?.stopWritingTools()
    }
  }

  /// `trackWritingToolsContexts` がためた知らせを送る。
  func sendWritingToolsUpdates() {
    for issue in writingTools.pendingForgottenIndications {
      textChecker.forgetIndicatedGrammar(in: issue)
    }
    writingTools.pendingForgottenIndications = []
    let cancelled = writingTools.pendingCancelledAnimations
    writingTools.pendingCancelledAnimations = []
    cancelTextAnimations(cancelled)
    let updates = writingTools.pendingUpdates
    let reflows = writingTools.pendingReflows
    writingTools.pendingUpdates = []
    writingTools.pendingReflows = []
    guard let coordinator = writingToolsCoordinator else { return }
    // 同じ編集の別の差分で捨てたコンテキストには送らない。
    for update in updates where writingTools.contexts[update.context] != nil {
      update.send(coordinator)
    }
    for id in reflows where writingTools.contexts[id] != nil {
      coordinator.updateForReflowedTextInContextWithIdentifier(id)
    }
  }

  private func cancelTextAnimations(_ animations: [UUID]) {
    guard !animations.isEmpty else { return }
    #if canImport(AppKit, _version: 2700)
    if #available(macOS 27.0, *) {
      writingToolsCoordinator?.cancelTextAnimations(identifiers: animations)
    }
    #endif
  }

  /// 文法の誤りを示すアニメーションを取りやめ、そのコンテキストと隠している本文を捨てる。
  /// `whileEditing` なら、エンジンの通知の中なので、コーディネータに知らせるのは後にする。
  func cancelGrammarIndications(_ contexts: [UUID], whileEditing: Bool = false) {
    guard !contexts.isEmpty else { return }
    // 取りやめた誤りは、検査し直したときにまた示す。コーディネータは取りやめる呼び出しの中で
    // アニメーションを終えてコンテキストを捨てさせるので、先に位置を控える。
    for id in contexts {
      guard let record = writingTools.contexts[id], writingTools.indications[id] != nil else {
        continue
      }
      let issue = NSRange(
        location: record.start + record.context.range.location,
        length: record.context.range.length)
      // 編集の途中の取りやめでは、位置を控えるのは編集を追う側が行う。
      if !whileEditing { textChecker.forgetIndicatedGrammar(in: issue) }
    }
    let animations = contexts.compactMap { writingTools.indications[$0] }
    if whileEditing {
      writingTools.pendingCancelledAnimations += animations
    } else {
      cancelTextAnimations(animations)
    }
    for id in contexts {
      writingTools.indications[id] = nil
      writingTools.contexts[id] = nil
      writingTools.hidden.removeAll { $0.context == id }
    }
    needsDisplay = true
    if !whileEditing { updateCarets() }
  }

  /// 幅や書体が変わって本文を組み直したときに、渡したコンテキストの配置が変わったことを知らせる。
  func writingToolsLayoutDidChange() {
    guard let coordinator = writingToolsCoordinator else { return }
    for id in writingTools.contexts.keys {
      coordinator.updateForReflowedTextInContextWithIdentifier(id)
    }
  }

  // MARK: - 文法の提示 (macOS 27)
  //
  // macOS 27 SDK の API は、それより前の SDK (AppKit 2700 より前) では外す。

  /// コンテキストの中で、いま文法の誤りの印を付けている誤り。範囲はコンテキストの中で数える。
  func grammarResults(for context: NSWritingToolsCoordinator.Context) -> [NSTextCheckingResult] {
    guard let record = writingTools.contexts[context.identifier] else { return [] }
    return textChecker.grammarResults(in: NSRange(location: record.start, length: record.length))
  }

  /// 本文の `range` に掛かるか接する、印を付けている文法の誤り。
  private func grammarIssues(touching range: NSRange) -> [GrammarIssue] {
    let string = layout.storage.mutableString
    let paragraph = string.paragraphRange(for: range)
    return textChecker.grammarResults(in: paragraph).flatMap { result -> [GrammarIssue] in
      let sentence = NSRange(
        location: paragraph.location + result.range.location, length: result.range.length)
      return (result.grammarDetails ?? []).compactMap { detail in
        guard let issue = (detail[NSGrammarRange] as? NSValue)?.rangeValue else { return nil }
        let target = NSRange(location: sentence.location + issue.location, length: issue.length)
        guard target.location <= NSMaxRange(range), range.location <= NSMaxRange(target) else {
          return nil
        }
        return GrammarIssue(
          sentence: string.substring(with: sentence), range: issue, documentRange: target)
      }
    }
  }

  #if canImport(AppKit, _version: 2700)
  /// 退けた文法の誤りを、スペルチェッカーに無視させ (検査し直しても印を付けない)、今の印を
  /// 外す。
  @available(macOS 27.0, *)
  private func ignoreGrammarIssues(_ issues: [GrammarIssue]) {
    let tag = textChecker.controller.spellCheckerDocumentTag
    for issue in issues {
      NSSpellChecker.shared.ignoreGrammarRange(
        issue.range, inSentence: issue.sentence, inSpellDocumentWithTag: tag)
      if NSMaxRange(issue.documentRange) <= layout.storage.length,
        textChecker.removeGrammarMarks(in: issue.documentRange)
      {
        textChecker.refreshMarks(in: issue.documentRange)
      }
    }
  }

  @available(macOS 27.0, *)
  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator,
    requestsGrammarResultsFor context: NSWritingToolsCoordinator.Context,
    completion: @escaping @Sendable ([NSTextCheckingResult]) -> Void
  ) {
    completion(grammarResults(for: context))
  }

  /// 文法の提示の画面で、利用者が文法の検査をオフにしたとき。右クリックメニューの「文法も
  /// チェック」と同じ入切を変える。
  @available(macOS 27.0, *)
  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator, setGrammarCheckingEnabled enabled: Bool
  ) {
    isGrammarCheckingEnabled = enabled
  }

  @available(macOS 27.0, *)
  func writingToolsCoordinator(
    _ writingToolsCoordinator: NSWritingToolsCoordinator,
    requestsPreviewFor textAnimation: NSWritingToolsCoordinator.TextAnimation, of range: NSRange,
    in context: NSWritingToolsCoordinator.Context,
    textDecoration: NSWritingToolsCoordinator.TextDecoration,
    completion: @escaping @Sendable ([NSTextPreview]?) -> Void
  ) {
    let marks: TextPreviewMarks = textDecoration == .grammarUnderline ? .grammarUnderline : .none
    completion(textPreview(of: range, in: context, marks: marks).map { [$0] })
  }
  #endif

  /// 新しく文法の誤りの印を付けた範囲のうち見えているものを、Writing Tools のアニメーションで
  /// 示す。示した範囲を返す。
  @discardableResult
  func grammarIssuesIndicated(_ ranges: [NSRange]) -> [NSRange] {
    #if canImport(AppKit, _version: 2700)
    var indicated: [NSRange] = []
    guard #available(macOS 27.0, *), let coordinator = writingToolsCoordinator,
      coordinator.behavior == .complete, writingTools.state == .inactive
    else { return [] }
    let string = layout.storage.mutableString
    let visible = visibleRect
    for range in ranges where NSMaxRange(range) <= string.length {
      guard viewRects(range).contains(where: { $0.intersects(visible) }) else { continue }
      let span = string.paragraphRange(for: range)
      let context = makeContext(span: span, range: range)
      let issue = NSRange(location: range.location - span.location, length: range.length)
      // アニメーションが呼び出しの中で終わることもあるので、先に示している印を付けておく。
      let id = context.identifier
      writingTools.indications[id] = UUID()
      let animation = coordinator.startTextAnimation(
        .indicateGrammar, for: issue, in: context, writingDirection: .natural)
      guard writingTools.contexts[id] != nil else {
        // 呼び出しの中で終わった。
        if animation != nil { indicated.append(range) }
        continue
      }
      if let animation {
        writingTools.indications[id] = animation
        indicated.append(range)
      } else {
        writingTools.indications[id] = nil
        writingTools.contexts[id] = nil
        writingTools.hidden.removeAll { $0.context == id }
      }
    }
    return indicated
    #else
    return []
    #endif
  }
}
