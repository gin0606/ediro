import AppKit

/// スペルと文法の検査、自動置換の入切、それらの右クリックメニュー。
///
/// 検査と置換そのものは `TextChecker` が NSTextCheckingController に任せる。入切の名前と
/// メニューの項目は NSTextView に合わせる。
extension EditorView: NSChangeSpelling, NSIgnoreMisspelledWords {
  // MARK: - 入切

  var isContinuousSpellCheckingEnabled: Bool {
    get { textChecker.settings.continuousSpellChecking }
    set {
      guard newValue != isContinuousSpellCheckingEnabled else { return }
      textChecker.settings.continuousSpellChecking = newValue
      textChecker.continuousCheckingDidChange()
      // 文法の誤りを示している途中のアニメーションも取りやめる。
      if !newValue { cancelGrammarIndications(Array(writingTools.indications.keys)) }
    }
  }

  /// 文法の誤りも検査するか。
  var isGrammarCheckingEnabled: Bool {
    get { textChecker.settings.grammarChecking }
    set {
      guard newValue != isGrammarCheckingEnabled else { return }
      textChecker.settings.grammarChecking = newValue
      textChecker.grammarCheckingDidChange()
      // 文法の誤りを示している途中のアニメーションも取りやめる。
      if !newValue { cancelGrammarIndications(Array(writingTools.indications.keys)) }
    }
  }

  var isAutomaticSpellingCorrectionEnabled: Bool {
    get { textChecker.settings.automaticSpellingCorrection }
    set { textChecker.settings.automaticSpellingCorrection = newValue }
  }

  var smartInsertDeleteEnabled: Bool {
    get { textChecker.settings.smartInsertDelete }
    set { textChecker.settings.smartInsertDelete = newValue }
  }

  var isAutomaticQuoteSubstitutionEnabled: Bool {
    get { textChecker.settings.quoteSubstitution }
    set { textChecker.settings.quoteSubstitution = newValue }
  }

  var isAutomaticDashSubstitutionEnabled: Bool {
    get { textChecker.settings.dashSubstitution }
    set { textChecker.settings.dashSubstitution = newValue }
  }

  var isAutomaticLinkDetectionEnabled: Bool {
    get { textChecker.settings.linkDetection }
    set { textChecker.settings.linkDetection = newValue }
  }

  var isAutomaticDataDetectionEnabled: Bool {
    get { textChecker.settings.dataDetection }
    set { textChecker.settings.dataDetection = newValue }
  }

  var isAutomaticTextReplacementEnabled: Bool {
    get { textChecker.settings.textReplacement }
    set { textChecker.settings.textReplacement = newValue }
  }

  @objc func toggleContinuousSpellChecking(_ sender: Any?) {
    isContinuousSpellCheckingEnabled.toggle()
  }
  @objc func toggleGrammarChecking(_ sender: Any?) { isGrammarCheckingEnabled.toggle() }
  @objc func toggleAutomaticSpellingCorrection(_ sender: Any?) {
    isAutomaticSpellingCorrectionEnabled.toggle()
  }
  @objc func toggleSmartInsertDelete(_ sender: Any?) { smartInsertDeleteEnabled.toggle() }
  @objc func toggleAutomaticQuoteSubstitution(_ sender: Any?) {
    isAutomaticQuoteSubstitutionEnabled.toggle()
  }
  @objc func toggleAutomaticDashSubstitution(_ sender: Any?) {
    isAutomaticDashSubstitutionEnabled.toggle()
  }
  @objc func toggleAutomaticLinkDetection(_ sender: Any?) {
    isAutomaticLinkDetectionEnabled.toggle()
  }
  @objc func toggleAutomaticDataDetection(_ sender: Any?) {
    isAutomaticDataDetectionEnabled.toggle()
  }
  @objc func toggleAutomaticTextReplacement(_ sender: Any?) {
    isAutomaticTextReplacementEnabled.toggle()
  }

  /// 入切の項目と、その値。メニューの検証でチェック印を付ける。
  var textCheckingToggles: [Selector: Bool] {
    [
      #selector(toggleContinuousSpellChecking(_:)): isContinuousSpellCheckingEnabled,
      #selector(toggleGrammarChecking(_:)): isGrammarCheckingEnabled,
      #selector(toggleAutomaticSpellingCorrection(_:)): isAutomaticSpellingCorrectionEnabled,
      #selector(toggleSmartInsertDelete(_:)): smartInsertDeleteEnabled,
      #selector(toggleAutomaticQuoteSubstitution(_:)): isAutomaticQuoteSubstitutionEnabled,
      #selector(toggleAutomaticDashSubstitution(_:)): isAutomaticDashSubstitutionEnabled,
      #selector(toggleAutomaticLinkDetection(_:)): isAutomaticLinkDetectionEnabled,
      #selector(toggleAutomaticDataDetection(_:)): isAutomaticDataDetectionEnabled,
      #selector(toggleAutomaticTextReplacement(_:)): isAutomaticTextReplacementEnabled,
    ]
  }

  // MARK: - スペルパネルと検査のコマンド

  /// スペルパネルの「変更」と、誤りの単語の候補。送り手の `selectedCell` の文字で選択を置き換える。
  @objc func changeSpelling(_ sender: Any?) { textChecker.controller.changeSpelling(sender) }
  /// スペルパネルの「無視」。送り手の `selectedCell` の単語を、この文書では誤りとしない。
  @objc func ignoreSpelling(_ sender: Any?) { textChecker.controller.ignoreSpelling(sender) }
  @objc func showGuessPanel(_ sender: Any?) { textChecker.controller.showGuessPanel(sender) }
  /// 選択の後ろの次の誤りを選び、スペルパネルに出す。
  @objc func checkSpelling(_ sender: Any?) {
    textChecker.allowsRequestedMarks = true
    textChecker.controller.checkSpelling(sender)
  }
  /// 置換のパネルの「すべてを置換」などから送られる。頼まれた範囲は、打鍵した文字でなくても
  /// 置き換える。
  @objc func checkTextInDocument(_ sender: Any?) {
    textChecker.allowSubstitutions(in: NSRange(location: 0, length: layout.storage.length))
    textChecker.controller.checkTextInDocument(sender)
  }
  @objc func checkTextInSelection(_ sender: Any?) {
    // コントローラは主の選択だけを検査する。
    textChecker.allowSubstitutions(in: nsRange(of: session.primarySelection.range))
    textChecker.controller.checkTextInSelection(sender)
  }
  @objc func orderFrontSubstitutionsPanel(_ sender: Any?) {
    textChecker.controller.orderFrontSubstitutionsPanel(sender)
  }

  /// 選択の中の引用符・ダッシュ・テキストを、自動置換の入切によらず置き換える。どの選択の
  /// 分もまとめて一回で取り消せる。置き換えの規則はスペルチェッカーに任せる。
  @objc func replaceQuotesInSelection(_ sender: Any?) { replaceInSelection(.quote) }
  @objc func replaceDashesInSelection(_ sender: Any?) { replaceInSelection(.dash) }
  @objc func replaceTextInSelection(_ sender: Any?) { replaceInSelection(.replacement) }

  private func replaceInSelection(_ type: NSTextCheckingResult.CheckingType) {
    guard !hasMarkedText() else { return NSSound.beep() }
    let text = self.text
    let tag = textChecker.controller.spellCheckerDocumentTag
    let ranges = session.selections.map { nsRange(of: $0.range) }.filter { $0.length > 0 }
      .sorted { $0.location < $1.location }
    var replacements: [Replacement] = []
    for range in ranges {
      let results = NSSpellChecker.shared.check(
        text, range: range, types: type.rawValue, options: nil, inSpellDocumentWithTag: tag,
        orthography: nil, wordCount: nil)
      for result in results.sorted(by: { $0.range.location < $1.range.location }) {
        guard result.resultType == type, let string = result.replacementString,
          NSIntersectionRange(result.range, range) == result.range,
          replacements.last.map({ NSMaxRange($0.range) <= result.range.location }) ?? true
        else { continue }
        replacements.append(Replacement(result.range, Self.normalizingLineEndings(string)))
      }
    }
    guard !replacements.isEmpty else { return }
    // NSTextView と同じく、置き換えた選択は、その中の最初の置き換えの後ろのキャレットにする。
    let selecting = session.selections.map { selection -> (anchor: Int, head: Int) in
      let range = nsRange(of: selection.range)
      if let first = replacements.first(where: { NSIntersectionRange($0.range, range) == $0.range }),
        range.length > 0
      {
        let caret = offset(NSMaxRange(first.range), after: replacements)
        return (caret, caret)
      }
      return (
        offset(offset(of: selection.anchor), after: replacements),
        offset(offset(of: selection.head), after: replacements)
      )
    }
    replace(replacements, selecting: selecting)
  }

  /// 範囲の最初の行の矩形。ビューの座標。
  func firstRectInView(for range: NSRange) -> NSRect {
    let rect = layout.selectionRects(range).first ?? layout.caretRect(at: range.location)
    return rect.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
  }

  // MARK: - 右クリックメニュー

  /// 右クリックメニューに、誤りの単語の候補と、スペルと文法・置換のサブメニューを足す。
  var textCheckingMenuAdditions: [ContextMenuAddition] {
    [
      ContextMenuAddition(position: .top) { [weak self] request in
        self?.spellingSuggestionItems(request) ?? []
      },
      ContextMenuAddition(position: .beforeTransformations) { [weak self] _ in
        guard let self else { return [] }
        return [spellingMenuItem(), substitutionsMenuItem()]
      },
    ]
  }

  /// 押した位置の誤りの単語の候補、「スペルを無視」と「スペルを学習」。入力中の検査が
  /// オフでも出す (NSTextView と同じ)。項目の宛先は NSTextCheckingController。
  private func spellingSuggestionItems(_ request: ContextMenuRequest) -> [NSMenuItem] {
    // キーボードから開いたときは、選んだ範囲の先頭の単語を見る。
    let primary = nsRange(of: session.primarySelection.range)
    guard let clicked = request.clickedIndex ?? (primary.length > 0 ? primary.location : nil)
    else { return [] }
    let onSelection = session.selections.contains {
      NSLocationInRange(clicked, nsRange(of: $0.range))
    }
    var effective = primary
    guard
      let menu = textChecker.controller.menu(
        at: clicked, clickedOnSelection: onSelection, effectiveRange: &effective)
    else { return [] }
    var items = menu.items
    menu.removeAllItems()
    // 前後の区切りは、メニューの組み立てが群の間に入れる区切りと重なる。
    while items.first?.isSeparatorItem == true { items.removeFirst() }
    while items.last?.isSeparatorItem == true { items.removeLast() }
    return items
  }

  private func submenuItem(title: String, items: [NSMenuItem]) -> NSMenuItem {
    let submenu = NSMenu()
    items.forEach(submenu.addItem)
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    return item
  }

  private func spellingMenuItem() -> NSMenuItem {
    submenuItem(
      title: standardSubmenuTitle(
        containing: #selector(showGuessPanel(_:)), fallback: "Spelling and Grammar"),
      items: [
        standardItem(#selector(showGuessPanel(_:)), fallback: "Show Spelling and Grammar"),
        standardItem(#selector(checkSpelling(_:)), fallback: "Check Document Now"),
        .separator(),
        toggleItem(#selector(toggleContinuousSpellChecking(_:)), "Check Spelling While Typing"),
        toggleItem(#selector(toggleGrammarChecking(_:)), "Check Grammar With Spelling"),
        toggleItem(
          #selector(toggleAutomaticSpellingCorrection(_:)), "Correct Spelling Automatically"),
      ])
  }

  /// 選択があるときだけ、選択の中を置き換える項目を先頭に出す (NSTextView と同じ)。
  private func substitutionsMenuItem() -> NSMenuItem {
    var items: [NSMenuItem] = []
    if session.selections.contains(where: { !$0.isEmpty }) {
      items += [
        standardItem(#selector(replaceQuotesInSelection(_:)), fallback: "Replace Quotes"),
        standardItem(#selector(replaceDashesInSelection(_:)), fallback: "Replace Dashes"),
        standardItem(#selector(replaceTextInSelection(_:)), fallback: "Replace Text"),
        .separator(),
      ]
    }
    items += [
      standardItem(#selector(orderFrontSubstitutionsPanel(_:)), fallback: "Show Substitutions"),
      .separator(),
      toggleItem(#selector(toggleSmartInsertDelete(_:)), "Smart Copy/Paste"),
      toggleItem(#selector(toggleAutomaticQuoteSubstitution(_:)), "Smart Quotes"),
      toggleItem(#selector(toggleAutomaticDashSubstitution(_:)), "Smart Dashes"),
      toggleItem(#selector(toggleAutomaticLinkDetection(_:)), "Smart Links"),
      toggleItem(#selector(toggleAutomaticDataDetection(_:)), "Data Detectors"),
      toggleItem(#selector(toggleAutomaticTextReplacement(_:)), "Text Replacement"),
    ]
    return submenuItem(
      title: standardSubmenuTitle(
        containing: #selector(orderFrontSubstitutionsPanel(_:)), fallback: "Substitutions"),
      items: items)
  }

  private func toggleItem(_ action: Selector, _ fallback: String) -> NSMenuItem {
    let item = standardItem(action, fallback: fallback)
    item.state = textCheckingToggles[action] == true ? .on : .off
    return item
  }
}
