import AVFoundation
import AppKit

/// 右クリックメニューに、ほかの機能が項目を足す口。
struct ContextMenuAddition {
  enum Position {
    /// メニューの先頭。誤りの単語の候補など、クリックした位置に掛かる項目を置く。
    case top
    /// 変換の前。スペルと文法や置換のサブメニューを置く。
    case beforeTransformations
  }

  let position: Position
  let items: (ContextMenuRequest) -> [NSMenuItem]
}

/// 右クリックメニューを組み立てるときの状況。
struct ContextMenuRequest {
  /// クリックした文字のオフセット。キーボードから開いたときと、文字の無い所 (空の本文、改行で
  /// 終わらない最後の行の右、改行で終わる本文の後ろの空の行) をクリックしたときは nil。
  let clickedIndex: Int?
  /// 調べる・翻訳の対象。対象が無ければ nil。
  let lookUpRange: NSRange?
}

/// 右クリックメニュー、調べる、翻訳、共有、読み上げ、サービス、単語の変換。
///
/// 項目の並びと出し分けは、参照 NSTextView (置き換え前のエディタと同じ設定の NSTextView) が
/// `menu(for:)` で返すものに合わせる。NSTextView が private の action で出す項目のうち、調べると
/// 翻訳は公開 API (`showDefinition(for:at:)` と SwiftUI の `translationPresentation`) で代わりに
/// する。Search With Google と Report a Concern は代わりの公開 API が無いので出さない。
/// 縦書き (Layout Orientation) は扱わない。
extension EditorView: NSServicesMenuRequestor {
  // MARK: - 右クリックメニュー

  override func menu(for event: NSEvent) -> NSMenu? {
    var clicked: Int?
    let mouse = [.rightMouseDown, .leftMouseDown, .otherMouseDown].contains(event.type)
    if mouse {
      window?.makeFirstResponder(self)
      // 確定で表示が送られる前に、押した位置の文字を求める。確定は本文を変えない。
      clicked = layout.characterIndex(at: containerPoint(event))
    }
    if session.markedRange != nil {
      withoutScrolling { commitComposition() }
      inputContext?.discardMarkedText()
    }
    // 調べる対象は、クリックで選択を変える前の選択から決める。文字の無い所のクリックでは
    // 調べない。
    let lookUp = mouse && clicked == nil ? nil : lookUpRange(clickedIndex: clicked)
    if let clicked { selectForContextMenu(clickedIndex: clicked) }
    return contextMenu(for: ContextMenuRequest(clickedIndex: clicked, lookUpRange: lookUp))
  }

  /// 右クリックした文字が選択にもキャレットにも接していなければ、その文字の単語を選ぶ
  /// (NSTextView と同じ)。
  private func selectForContextMenu(clickedIndex clicked: Int) {
    // NSTextView と同じく、接しているかは文字の先頭の符号単位で決める。複数の符号単位からなる
    // 文字の直後のキャレットは、その文字に接しない。
    let touches = session.selections.contains { selection in
      let range = nsRange(of: selection.range)
      return range.location <= clicked + 1 && NSMaxRange(range) >= clicked
    }
    // NSTextView と同じく、選び直しても表示は送らない。
    if !touches { withoutScrolling { select([layout.storage.doubleClick(at: clicked)], primary: 0) } }
  }

  /// 調べる・翻訳の対象。クリックした文字を含む選択があればその選択、無ければクリックした
  /// 単語。空白だけの選択と、文字や数字を含まない単語は対象にしない。クリックの位置が無ければ
  /// 主の選択か、キャレットのある単語。
  func lookUpRange(clickedIndex clicked: Int?) -> NSRange? {
    let string = layout.storage.mutableString
    // 選択の前後の空白と改行は対象に含めない。
    func visible(_ range: NSRange) -> NSRange? {
      let content = CharacterSet.whitespacesAndNewlines.inverted
      let first = string.rangeOfCharacter(from: content, range: range)
      guard first.location != NSNotFound else { return nil }
      let last = string.rangeOfCharacter(from: content, options: .backwards, range: range)
      return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
    func word(_ range: NSRange) -> NSRange? {
      string.substring(with: range).rangeOfCharacter(from: .alphanumerics) == nil ? nil : range
    }
    let ranges = session.selections.map { nsRange(of: $0.range) }
    guard let clicked else {
      let primary = nsRange(of: session.primarySelection.range)
      return primary.length > 0 ? visible(primary) : word(wordRange(around: primary))
    }
    if let inside = ranges.first(where: { $0.location <= clicked && clicked < NSMaxRange($0) }) {
      return visible(inside)
    }
    return word(layout.storage.doubleClick(at: clicked))
  }

  /// メニューの題名に入れる、調べる・翻訳の対象の文字。前後の空白を除き、改行を空白にして、
  /// UTF-16 で 30 を超える分を省く (NSTextView と同じ)。文字の途中では切らない。
  static func menuTitleText(_ text: String) -> String {
    let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: .newlines).joined(separator: " ") as NSString
    guard flat.length > 30 else { return flat as String }
    return flat.substring(to: flat.rangeOfComposedCharacterSequence(at: 30).location) + "…"
  }

  func contextMenu(for request: ContextMenuRequest) -> NSMenu {
    let menu = NSMenu()
    // Writing Tools の項目はここで並べる。AppKit がこのビューのメニューに項目を足すかは表示の
    // 時点まで分からないので、足した場合に二重にならないよう自動の挿入は切る。
    menu.automaticallyInsertsWritingToolsItems = false
    func additions(_ position: ContextMenuAddition.Position) -> [NSMenuItem] {
      contextMenuAdditions.filter { $0.position == position }.flatMap { $0.items(request) }
    }
    var groups: [[NSMenuItem]] = [additions(.top)]
    if let range = request.lookUpRange {
      let title = Self.menuTitleText(layout.storage.mutableString.substring(with: range))
      groups.append([
        ownItem("Look Up “\(title)”", #selector(lookUpFromMenu(_:)), range: range),
        ownItem("Translate “\(title)”", #selector(translateFromMenu(_:)), range: range),
      ])
    }
    groups.append(clipboardItems())
    groups.append(shareItem().map { [$0] } ?? [])
    groups.append(writingToolsItems())
    groups.append(
      additions(.beforeTransformations) + [transformationsItem(), speechItem()].compactMap(\.self))
    for group in groups where !group.isEmpty {
      if !menu.items.isEmpty { menu.addItem(.separator()) }
      group.forEach(menu.addItem)
    }
    return menu
  }

  /// このビューが自分で扱う項目。応答連鎖を通さず、このビューに送る。
  private func ownItem(_ title: String, _ action: Selector, range: NSRange) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.representedObject = NSValue(range: range)
    return item
  }

  /// NSTextView の既定のメニューにある項目の写し。題名はシステムの言語に従う。
  func standardItem(_ action: Selector, fallback: String) -> NSMenuItem {
    let item =
      Self.findItem(in: NSTextView.defaultMenu) { $0.action == action }?.copy() as? NSMenuItem
      ?? NSMenuItem(title: fallback, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  /// NSTextView の既定のメニューで、`action` の項目を持つサブメニューの題名。
  func standardSubmenuTitle(containing action: Selector, fallback: String) -> String {
    Self.findItem(in: NSTextView.defaultMenu) { item in
      item.submenu?.items.contains { $0.action == action } == true
    }?.title ?? fallback
  }

  private static func findItem(in menu: NSMenu?, where matches: (NSMenuItem) -> Bool) -> NSMenuItem? {
    for item in menu?.items ?? [] {
      if matches(item) { return item }
      if let found = findItem(in: item.submenu, where: matches) { return found }
    }
    return nil
  }

  private func clipboardItems() -> [NSMenuItem] {
    let plain = standardItem(#selector(pasteAsPlainText(_:)), fallback: "Paste and Match Style")
    // NSTextView と同じく、⌥⇧ を押している間だけ Paste と入れ替わる。
    plain.keyEquivalent = ""
    plain.keyEquivalentModifierMask = [.option, .shift]
    plain.isAlternate = true
    return [
      standardItem(#selector(cut(_:)), fallback: "Cut"),
      standardItem(#selector(copy(_:)), fallback: "Copy"),
      standardItem(#selector(paste(_:)), fallback: "Paste"),
      plain,
    ]
  }

  /// 選択を、選択が無ければ本文全体を共有する。空白と句読点しか無ければ出さない。
  private func shareItem() -> NSMenuItem? {
    let shared = selectionOrWholeText
    let blank = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    guard shared.rangeOfCharacter(from: blank.inverted) != nil else { return nil }
    let picker = NSSharingServicePicker(items: [shared])
    sharingPicker = picker
    return picker.standardShareMenuItem
  }

  /// システムの Writing Tools の項目のうち、NSTextView が右クリックメニューに並べる 3 つ
  /// (Show Writing Tools、Proofread、Rewrite)。システムはこれらを tag 0〜2 で区別する。
  private func writingToolsItems() -> [NSMenuItem] {
    guard NSWritingToolsCoordinator.isWritingToolsAvailable else { return [] }
    let action = #selector(NSResponder.showWritingTools(_:))
    let all = NSMenuItem.writingToolsItems.flatMap { $0.submenu?.items ?? [$0] }
    return [0, 1, 2].compactMap { tag in
      all.first { $0.action == action && $0.tag == tag }?.copy() as? NSMenuItem
    }
  }

  // MARK: - 変換

  private struct Transformation {
    let action: Selector
    let fallback: String
    let apply: (String) -> String
  }

  private static let uppercase = Transformation(
    action: #selector(uppercaseWord(_:)), fallback: "Make Upper Case"
  ) { $0.uppercased() }
  private static let lowercase = Transformation(
    action: #selector(lowercaseWord(_:)), fallback: "Make Lower Case"
  ) { $0.lowercased() }
  private static let capitalize = Transformation(
    action: #selector(capitalizeWord(_:)), fallback: "Capitalize"
  ) { $0.capitalized }
  private static let fullWidth = Transformation(
    action: #selector(convertToFullWidth(_:)), fallback: "Convert to Full Width"
  ) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 }
  private static let halfWidth = Transformation(
    action: #selector(convertToHalfWidth(_:)), fallback: "Convert to Half Width"
  ) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }
  private static let traditionalChinese = Transformation(
    action: #selector(convertToTraditionalChinese(_:)), fallback: "Convert to Traditional Chinese"
  ) { $0.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? $0 }
  private static let simplifiedChinese = Transformation(
    action: #selector(convertToSimplifiedChinese(_:)), fallback: "Convert to Simplified Chinese"
  ) { $0.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? $0 }

  private static let caseTransformations = [uppercase, lowercase, capitalize]
  private static let scriptTransformations = [
    fullWidth, halfWidth, traditionalChinese, simplifiedChinese,
  ]

  /// 選択に効く変換だけを並べる。大文字・小文字は大文字と小文字の区別がある文字を含む
  /// ときだけ、全角・半角・繁体・簡体はその変換で文字が変わるときだけ出す (NSTextView と同じ)。
  private func transformationsItem() -> NSMenuItem? {
    let selected = selectedTexts.joined(separator: "\n")
    guard !selected.isEmpty else { return nil }
    let cased = selected.uppercased() != selected.lowercased()
    let applicable =
      (cased ? Self.caseTransformations : [])
      + Self.scriptTransformations.filter { $0.apply(selected) != selected }
    guard !applicable.isEmpty else { return nil }
    let submenu = NSMenu()
    for transformation in applicable {
      submenu.addItem(standardItem(transformation.action, fallback: transformation.fallback))
    }
    let item = NSMenuItem(
      title: standardSubmenuTitle(
        containing: #selector(uppercaseWord(_:)), fallback: "Transformations"),
      action: nil, keyEquivalent: "")
    item.submenu = submenu
    return item
  }

  override func uppercaseWord(_ sender: Any?) { transformWords(Self.uppercase.apply) }
  override func lowercaseWord(_ sender: Any?) { transformWords(Self.lowercase.apply) }
  override func capitalizeWord(_ sender: Any?) { transformWords(Self.capitalize.apply) }
  @objc func convertToFullWidth(_ sender: Any?) { transformWords(Self.fullWidth.apply) }
  @objc func convertToHalfWidth(_ sender: Any?) { transformWords(Self.halfWidth.apply) }
  @objc func convertToTraditionalChinese(_ sender: Any?) {
    transformWords(Self.traditionalChinese.apply)
  }
  @objc func convertToSimplifiedChinese(_ sender: Any?) {
    transformWords(Self.simplifiedChinese.apply)
  }

  /// 選択ごとに、`selectWord:` と同じく単語の境界まで広げた範囲を変換し、変換した範囲を選ぶ。
  /// 広げた範囲が重なる選択は、まとめて一度だけ変換する。
  private func transformWords(_ transform: (String) -> String) {
    let string = layout.storage.mutableString
    let ranges = session.selections.map { wordRange(around: nsRange(of: $0.range)) }
    var merged: [NSRange] = []
    for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
      if let last = merged.last, range.location < NSMaxRange(last) {
        merged[merged.count - 1] = NSUnionRange(last, range)
      } else {
        merged.append(range)
      }
    }
    guard !merged.isEmpty else { return }
    let replacements = merged.map { Replacement($0, transform(string.substring(with: $0))) }
    // 本文が空でなければ、どの選択の範囲も空にならず、まとめた範囲のどれかに入る。
    let selecting = ranges.map { range -> (anchor: Int, head: Int) in
      let index = merged.firstIndex { NSLocationInRange(range.location, $0) } ?? 0
      let start = offset(merged[index].location, after: replacements)
      return (start, start + replacements[index].length)
    }
    replace(replacements, selecting: selecting)
  }

  // MARK: - 読み上げ

  /// 共有と読み上げの対象。選択があれば選択を (複数の選択はコピーと同じく改行で繋ぐ)、
  /// 無ければ本文全体を使う (NSTextView と同じ)。
  var selectionOrWholeText: String {
    let selected = selectedTexts
    return selected.isEmpty ? text : selected.joined(separator: "\n")
  }

  private func speechItem() -> NSMenuItem {
    let submenu = NSMenu()
    submenu.addItem(standardItem(#selector(startSpeaking(_:)), fallback: "Start Speaking"))
    submenu.addItem(standardItem(#selector(stopSpeaking(_:)), fallback: "Stop Speaking"))
    let item = NSMenuItem(
      title: standardSubmenuTitle(containing: #selector(startSpeaking(_:)), fallback: "Speech"),
      action: nil, keyEquivalent: "")
    item.submenu = submenu
    return item
  }

  /// 選択を、選択が無ければ本文全体を読み上げる。
  @objc func startSpeaking(_ sender: Any?) {
    let spoken = selectionOrWholeText
    guard !spoken.isEmpty else { return }
    // 読み上げ中の音声を止めた直後に同じ音声で読み上げると、読み上げないことがある。
    // 止めたものは捨てて、新しく作る。
    speechSynthesizer?.stopSpeaking(at: .immediate)
    let synthesizer = AVSpeechSynthesizer()
    speechSynthesizer = synthesizer
    let utterance = AVSpeechUtterance(string: spoken)
    utterance.prefersAssistiveTechnologySettings = true
    synthesizer.speak(utterance)
  }

  @objc func stopSpeaking(_ sender: Any?) {
    speechSynthesizer?.stopSpeaking(at: .immediate)
  }

  // MARK: - 調べる

  @objc func lookUpFromMenu(_ sender: Any?) {
    guard let range = menuRange(sender) else { return }
    let request = definitionRequest(for: range)
    showDefinition(for: request.text, at: request.origin)
  }

  /// 強めのクリックと 3 本指のタップ。クリックした位置の単語か、それを含む選択を調べる。
  /// 位置が表示領域の外 (キーボードからの操作など) なら、主の選択かキャレットのある単語を調べる。
  override func quickLook(with event: NSEvent) {
    // 選択の上を強く押したときは、離しても選択を残す。
    dragAndDrop.pressedOnSelection = nil
    guard let request = definitionRequest(for: event) else {
      // ビューの中の文字の無い所では、何も調べない。
      if visibleRect.contains(convert(event.locationInWindow, from: nil)) { return }
      return super.quickLook(with: event)
    }
    showDefinition(for: request.text, at: request.origin)
  }

  func definitionRequest(for event: NSEvent) -> (text: NSAttributedString, origin: NSPoint)? {
    var clicked: Int?
    if visibleRect.contains(convert(event.locationInWindow, from: nil)) {
      // 右クリックと違い、文字の無い所では調べない。
      let point = containerPoint(event)
      guard let index = layout.characterIndex(at: point),
        layout.selectionRects(layout.storage.mutableString.rangeOfComposedCharacterSequence(at: index))
          .contains(where: { $0.contains(point) })
      else { return nil }
      clicked = index
    }
    guard let range = lookUpRange(clickedIndex: clicked) else { return nil }
    return definitionRequest(for: range)
  }

  /// `showDefinition(for:at:)` に渡す、範囲の文字と、その先頭のベースラインの位置 (ビューの座標)。
  func definitionRequest(for range: NSRange) -> (text: NSAttributedString, origin: NSPoint) {
    let baseline = layout.baselineOrigin(at: range.location)
    // 右から左に書く文字では、範囲の先頭の境界は右端にある。文字が並ぶ左端から重ねる。
    let x = layout.selectionRects(range).first?.minX ?? baseline.x
    return (
      layout.storage.attributedSubstring(from: range),
      NSPoint(x: x + textOrigin.x, y: baseline.y + textOrigin.y)
    )
  }

  /// メニュー項目が持つ範囲。キーバインドなど、メニュー項目以外から送られたときは nil。
  private func menuRange(_ sender: Any?) -> NSRange? {
    guard let range = ((sender as? NSMenuItem)?.representedObject as? NSValue)?.rangeValue,
      NSMaxRange(range) <= layout.storage.length
    else { return nil }
    return range
  }

  // MARK: - 翻訳

  @objc func translateFromMenu(_ sender: Any?) {
    guard let range = menuRange(sender) else { return }
    presentTranslation(for: range)
  }

  /// 範囲の文字を、システムの翻訳のポップオーバーで見せる。ポップオーバーは範囲の上に置いた
  /// 透明なビューから出す。訳文で置き換えると、取り消せる編集として範囲を置き換える。
  ///
  /// 翻訳を頼むたびに、ポップオーバーを出すビューを作り直す。前のビューを外すと前の翻訳も閉じ、
  /// 前の訳文で新しい範囲を置き換えることが無い。
  func presentTranslation(for range: NSRange) {
    let rects = layout.selectionRects(range)
    guard let first = rects.first else { return }
    translationAnchor?.removeFromSuperview()
    let request = TranslationRequest()
    translation = request
    let anchor = TranslationAnchorView(request: request)
    anchor.frame = rects.dropFirst().reduce(first) { $0.union($1) }
      .offsetBy(dx: textOrigin.x, dy: textOrigin.y)
    addSubview(anchor)
    translationAnchor = anchor
    request.text = layout.storage.mutableString.substring(with: range)
    let version = textVersion
    request.replace = { [weak self] translated in
      self?.replaceTranslated(range, version: version, with: translated)
    }
    request.isPresented = true
  }

  /// 訳を出した後に本文が変わっていたら、範囲がどの文字を指すか分からないので置き換えない。
  func replaceTranslated(_ range: NSRange, version: Int, with translated: String) {
    guard version == textVersion, NSMaxRange(range) <= layout.storage.length else {
      return NSSound.beep()
    }
    let replacement = Replacement(range, Self.normalizingLineEndings(translated))
    replace([replacement], selecting: selections(after: [replacement]))
  }

  // MARK: - 書式なしのペースト

  /// 本文はもともと書式を持たないので、ペーストと同じ。
  @objc func pasteAsPlainText(_ sender: Any?) { paste(from: .general) }

  // MARK: - サービス

  /// NSTextView がサービスの送受信に使う、旧来の名前の文字列の型。
  static let legacyStringType = NSPasteboard.PasteboardType("NSStringPboardType")
  /// アプリの起動時にサービスへ登録する型。このビューが応答するのは旧来の名前だけだが、
  /// システムが問い合わせに使う型の一覧に両方の名前を入れておく。
  static let serviceTypes: [NSPasteboard.PasteboardType] = [.string, legacyStringType]

  /// 文字列の型でだけ応答する。選択が無ければ受け取りだけに応答する。NSTextView と同じく、
  /// 文字列の型は旧来の名前 (`NSStringPboardType`) でだけ受け付け、UTI では受け付けない。
  /// どちらの型も無い問い合わせには応答する (NSTextView と同じ)。
  override func validRequestor(
    forSendType sendType: NSPasteboard.PasteboardType?,
    returnType: NSPasteboard.PasteboardType?
  ) -> Any? {
    let hasSelection = session.selections.contains { !$0.isEmpty }
    let sends = sendType.map { $0 == Self.legacyStringType && hasSelection } ?? true
    let returns = returnType.map { $0 == Self.legacyStringType } ?? true
    if sends, returns { return self }
    return super.validRequestor(forSendType: sendType, returnType: returnType)
  }

  /// コピーと同じく、複数の選択は改行で繋いで書き出す。
  func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    guard types.contains(where: Self.serviceTypes.contains), !selectedTexts.isEmpty else {
      return false
    }
    writeSelection(to: pboard)
    return true
  }

  /// 受け取った文字列で、送り出した選択 (範囲を選んでいる選択) を置き換え、その後ろにキャレット
  /// を置く。一回で取り消せる。範囲を選んでいる選択が無ければ、主のキャレットの位置に入れる。
  ///
  /// 複数の選択から送り出したときは改行で繋いでいるので、どの選択も改行を含まず、受け取った
  /// 行の数が揃えば、一行ずつ元の選択に戻す (末尾に足された改行は数えない)。揃わなければ、どの行がどの選択の分か分からない
  /// ので、主の選択 (主が範囲を選んでいなければ最初の選択) だけを置き換え、ほかの選択の文字は
  /// 消さずに残す。
  func readSelection(from pboard: NSPasteboard) -> Bool {
    guard let pasted = Self.plainText(from: pboard) else { return false }
    let string = Self.normalizingLineEndings(pasted)
    let ranges = session.selections.map { nsRange(of: $0.range) }
    let sent = ranges.indices.filter { ranges[$0].length > 0 }
      .sorted { ranges[$0].location < ranges[$1].location }
    // 改行を含む選択があると、行と選択の対応が決まらない。
    let text = layout.storage.mutableString
    let singleLines = sent.allSatisfy {
      text.substring(with: ranges[$0]).rangeOfCharacter(from: .newlines) == nil
    }
    var lines = string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.count > 1, lines.last == "" { lines.removeLast() }
    let texts: [(index: Int, text: String)] =
      if sent.isEmpty {
        [(session.primaryIndex, string)]
      } else if sent.count > 1, singleLines, lines.count == sent.count {
        Array(zip(sent, lines))
      } else {
        [(sent.contains(session.primaryIndex) ? session.primaryIndex : sent[0], string)]
      }
    let helper = smartInsertDeleteEnabled && pboard.types?.contains(Self.smartPasteType) == true
      ? inputReference() : nil
    let replacements = texts.map { item in
      let range = ranges[item.index]
      var before: NSString?
      var after: NSString?
      helper?.smartInsert(for: item.text, replacing: range, before: &before, after: &after)
      return Replacement(range, (before as String? ?? "") + item.text + (after as String? ?? ""))
    }
    let replaced = Dictionary(uniqueKeysWithValues: zip(texts.map(\.index), replacements))
    let selecting = session.selections.indices.map { index -> (anchor: Int, head: Int) in
      if let replacement = replaced[index] {
        let caret = offset(NSMaxRange(replacement.range), after: replacements)
        return (caret, caret)
      }
      let selection = session.selections[index]
      return (
        offset(offset(of: selection.anchor), after: replacements),
        offset(offset(of: selection.head), after: replacements)
      )
    }
    return replace(replacements, selecting: selecting)
  }
}
