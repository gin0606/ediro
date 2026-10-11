import AppKit
import EditorEngine

/// スペルと文法の検査と自動置換の入切。どれもその起動の間だけ持ち、保存しない。
///
/// 既定値は置き換え前のエディタ (NSTextView) に合わせる。入力中のスペルチェックと、引用符・
/// ダッシュ・テキスト置換は、旧版が起動のたびにオフにしていたのでオフ。ほかは NSTextView の
/// 既定値で、自動スペル修正はシステム設定に従う。
struct TextCheckingSettings: Equatable {
  var continuousSpellChecking = false
  /// 文法の誤りも検査する。検査するのは入力中のスペルチェックがオンのときだけ (NSTextView と同じ)。
  var grammarChecking = true
  var automaticSpellingCorrection = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
  var smartInsertDelete = true
  var quoteSubstitution = false
  var dashSubstitution = false
  var linkDetection = false
  var dataDetection = false
  var textReplacement = false
}

/// AppKit の NSTextCheckingController にエディタの本文を検査させる。スペルと文法の誤りの印、
/// 誤りの単語の候補、引用符・ダッシュ・テキスト置換の自動置換は、このコントローラが行う。
///
/// 検査の印 (誤りの単語の `NSSpellingState` など) は、本文の写し (NSTextStorage) の属性ではなく、
/// 本文と同じ文字列を持つ別の属性付き文字列 `annotations` に持つ。写しの属性は Markdown の装飾が
/// 当て直すので、そこに持つと装飾のたびに消える。下線は TextKit 2 の rendering attribute で描く。
///
/// 自動スペル修正、スマートコピー/ペースト、スマートリンク、データ検出は入切の値だけを持ち、
/// コントローラには常にオフと伝える。入力への効果は持たない。
///
/// NSTextCheckingClient は NSView が別の意味で持つ `candidateListTouchBarItem` を要求し、Swift の
/// NSView の派生型では採用できない。そのため、ビューとは別のこの型がクライアントになる。
final class TextChecker: NSObject {
  private weak var view: EditorView?
  private(set) var controller: NSTextCheckingController!
  /// 本文と同じ文字列に、コントローラが付けた注釈 (値はどれも文字列) だけを持つ。
  private(set) var annotations = NSMutableAttributedString()
  var settings = TextCheckingSettings()
  /// コントローラが本文を書き換えている間は、その変更をコントローラに知らせ直さない。
  private var isReplacing = false
  /// 誤りの印を rendering attribute として付けているか。付けていなければ外す手間を省く。
  private var hasRenderedMarks = false
  /// 一度の検査の結果で行う置き換えを、まとめて一回で取り消せるようにする履歴の名前。
  /// コントローラは一度の検査の結果を続けて置き換えるので、メインキューの同じ周回で行った
  /// 置き換えを同じ名前にする (NSTextView と同じく、一回の取り消しでまとめて戻る)。
  private var replacementGroup: String?
  private var replacementCount = 0
  /// 打鍵以外で入った文字 (貼り付け、確定した変換、引用符の置換を通さないコマンド、取り消し
  /// など) のオフセット。コントローラは打鍵した文字の前後も見て自動置換するので、これらの
  /// 文字に掛かる自動置換は当てない (NSTextView は打鍵した文字だけを置き換える)。
  private var untyped = IndexSet()
  /// 打鍵以外の編集で変わり、スペルと文法を検査し直す文字。コントローラは変更を知らされたのと
  /// 同じメインキューの周回で頼まれた検査を捨てるので、次の周回でまとめて検査する。
  private var pendingChecks = IndexSet()
  /// 利用者が置き換えを頼んだ範囲 (置換のパネルの「すべてを置換」など)。打鍵した文字でなくても
  /// 自動置換の結果を当てる。次に利用者が本文を編集するまで持つ。
  private var requested = IndexSet()
  /// 利用者が頼んだ文書の検査 (`checkSpelling:`) の印は、入力中の検査がオフでも付ける。入切を
  /// 変えるまで持つ。
  var allowsRequestedMarks = false
  private var isCheckScheduled = false

  init(view: EditorView) {
    self.view = view
    super.init()
    controller = NSTextCheckingController(client: self)
  }

  /// コントローラはクライアントを保持しないので、先に消えるクライアントへ呼び出さないよう切り離す。
  isolated deinit {
    let tag = controller.spellCheckerDocumentTag
    controller.invalidate()
    NSSpellChecker.shared.closeSpellDocument(withTag: tag)
  }

  /// 本文を差し替えたときに、注釈を捨てて作り直す。無視した単語を覚えておくため、スペル
  /// チェッカーの文書の番号は引き継ぐ。
  func reset(text: String) {
    let tag = controller.spellCheckerDocumentTag
    controller.invalidate()
    annotations = NSMutableAttributedString(string: text)
    untyped = IndexSet(integersIn: 0..<annotations.length)
    pendingChecks = IndexSet()
    requested = IndexSet()
    allowsRequestedMarks = false
    controller = NSTextCheckingController(client: self)
    NSSpellChecker.shared.closeSpellDocument(withTag: controller.spellCheckerDocumentTag)
    controller.spellCheckerDocumentTag = tag
    refreshMarks()
    checkSpelling(in: NSRange(location: 0, length: annotations.length))
  }

  // MARK: - 本文の変更

  /// エンジンが通知した一つの差分を注釈の文字列に当て、変わった範囲をコントローラに知らせる。
  /// 差分のオフセットはその差分を当てる直前の本文で数える。`typed` は打鍵で入った文字か。
  /// 返すのは当てた後の本文での、入った文字の範囲。
  @discardableResult
  func apply(_ batch: [ContentChange], typed: Bool) -> [NSRange] {
    // 入った文字は前の文字の注釈を引き継がない。誤りの印が隣の文字へ広がらないようにする。
    for change in batch.reversed() {
      let length = (change.insertedText as NSString).length
      annotations.replaceCharacters(
        in: NSRange(location: change.offset, length: change.removedLength),
        with: NSAttributedString(string: change.insertedText))
      for indices in [\TextChecker.untyped, \TextChecker.pendingChecks, \TextChecker.requested] {
        self[keyPath: indices].remove(integersIn: change.offset..<change.offset + change.removedLength)
        self[keyPath: indices].shift(
          startingAt: change.offset + change.removedLength, by: length - change.removedLength)
      }
      if !typed { untyped.insert(integersIn: change.offset..<change.offset + length) }
    }
    var delta = 0
    let ranges = batch.map { change -> NSRange in
      let length = (change.insertedText as NSString).length
      defer { delta += length - change.removedLength }
      return NSRange(location: change.offset + delta, length: length)
    }
    if !isReplacing {
      requested = IndexSet()
      for range in ranges { controller.didChangeText(in: range) }
    }
    return ranges
  }

  /// 利用者が置き換えを頼んだ範囲は、打鍵した文字でなくても自動置換の結果を当てる。
  func allowSubstitutions(in range: NSRange) {
    requested.insert(integersIn: range.location..<NSMaxRange(range))
  }

  /// 打鍵で入った文字の範囲。コントローラに自動置換と入力中の検査をさせる。
  func insertedText(in ranges: [NSRange]) {
    // 入力中の検査がオフなら、文書の検査で付けた印を編集した段落から外すだけにする。
    if !settings.continuousSpellChecking { ranges.forEach(checkSpelling(in:)) }
    for range in ranges where range.length > 0 {
      controller.insertedText(in: range)
      controller.considerTextChecking(for: range)
    }
  }

  /// 打鍵以外の編集 (貼り付けや取り消しなど) で変わった範囲を、入力中の検査がオンならスペル
  /// と文法だけ検査し直す。NSTextView と同じく、打鍵以外で入った文字は自動置換しない。
  /// 検査は次のメインキューの周回で、範囲を含む段落ごとに行う。
  func checkSpelling(in range: NSRange) {
    let length = annotations.length
    guard length > 0 else { return }
    // 文字を消しただけの変更は、消した位置の文字を含む段落を検査する。入った文字が改行で
    // 終わるときは、その後ろの段落も検査する。
    let location = min(range.location, length - 1)
    let end = min(NSMaxRange(range) + 1, length)
    guard settings.continuousSpellChecking else {
      // 入力中の検査がオフのときに文書の検査で付けた印は、検査し直さないので、編集した文字に
      // 掛かる印だけを外す。
      removeMarks(touching: NSRange(location: max(range.location - 1, 0), length: end - max(range.location - 1, 0)))
      return
    }
    pendingChecks.insert(integersIn: location..<max(end, location + 1))
    guard !isCheckScheduled else { return }
    isCheckScheduled = true
    DispatchQueue.main.async { [weak self] in self?.performPendingChecks() }
  }

  /// `range` の文字に掛かる誤りの印を、その印の範囲ごと外す。
  private func removeMarks(touching range: NSRange) {
    let full = NSRange(location: 0, length: annotations.length)
    let clamped = NSIntersectionRange(range, full)
    guard clamped.length > 0 else { return }
    var marked: [NSRange] = []
    annotations.enumerateAttribute(.spellingState, in: clamped) { value, run, _ in
      guard value != nil else { return }
      var effective = NSRange()
      _ = annotations.attribute(
        .spellingState, at: run.location, longestEffectiveRange: &effective, in: full)
      marked.append(effective)
    }
    guard !marked.isEmpty else { return }
    let keys = markKeys
    for mark in marked {
      for key in keys { annotations.removeAttribute(key, range: mark) }
      refreshMarks(in: mark)
    }
  }

  private func performPendingChecks() {
    isCheckScheduled = false
    let pending = pendingChecks
    pendingChecks = IndexSet()
    guard settings.continuousSpellChecking, let view else { return }
    let string = annotations.mutableString as NSString
    var paragraphs = IndexSet()
    for range in pending.rangeView where range.upperBound <= string.length {
      let paragraph = string.paragraphRange(for: NSRange(range))
      paragraphs.insert(integersIn: paragraph.location..<NSMaxRange(paragraph))
    }
    // 変換中の文字の段落は検査しない (NSTextView と同じ)。確定するときに検査し直す。
    for marked in view.session.markedRanges.map(view.nsRange(of:)) {
      let paragraph = string.paragraphRange(for: marked)
      paragraphs.remove(integersIn: paragraph.location..<NSMaxRange(paragraph))
    }
    for paragraph in paragraphs.rangeView {
      controller.checkText(in: NSRange(paragraph), types: spellingTypes, options: [:])
    }
  }

  private var spellingTypes: NSTextCheckingTypes {
    NSTextCheckingResult.CheckingType.spelling.rawValue
      | (settings.grammarChecking ? NSTextCheckingResult.CheckingType.grammar.rawValue : 0)
  }

  // MARK: - 入切

  /// 入力中の検査の入切を変えたら、今の印を消し、オンなら本文全体を検査し直す。
  func continuousCheckingDidChange() {
    allowsRequestedMarks = false
    let full = NSRange(location: 0, length: annotations.length)
    for key in markKeys { annotations.removeAttribute(key, range: full) }
    refreshMarks()
    checkSpelling(in: full)
  }

  /// 文法の検査の入切を変えたら、オフなら文法の印だけを消す。入力中の検査がオンなら本文全体を
  /// 検査し直す。
  /// スペルの印は残す (NSTextView と同じ)。
  func grammarCheckingDidChange() {
    let full = NSRange(location: 0, length: annotations.length)
    if !settings.grammarChecking {
      let grammar = NSAttributedString.SpellingState.grammar.rawValue
      let grammarKeys = markKeys.filter { $0.rawValue.contains("Grammar") }
      var runs: [(NSRange, Int)] = []
      annotations.enumerateAttribute(.spellingState, in: full) { value, run, _ in
        guard let state = (value as? String).flatMap(Int.init), state & grammar != 0 else { return }
        runs.append((run, state & ~grammar))
      }
      for (run, state) in runs {
        for key in grammarKeys { annotations.removeAttribute(key, range: run) }
        if state & NSAttributedString.SpellingState.spelling.rawValue == 0 {
          for key in markKeys { annotations.removeAttribute(key, range: run) }
        } else {
          annotations.addAttribute(.spellingState, value: String(state), range: run)
        }
      }
      refreshMarks()
    }
    if settings.continuousSpellChecking { checkSpelling(in: full) }
  }

  /// 入切をオフにした後に届いた、オフにする前に頼んだ検査の結果の印を捨てる。
  private func allowed(_ annotations: [NSAttributedString.Key: String]) -> [NSAttributedString.Key: String] {
    let grammar = NSAttributedString.SpellingState.grammar.rawValue
    guard let state = annotations[.spellingState].flatMap(Int.init) else { return annotations }
    var kept = state
    if !settings.continuousSpellChecking, !allowsRequestedMarks { kept = 0 }
    if !settings.grammarChecking { kept &= ~grammar }
    guard kept != state else { return annotations }
    // 文法の印を外すときは、文法の誤りの詳細も外す。
    let keys = Set(markKeys).subtracting(kept != 0 ? [.spellingState] : [])
    var result = annotations.filter { !keys.contains($0.key) }
    if kept != 0 { result[.spellingState] = String(kept) }
    return result
  }

  /// 誤りの印に関わる注釈。`NSSpellingState` と、文法の誤りの詳細を持つ注釈。
  private var markKeys: [NSAttributedString.Key] {
    let keys = Set(controller.validAnnotations() + [NSAttributedString.Key.spellingState])
    return keys.filter {
      $0 == .spellingState || $0.rawValue.contains("SpellingState")
        || $0.rawValue.contains("Grammar")
    }
  }

  // MARK: - 誤りの下線

  /// 注釈の `NSSpellingState` を、`range` を含む段落 (nil なら本文全体) について TextKit 2 の
  /// rendering attribute に写す。rendering attribute は本文の写しの編集に合わせて注釈と同じ
  /// ようにずれるので、注釈が変わった所だけ写せばよい。
  func refreshMarks(in range: NSRange? = nil) {
    guard let layout = view?.layout, layout.storage.length == annotations.length else { return }
    let full = NSRange(location: 0, length: annotations.length)
    var target = full
    if let range {
      let location = min(range.location, full.length)
      target = (annotations.mutableString as NSString).paragraphRange(
        for: NSRange(location: location, length: min(range.length, full.length - location)))
    }
    var marks: [(NSRange, Int)] = []
    let states = NSAttributedString.SpellingState.spelling.rawValue
      | NSAttributedString.SpellingState.grammar.rawValue
    annotations.enumerateAttribute(.spellingState, in: target) { value, range, _ in
      guard let state = (value as? String).flatMap(Int.init), state & states != 0 else { return }
      marks.append((range, state & states))
    }
    guard hasRenderedMarks || !marks.isEmpty, let textRange = layout.textRange(target) else {
      return
    }
    let manager = layout.layoutManager
    manager.removeRenderingAttribute(.spellingState, for: textRange)
    for (range, state) in marks {
      guard let textRange = layout.textRange(range) else { continue }
      manager.addRenderingAttribute(.spellingState, value: state, for: textRange)
    }
    hasRenderedMarks = hasRenderedMarks || !marks.isEmpty
    view?.needsDisplay = true
  }

  /// 注釈の範囲を、標準の範囲の調整 (NSTextCheckingClient の説明) に従って本文の中に収める。
  /// 範囲が本文に全く掛からなければ nil。
  private func adjusted(_ range: NSRange) -> NSRange? {
    let length = annotations.length
    if range.location == NSNotFound { return NSRange(location: 0, length: length) }
    guard range.location <= length else { return nil }
    return NSRange(location: range.location, length: min(range.length, length - range.location))
  }
}

// MARK: - NSTextCheckingClient

extension TextChecker: NSTextCheckingClient {
  func annotatedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard let clamped = adjusted(range) else { return nil }
    let paragraphs = (annotations.mutableString as NSString).paragraphRange(for: clamped)
    actualRange?.pointee = paragraphs
    return annotations.attributedSubstring(from: paragraphs)
  }

  func setAnnotations(_ annotations: [NSAttributedString.Key: String], range: NSRange) {
    guard let range = adjusted(range), range.length > 0 else { return }
    self.annotations.setAttributes(allowed(annotations), range: range)
    refreshMarks(in: range)
  }

  func addAnnotations(_ annotations: [NSAttributedString.Key: String], range: NSRange) {
    guard let range = adjusted(range), range.length > 0 else { return }
    self.annotations.addAttributes(allowed(annotations), range: range)
    refreshMarks(in: range)
  }

  func removeAnnotation(_ annotationName: NSAttributedString.Key, range: NSRange) {
    guard let range = adjusted(range), range.length > 0 else { return }
    annotations.removeAttribute(annotationName, range: range)
    refreshMarks(in: range)
  }

  /// 候補での置き換えと自動置換。エンジン経由で一回の取り消し単位として置き換える。変換中は
  /// 本文を書き換えられないので、何もしない。
  func replaceCharacters(in range: NSRange, withAnnotatedString annotatedString: NSAttributedString) {
    guard let view, !view.hasMarkedText(), let range = adjusted(range) else { return }
    // 自動置換の結果は、置き換える前の文字を `NSReplacedString` に持つ。候補での置き換えは持たない。
    let substitution =
      annotatedString.length > 0
      && annotatedString.attribute(Self.replacedString, at: 0, effectiveRange: nil) != nil
    // 打鍵した文字を一つも含まない範囲の自動置換は、置き換えを頼まれた範囲でなければ当てない。
    // 文字を入れるだけの置き換えは、その前の文字で判断する。
    let characters =
      range.length > 0
      ? range.location..<NSMaxRange(range) : max(range.location - 1, 0)..<range.location
    if substitution, untyped.contains(integersIn: characters),
      !requested.contains(integersIn: characters)
    {
      return
    }
    // エンジンは改行を LF に揃えて入れる。揃えた後の長さで選択と注釈の位置を求める。
    let text = EditorView.normalizingLineEndings(annotatedString.string)
    let replacement = EditorView.Replacement(range, text)
    let selecting = view.session.selections.map { selection -> (anchor: Int, head: Int) in
      (
        view.offset(view.offset(of: selection.anchor), after: [replacement]),
        view.offset(view.offset(of: selection.head), after: [replacement])
      )
    }
    isReplacing = true
    let replaced = view.replace(
      [replacement], selecting: selecting, historyGroup: currentReplacementGroup())
    isReplacing = false
    guard replaced else { return }
    let inserted = NSRange(location: range.location, length: replacement.length)
    annotations.setAttributes(nil, range: inserted)
    // 改行を揃えて文字が変わったときは、注釈の位置が合わないので写さない。
    if text == annotatedString.string {
      annotatedString.enumerateAttributes(
        in: NSRange(location: 0, length: min(annotatedString.length, inserted.length))
      ) { attributes, run, _ in
        let strings = attributes.compactMapValues { $0 as? String }
        annotations.addAttributes(
          allowed(strings),
          range: NSRange(location: inserted.location + run.location, length: run.length))
      }
    }
    refreshMarks(in: inserted)
  }

  static let replacedString = NSAttributedString.Key("NSReplacedString")

  private func currentReplacementGroup() -> String {
    if let replacementGroup { return replacementGroup }
    replacementCount += 1
    let group = "text-checking-\(replacementCount)"
    replacementGroup = group
    DispatchQueue.main.async { [weak self] in self?.replacementGroup = nil }
    return group
  }

  func selectAndShow(_ range: NSRange) {
    guard let view, let range = adjusted(range) else { return }
    view.select([range], primary: 0)
    view.scrollToVisible(view.firstRectInView(for: range))
  }

  func view(for range: NSRange, firstRect: NSRectPointer?, actualRange: NSRangePointer?) -> NSView? {
    guard let view, let range = adjusted(range) else { return nil }
    firstRect?.pointee = view.firstRectInView(for: range)
    actualRange?.pointee = range
    return view
  }

  func candidateListTouchBarItem() -> NSCandidateListTouchBarItem<AnyObject>? { nil }

  // NSTextInputTraits: 効果を実装した検査と置換だけを伝え、ほかはオフと伝える。置換のパネル
  // (Show Substitutions) で変えた値は、メニューの入切と同じ値に入れる。

  private func trait(_ enabled: Bool) -> NSTextInputTraitType { enabled ? .yes : .no }

  /// `.yes` か `.no` を受けたら `body` に入切を渡す。`.default` は無視する。
  private func update(_ trait: NSTextInputTraitType, _ body: (EditorView, Bool) -> Void) {
    guard let view, trait != .default else { return }
    body(view, trait == .yes)
  }

  var spellCheckingType: NSTextInputTraitType {
    get { trait(settings.continuousSpellChecking) }
    set { update(newValue) { $0.isContinuousSpellCheckingEnabled = $1 } }
  }
  var grammarCheckingType: NSTextInputTraitType {
    get { trait(settings.continuousSpellChecking && settings.grammarChecking) }
    set { update(newValue) { $0.isGrammarCheckingEnabled = $1 } }
  }
  var smartQuotesType: NSTextInputTraitType {
    get { trait(settings.quoteSubstitution) }
    set { update(newValue) { $0.isAutomaticQuoteSubstitutionEnabled = $1 } }
  }
  var smartDashesType: NSTextInputTraitType {
    get { trait(settings.dashSubstitution) }
    set { update(newValue) { $0.isAutomaticDashSubstitutionEnabled = $1 } }
  }
  var textReplacementType: NSTextInputTraitType {
    get { trait(settings.textReplacement) }
    set { update(newValue) { $0.isAutomaticTextReplacementEnabled = $1 } }
  }
  var autocorrectionType: NSTextInputTraitType {
    get { .no }
    set { update(newValue) { $0.isAutomaticSpellingCorrectionEnabled = $1 } }
  }
  var smartInsertDeleteType: NSTextInputTraitType {
    get { .no }
    set { update(newValue) { $0.smartInsertDeleteEnabled = $1 } }
  }
  var dataDetectionType: NSTextInputTraitType {
    get { .no }
    set { update(newValue) { $0.isAutomaticDataDetectionEnabled = $1 } }
  }
  var linkDetectionType: NSTextInputTraitType {
    get { .no }
    set { update(newValue) { $0.isAutomaticLinkDetectionEnabled = $1 } }
  }
  /// テキスト補完は、この型が入切を持たない。
  var textCompletionType: NSTextInputTraitType {
    get { .no }
    set {}
  }

  // NSTextInputClient: コントローラが本文と選択を読むために使う。ビューに回す。

  func insertText(_ string: Any, replacementRange: NSRange) {
    view?.insertText(string, replacementRange: replacementRange)
  }

  func doCommand(by selector: Selector) { view?.doCommand(by: selector) }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    view?.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
  }

  func unmarkText() { view?.unmarkText() }

  func selectedRange() -> NSRange {
    view?.selectedRange() ?? NSRange(location: NSNotFound, length: 0)
  }

  func markedRange() -> NSRange {
    view?.markedRange() ?? NSRange(location: NSNotFound, length: 0)
  }

  func hasMarkedText() -> Bool { view?.hasMarkedText() ?? false }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    view?.attributedSubstring(forProposedRange: range, actualRange: actualRange)
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    view?.firstRect(forCharacterRange: range, actualRange: actualRange) ?? .zero
  }

  func characterIndex(for point: NSPoint) -> Int {
    view?.characterIndex(for: point) ?? NSNotFound
  }
}
