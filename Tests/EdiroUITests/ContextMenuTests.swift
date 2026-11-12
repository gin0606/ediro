import AppKit
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったウィンドウとコントローラもテストの間は生かしておく。
private var retainedEditors: [(NSWindow, EditorTextController)] = []

/// 本文と選択から始めて、`location` の文字の上で右クリックする場面と、その結果。
nonisolated struct ContextMenuScenario: CustomTestStringConvertible, Sendable {
  enum Transformation: String, Sendable {
    case upper = "uppercaseWord:", lower = "lowercaseWord:", capitalize = "capitalizeWord:"
    case fullWidth = "convertToFullWidth:", halfWidth = "convertToHalfWidth:"
    case traditional = "convertToTraditionalChinese:", simplified = "convertToSimplifiedChinese:"

    static let cased: [Self] = [.upper, .lower, .capitalize]
  }

  let text: String
  let selection: NSRange
  let click: Int
  /// 右クリックの後の選択。
  let selects: NSRange
  /// 調べると翻訳の題名に入る文字。調べる対象が無ければ nil。
  let lookUp: String?
  let shares: Bool
  /// 変換のサブメニューの項目。全角・半角は、優先する言語に日本語があるときの並び。
  let transformations: [Transformation]

  init(
    _ text: String, _ location: Int, _ length: Int, click: Int, selects: Int, _ selectedLength: Int,
    lookUp: String?, shares: Bool = true, _ transformations: [Transformation]
  ) {
    self.text = text
    self.selection = NSRange(location: location, length: length)
    self.click = click
    self.selects = NSRange(location: selects, length: selectedLength)
    self.lookUp = lookUp
    self.shares = shares
    self.transformations = transformations
  }

  var testDescription: String { "\(text.debugDescription) \(selection) click=\(click)" }
}

extension AppKitTests {
  struct ContextMenuTests {
    /// 参照 NSTextView と同じ大きさのウィンドウに載せたエディタ。
    private func makeEditor(text: String) -> (NSWindow, EditorView) {
      let controller = EditorTextController(state: makeState(text: text))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = controller.scrollView
      controller.editorView.setFrameSize(controller.scrollView.contentSize)
      window.makeFirstResponder(controller.editorView)
      retainedEditors.append((window, controller))
      return (window, controller.editorView)
    }

    private func ranges(_ view: EditorView) -> [NSRange] {
      view.session.selections.map { view.nsRange(of: $0.range) }
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    /// `location` の文字の中央を押すイベント。
    private func mouseEvent(
      _ type: NSEvent.EventType, at location: Int, in view: EditorView
    ) throws -> NSEvent {
      let character = view.layout.storage.mutableString.rangeOfComposedCharacterSequence(at: location)
      let rect = try #require(view.layout.selectionRects(character).first)
      let point = view.convert(
        NSPoint(x: rect.midX + view.textOrigin.x, y: rect.midY + view.textOrigin.y), to: nil)
      return try #require(
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
          clickCount: 1, pressure: 1))
    }

    /// ウィンドウ座標の `point` を右クリックするイベント。
    private func rightMouseDown(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
    }

    // MARK: - 右クリックメニューの並び

    /// 優先する言語に日本語があるか。全角・半角の変換は、このときだけ出す (NSTextView と同じ)。
    private static var prefersJapanese: Bool {
      Locale.preferredLanguages.contains { Locale(identifier: $0).language.languageCode == .japanese }
    }

    /// 項目を、AppKit の翻訳で変わらない値で一行ずつ表す。サブメニューは `submenu` の行の後に
    /// 字下げして並べる。題名は、このビューが組み立てる調べると翻訳の項目だけ入れる。共有の
    /// 項目は AppKit の共有の項目と同じ action なので `share` と書く。このビューが宛先の項目は、
    /// 無効なら `disabled` を付ける。ペーストの有効・無効は汎用のペーストボードで変わるので見ない。
    private func outline(_ menu: NSMenu, in view: EditorView, depth: Int = 0) -> [String] {
      let indent = String(repeating: "  ", count: depth)
      let share = NSSharingServicePicker(items: [""]).standardShareMenuItem.action
      let titled = [#selector(EditorView.lookUpFromMenu(_:)), #selector(EditorView.translateFromMenu(_:))]
      let paste = [#selector(EditorView.paste(_:)), #selector(EditorView.pasteAsPlainText(_:))]
      return menu.items.flatMap { item -> [String] in
        if item.isSeparatorItem { return [indent + "---"] }
        if let submenu = item.submenu {
          return [indent + "submenu"] + outline(submenu, in: view, depth: depth + 1)
        }
        guard let action = item.action else { return [indent + "no action"] }
        if action == share { return [indent + "share"] }
        // 検証はチェック印を付け直すので、状態を読む前に行う。
        let disabled =
          item.target === view && !paste.contains(action) && !view.validateUserInterfaceItem(item)
        var fields = [NSStringFromSelector(action)]
        if titled.contains(action) { fields.append(item.title) }
        if item.tag != 0 { fields.append("tag=\(item.tag)") }
        if item.state == .on { fields.append("on") }
        if item.isAlternate { fields.append("alternate") }
        if item.isAlternate || !item.keyEquivalent.isEmpty {
          let mask = item.keyEquivalentModifierMask
          let modifiers: [(NSEvent.ModifierFlags, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
          ]
          fields.append(modifiers.filter { mask.contains($0.0) }.map(\.1).joined() + item.keyEquivalent)
        }
        if disabled { fields.append("disabled") }
        return [indent + fields.joined(separator: " ")]
      }
    }

    /// Writing Tools が使えるときだけ、Show Writing Tools、Proofread、Rewrite の 3 項目と区切り。
    /// 有効かどうかは応答連鎖の先の NSApplication が決めるので見ない。
    private var writingToolsLines: [String] {
      guard NSWritingToolsCoordinator.isWritingToolsAvailable else { return [] }
      return ["showWritingTools:", "showWritingTools: tag=1", "showWritingTools: tag=2", "---"]
    }

    /// スペルと文法のサブメニュー。自動のスペル修正の既定はシステム設定に従う。
    private var spellingLines: [String] {
      let correction = NSSpellChecker.isAutomaticSpellingCorrectionEnabled ? " on" : ""
      return [
        "submenu", "  showGuessPanel:", "  checkSpelling:", "  ---", "  toggleContinuousSpellChecking:",
        "  toggleGrammarChecking: on", "  toggleAutomaticSpellingCorrection:" + correction,
      ]
    }

    /// 置換のサブメニュー。選択があるときだけ、選択の中を置き換える項目を先頭に出す。
    private func substitutionLines(selection: Bool) -> [String] {
      let replacing =
        selection
        ? ["  replaceQuotesInSelection:", "  replaceDashesInSelection:", "  replaceTextInSelection:", "  ---"]
        : []
      return ["submenu"] + replacing + [
        "  orderFrontSubstitutionsPanel:", "  ---", "  toggleSmartInsertDelete: on",
        "  toggleAutomaticQuoteSubstitution:", "  toggleAutomaticDashSubstitution:",
        "  toggleAutomaticLinkDetection:", "  toggleAutomaticDataDetection:",
        "  toggleAutomaticTextReplacement:",
      ]
    }

    @Test func 右クリックメニューは調べると編集と共有とWritingToolsとスペルと置換と変換と読み上げを並べる() throws {
      let (window, view) = makeEditor(text: "This is a word.")
      defer { window.close() }
      view.select([NSRange(location: 0, length: 4)], primary: 0)
      let menu = try #require(view.menu(for: try mouseEvent(.rightMouseDown, at: 1, in: view)))
      let widths = Self.prefersJapanese ? ["  convertToFullWidth:"] : []
      let expected =
        [
          "lookUpFromMenu: Look Up “This”", "translateFromMenu: Translate “This”", "---",
          "cut:", "copy:", "paste:", "pasteAsPlainText: alternate ⌥⇧", "---",
          "share", "---",
        ] + writingToolsLines + spellingLines + substitutionLines(selection: true)
        + ["submenu", "  uppercaseWord:", "  lowercaseWord:", "  capitalizeWord:"] + widths
        + ["submenu", "  startSpeaking:", "  stopSpeaking: disabled"]
      #expect(outline(menu, in: view) == expected)
    }

    @Test func 空の本文の右クリックメニューは調べると共有と変換を出さない() throws {
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      let menu = try #require(view.menu(for: try rightMouseDown(at: NSPoint(x: 100, y: 250), in: window)))
      let expected =
        ["cut: disabled", "copy: disabled", "paste:", "pasteAsPlainText: alternate ⌥⇧", "---"]
        + writingToolsLines + spellingLines + substitutionLines(selection: false)
        + ["submenu", "  startSpeaking: disabled", "  stopSpeaking: disabled"]
      #expect(outline(menu, in: view) == expected)
      #expect(ranges(view) == [caret(0)])
    }

    // MARK: - 場面ごとの出し分け

    nonisolated static let menuScenarios: [ContextMenuScenario] = {
      let cased = ContextMenuScenario.Transformation.cased
      return [
        // 選択の上では選択を変えず、選択に接しない単語の上ではその単語を選ぶ。
        .init("This is a word.", 0, 4, click: 1, selects: 0, 4, lookUp: "This", cased + [.fullWidth]),
        .init("This is a word.", 0, 4, click: 11, selects: 10, 4, lookUp: "word", cased + [.fullWidth]),
        .init("This is a word.", 3, 3, click: 1, selects: 0, 4, lookUp: "This", cased + [.fullWidth]),
        .init("This is a word.", 0, 7, click: 5, selects: 0, 7, lookUp: "This is", cased + [.fullWidth]),
        // 選択の端に接する空白の上では選択を変えず、調べる対象は無い。
        .init("This is a word.", 0, 7, click: 7, selects: 0, 7, lookUp: nil, cased + [.fullWidth]),
        // キャレットの前後の文字の上では選択を変えない。それ以外の文字の上ではその単語を選ぶ。
        .init("This is a word.", 2, 0, click: 1, selects: 2, 0, lookUp: "This", []),
        .init("hello world", 2, 0, click: 2, selects: 2, 0, lookUp: "hello", []),
        .init("hello world", 1, 0, click: 2, selects: 0, 5, lookUp: "hello", cased + [.fullWidth]),
        .init("hello world", 11, 0, click: 9, selects: 6, 5, lookUp: "world", cased + [.fullWidth]),
        .init("This is a word.", 4, 0, click: 4, selects: 4, 0, lookUp: nil, []),
        // 空白と句読点の上: 選ぶが、共有の対象にしない。クリックした単語としては調べないが、
        // クリックした文字を含む選択は、空白だけでなければ句読点だけでも調べる対象にする。
        .init("This is a word.", 0, 0, click: 4, selects: 4, 1, lookUp: nil, shares: false, [.fullWidth]),
        .init("This is a word.", 0, 0, click: 14, selects: 14, 1, lookUp: nil, shares: false, [.fullWidth]),
        .init("a, b", 0, 0, click: 1, selects: 1, 1, lookUp: nil, shares: false, [.fullWidth]),
        .init("a, b", 1, 1, click: 1, selects: 1, 1, lookUp: ",", shares: false, [.fullWidth]),
        .init("a b", 1, 1, click: 1, selects: 1, 1, lookUp: nil, shares: false, [.fullWidth]),
        .init(", ,", 1, 0, click: 1, selects: 1, 0, lookUp: nil, shares: false, []),
        .init(", ,", 0, 3, click: 1, selects: 0, 3, lookUp: ", ,", shares: false, [.fullWidth]),
        // 題名: 前後の空白を除き、改行は空白に、UTF-16 で 30 を超える分は省く。
        .init("ab cd\nef gh", 0, 8, click: 1, selects: 0, 8, lookUp: "ab cd ef", cased + [.fullWidth]),
        .init(
          "This is a much longer sentence that goes on.", 0, 44, click: 1, selects: 0, 44,
          lookUp: "This is a much longer sentence…", cased + [.fullWidth]),
        .init(
          "This is a much longer sentence that goes on.", 0, 31, click: 1, selects: 0, 31,
          lookUp: "This is a much longer sentence", cased + [.fullWidth]),
        .init(
          "  leading and trailing  x", 0, 24, click: 3, selects: 0, 24, lookUp: "leading and trailing",
          cased + [.fullWidth]),
        .init(
          String(repeating: "😀", count: 20) + " xyz", 0, 44, click: 0, selects: 0, 44,
          lookUp: String(repeating: "😀", count: 15) + "…", cased + [.fullWidth]),
        // 複数の符号単位からなる文字の直後のキャレットは、その文字に接しない。絵文字は文字でも
        // 数字でもないので、クリックした単語としては調べない。
        .init("😀 foo", 2, 0, click: 0, selects: 0, 2, lookUp: nil, []),
        .init("e\u{301} foo", 2, 0, click: 0, selects: 0, 2, lookUp: "e\u{301}", cased + [.fullWidth]),
        // 変換は、大文字と小文字の区別がある文字を含むときと、その変換で文字が変わるときだけ出す。
        .init("全角ＡＢＣ　テスト です", 0, 0, click: 7, selects: 6, 3, lookUp: "テスト", [.halfWidth]),
        .init("全角ＡＢＣ　テスト です", 0, 5, click: 1, selects: 0, 5, lookUp: "全角ＡＢＣ", cased + [.halfWidth]),
        .init("ｱｲｳ zz", 0, 3, click: 1, selects: 0, 3, lookUp: "ｱｲｳ", [.fullWidth]),
        .init(
          "abc テスト zz", 0, 7, click: 1, selects: 0, 7, lookUp: "abc テスト",
          cased + [.fullWidth, .halfWidth]),
        .init("漢字 zz", 0, 2, click: 0, selects: 0, 2, lookUp: "漢字", [.simplified]),
        .init("汉字 zz", 0, 2, click: 0, selects: 0, 2, lookUp: "汉字", [.traditional]),
        .init("! zz", 0, 1, click: 0, selects: 0, 1, lookUp: "!", shares: false, [.fullWidth]),
        .init("日本 zz", 0, 2, click: 0, selects: 0, 2, lookUp: "日本", []),
        // 誤りの単語の上でも、選択と調べる対象はほかの単語と同じ。候補、Ignore Spelling、
        // Learn Spelling の項目は TextCheckingTests で確かめる。
        .init(
          "This is a mispeled word.", 0, 0, click: 12, selects: 10, 8, lookUp: "mispeled",
          cased + [.fullWidth]),
      ]
    }()

    private func item(_ menu: NSMenu, _ action: Selector) -> NSMenuItem? {
      for item in menu.items {
        if item.action == action { return item }
        if let submenu = item.submenu, let found = self.item(submenu, action) { return found }
      }
      return nil
    }

    /// 調べると翻訳の項目の題名。
    private func lookUpTitles(_ menu: NSMenu) -> [String] {
      let actions = [#selector(EditorView.lookUpFromMenu(_:)), #selector(EditorView.translateFromMenu(_:))]
      return menu.items.filter { $0.action.map(actions.contains) == true }.map(\.title)
    }

    private func expectedLookUpTitles(_ text: String?) -> [String] {
      text.map { ["Look Up “\($0)”", "Translate “\($0)”"] } ?? []
    }

    private func hasShareItem(_ menu: NSMenu) -> Bool {
      let share = NSSharingServicePicker(items: [""]).standardShareMenuItem.action
      return menu.items.contains { $0.action == share }
    }

    /// 変換のサブメニューの項目の action。サブメニューが無ければ空。
    private func transformations(_ menu: NSMenu) -> [String] {
      let all: Set<String> = [
        "uppercaseWord:", "lowercaseWord:", "capitalizeWord:", "convertToFullWidth:", "convertToHalfWidth:",
        "convertToTraditionalChinese:", "convertToSimplifiedChinese:",
      ]
      let submenu = menu.items.compactMap(\.submenu).first { submenu in
        submenu.items.contains { $0.action.map { all.contains(NSStringFromSelector($0)) } == true }
      }
      return submenu?.items.compactMap { $0.action.map(NSStringFromSelector) } ?? []
    }

    @Test(arguments: menuScenarios)
    func 右クリックした場面で選択と調べる対象と共有と変換が決まる(scenario: ContextMenuScenario) throws {
      let (window, view) = makeEditor(text: scenario.text)
      defer { window.close() }
      view.select([scenario.selection], primary: 0)
      let menu = try #require(view.menu(for: try mouseEvent(.rightMouseDown, at: scenario.click, in: view)))
      #expect(ranges(view) == [scenario.selects])
      #expect(lookUpTitles(menu) == expectedLookUpTitles(scenario.lookUp))
      #expect(hasShareItem(menu) == scenario.shares)
      let widths: Set<ContextMenuScenario.Transformation> = [.fullWidth, .halfWidth]
      let expected = scenario.transformations.filter { Self.prefersJapanese || !widths.contains($0) }
      #expect(transformations(menu) == expected.map(\.rawValue))
      // 選択の中を置き換える項目は、選択があるときだけ出す。
      let replacing = item(menu, #selector(EditorView.replaceQuotesInSelection(_:))) != nil
      #expect(replacing == (scenario.selects.length > 0))
    }

    /// 文字の無い所を押す場面と、その結果。`line` の文字がある表示上の行の高さで、横は行の右か
    /// 左の端。上と下は本文の外の余白。
    nonisolated struct PointScenario: CustomTestStringConvertible, Sendable {
      enum Side: Sendable { case right, left, above, below }
      let line: Int
      let side: Side
      /// 右クリックの後の選択。
      let selects: NSRange
      /// 調べると翻訳の題名に入る文字。調べる対象が無ければ nil。
      let lookUp: String?

      init(line: Int, side: Side, selects: Int, _ length: Int, lookUp: String?) {
        self.line = line
        self.side = side
        self.selects = NSRange(location: selects, length: length)
        self.lookUp = lookUp
      }

      var testDescription: String { "line of \(line) \(side)" }
    }

    /// `pointText` の 2 の位置のキャレットから始める。
    nonisolated static let pointText = "hello\nworld wide\n\nlast"
    nonisolated static let pointScenarios: [PointScenario] = [
      // 行の右の余白は、その行の改行に掛かる。改行で終わらない最後の行の右はどの文字でもないので、
      // 選択を変えず、調べない。
      .init(line: 0, side: .right, selects: 5, 1, lookUp: nil),
      .init(line: 6, side: .right, selects: 16, 1, lookUp: nil),
      .init(line: 17, side: .right, selects: 17, 1, lookUp: nil),
      .init(line: 18, side: .right, selects: 2, 0, lookUp: nil),
      // 行の左の余白は、その行の最初の文字に掛かる。
      .init(line: 0, side: .left, selects: 0, 5, lookUp: "hello"),
      .init(line: 6, side: .left, selects: 6, 5, lookUp: "world"),
      .init(line: 18, side: .left, selects: 18, 4, lookUp: "last"),
      // どの行の高さでもない本文の下と上の余白は、最後の文字に掛かる (NSTextView と同じ)。
      .init(line: 18, side: .below, selects: 18, 4, lookUp: "last"),
      .init(line: 0, side: .above, selects: 18, 4, lookUp: "last"),
    ]

    /// `text` の `location` にキャレットを置き、文字の無い所を右クリックしたメニュー。
    private func rightClick(
      _ scenario: PointScenario, text: String, caret location: Int
    ) throws -> (NSWindow, EditorView, NSMenu) {
      let (window, view) = makeEditor(text: text)
      view.select([caret(location)], primary: 0)
      // 改行で終わる本文の後ろの空の行には文字が無いので、キャレットの矩形で高さを求める。
      let rect =
        view.layout.selectionRects(NSRange(location: scenario.line, length: 1)).first
        ?? view.layout.caretRect(at: scenario.line)
      let point =
        switch scenario.side {
        case .right: view.convert(NSPoint(x: 300, y: rect.midY + view.textOrigin.y), to: nil)
        case .left: view.convert(NSPoint(x: 3, y: rect.midY + view.textOrigin.y), to: nil)
        case .below: NSPoint(x: 100, y: 20)
        case .above: view.convert(NSPoint(x: 100, y: 3), to: nil)
        }
      let menu = try #require(view.menu(for: try rightMouseDown(at: point, in: window)))
      return (window, view, menu)
    }

    @Test(arguments: pointScenarios)
    func 文字の無い所の右クリックは近い文字に掛かるか選択を変えない(scenario: PointScenario) throws {
      let (window, view, menu) = try rightClick(scenario, text: Self.pointText, caret: 2)
      defer { window.close() }
      #expect(ranges(view) == [scenario.selects])
      #expect(lookUpTitles(menu) == expectedLookUpTitles(scenario.lookUp))
    }

    /// `hello\nworld\n` の 1 の位置のキャレットから始める。
    nonisolated static let trailingNewlineScenarios: [PointScenario] = [
      // 最後の改行の右と本文の下は、最後の改行に掛かる。
      .init(line: 6, side: .right, selects: 11, 1, lookUp: nil),
      .init(line: 6, side: .below, selects: 11, 1, lookUp: nil),
      // 改行で終わる本文の後ろの空の行はどの文字でもないので、選択を変えず、調べない。
      .init(line: 12, side: .right, selects: 1, 0, lookUp: nil),
    ]

    @Test(arguments: trailingNewlineScenarios)
    func 改行で終わる本文の後ろの右クリックは最後の改行に掛かるか選択を変えない(scenario: PointScenario) throws {
      let (window, view, menu) = try rightClick(scenario, text: "hello\nworld\n", caret: 1)
      defer { window.close() }
      #expect(ranges(view) == [scenario.selects])
      #expect(lookUpTitles(menu) == expectedLookUpTitles(scenario.lookUp))
    }

    @Test func 折り返した行の右と左の余白は押した行の端の文字に掛かる() throws {
      let (window, view) = makeEditor(text: "aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj")
      defer { window.close() }
      view.setFrameSize(NSSize(width: 120, height: view.frame.height))
      let lines = view.layout.lineFrames()
      try #require(lines.count > 1)
      let second = view.layout.offset(at: CGPoint(x: 0, y: lines[1].midY))
      #expect(view.layout.characterIndex(at: CGPoint(x: 500, y: lines[0].midY)) == second - 1)
      #expect(view.layout.characterIndex(at: CGPoint(x: -3, y: lines[1].midY)) == second)
    }

    @Test func 右から左に書く文字は押した文字に掛かる() throws {
      let (window, view) = makeEditor(text: "אבג דהו")
      defer { window.close() }
      for index in [0, 2, 3, 4, 6] {
        let rect = try #require(view.layout.selectionRects(NSRange(location: index, length: 1)).first)
        #expect(view.layout.characterIndex(at: CGPoint(x: rect.midX, y: rect.midY)) == index)
      }
    }

    @Test func 複数の選択では右クリックした選択があれば選択を変えず無ければその単語だけを選ぶ() throws {
      let (window, view) = makeEditor(text: "one two three four")
      defer { window.close() }
      let selections = [NSRange(location: 0, length: 3), NSRange(location: 8, length: 5)]
      for (click, expected) in [(9, selections), (15, [NSRange(location: 14, length: 4)])] {
        view.select(selections, primary: 0)
        _ = view.menu(for: try mouseEvent(.rightMouseDown, at: click, in: view))
        #expect(ranges(view) == expected, "click=\(click)")
      }
    }

    // MARK: - 自分で組み立てる項目

    @Test func 調べると翻訳の項目はクリックした単語を対象にこのビューへ送る() throws {
      let (window, view) = makeEditor(text: "hello world")
      defer { window.close() }
      view.select([caret(0)], primary: 0)
      let menu = try #require(view.menu(for: try mouseEvent(.rightMouseDown, at: 8, in: view)))
      let lookUp = try #require(item(menu, #selector(EditorView.lookUpFromMenu(_:))))
      let translate = try #require(item(menu, #selector(EditorView.translateFromMenu(_:))))
      #expect(lookUp.title == "Look Up “world”")
      #expect(translate.title == "Translate “world”")
      for item in [lookUp, translate] {
        #expect(item.target === view)
        #expect((item.representedObject as? NSValue)?.rangeValue == NSRange(location: 6, length: 5))
        #expect(view.validateUserInterfaceItem(item))
      }
    }

    @Test func 標準の項目の有効と無効を選択と状態から決める() throws {
      let (window, view) = makeEditor(text: "hello world")
      defer { window.close() }
      view.select([caret(2)], primary: 0)
      var menu = view.contextMenu(for: ContextMenuRequest(clickedIndex: nil, lookUpRange: nil))
      for action in [#selector(EditorView.cut(_:)), #selector(EditorView.copy(_:))] {
        #expect(try !view.validateUserInterfaceItem(#require(item(menu, action))))
      }
      #expect(try !view.validateUserInterfaceItem(#require(item(menu, #selector(EditorView.stopSpeaking(_:))))))
      #expect(try view.validateUserInterfaceItem(#require(item(menu, #selector(EditorView.startSpeaking(_:))))))
      // 選択が無ければ変換のサブメニューは出さない。
      #expect(item(menu, #selector(EditorView.uppercaseWord(_:))) == nil)
      let plain = try #require(item(menu, #selector(EditorView.pasteAsPlainText(_:))))
      #expect(plain.isAlternate)

      view.select([NSRange(location: 0, length: 5)], primary: 0)
      menu = view.contextMenu(for: ContextMenuRequest(clickedIndex: nil, lookUpRange: nil))
      for action in [#selector(EditorView.cut(_:)), #selector(EditorView.copy(_:))] {
        #expect(try view.validateUserInterfaceItem(#require(item(menu, action))))
      }
      #expect(item(menu, #selector(EditorView.uppercaseWord(_:)))?.target === view)
    }

    @Test func ほかの機能が足す項目を先頭と変換の前に置く() throws {
      let (window, view) = makeEditor(text: "hello world")
      defer { window.close() }
      var requests: [ContextMenuRequest] = []
      view.contextMenuAdditions = [
        ContextMenuAddition(position: .beforeTransformations) { _ in
          [NSMenuItem(title: "Spelling", action: nil, keyEquivalent: "")]
        },
        ContextMenuAddition(position: .top) { request in
          requests.append(request)
          return [NSMenuItem(title: "Suggestion", action: nil, keyEquivalent: "")]
        },
      ]
      view.select([NSRange(location: 0, length: 5)], primary: 0)
      let menu = try #require(view.menu(for: try mouseEvent(.rightMouseDown, at: 1, in: view)))
      let titles = menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
      #expect(titles.first == "Suggestion")
      #expect(titles[1] == "---")
      let spelling = try #require(titles.firstIndex(of: "Spelling"))
      #expect(titles[spelling - 1] == "---")
      #expect(titles[spelling + 1] == "Transformations")
      #expect(requests.map(\.clickedIndex) == [1])
      #expect(requests.map(\.lookUpRange) == [NSRange(location: 0, length: 5)])
    }

    @Test func 右クリックは変換中の文字を確定する() throws {
      let (window, view) = makeEditor(text: "hello world")
      defer { window.close() }
      view.select([caret(11)], primary: 0)
      view.setMarkedText("か", selectedRange: caret(1), replacementRange: caret(NSNotFound))
      _ = view.menu(for: try mouseEvent(.rightMouseDown, at: 1, in: view))
      #expect(!view.hasMarkedText())
      #expect(view.text == "hello worldか")
    }

    // MARK: - 変換

    @Test func 変換は選択ごとに単語の範囲へ掛けて一回で取り消せる() {
      let (window, view) = makeEditor(text: "hello world foo\nbar baz")
      defer { window.close() }
      view.select([caret(2), NSRange(location: 13, length: 1), caret(18)], primary: 1)
      view.uppercaseWord(nil)
      #expect(view.text == "HELLO world FOO\nBAR baz")
      #expect(
        ranges(view) == [
          NSRange(location: 0, length: 5), NSRange(location: 12, length: 3),
          NSRange(location: 16, length: 3),
        ])
      #expect(view.session.primaryIndex == 1)
      view.undo(nil)
      #expect(view.text == "hello world foo\nbar baz")
      view.redo(nil)
      #expect(view.text == "HELLO world FOO\nBAR baz")
    }

    @Test func 同じ単語に掛かる選択はまとめて一度だけ変換する() {
      let (window, view) = makeEditor(text: "straße x")
      defer { window.close() }
      view.select([caret(1), caret(4)], primary: 0)
      view.uppercaseWord(nil)
      #expect(view.text == "STRASSE x")
      #expect(ranges(view) == [NSRange(location: 0, length: 7)])
    }

    @Test func 長さの変わる変換の後ろの選択は変換した範囲に合わせて動く() {
      let (window, view) = makeEditor(text: "straße ab")
      defer { window.close() }
      view.select([caret(1), caret(8)], primary: 1)
      view.convertToFullWidth(nil)
      view.undo(nil)
      view.uppercaseWord(nil)
      #expect(view.text == "STRASSE AB")
      #expect(ranges(view) == [NSRange(location: 0, length: 7), NSRange(location: 8, length: 2)])
    }

    @Test func 全角と半角と繁体と簡体の変換は選択ごとに掛ける() {
      let (window, view) = makeEditor(text: "abc ｱｲｳ\n漢字")
      defer { window.close() }
      view.select([caret(1), caret(5)], primary: 0)
      view.convertToFullWidth(nil)
      #expect(view.text == "ａｂｃ アイウ\n漢字")
      view.convertToHalfWidth(nil)
      #expect(view.text == "abc ｱｲｳ\n漢字")
      view.select([NSRange(location: 8, length: 2)], primary: 0)
      view.convertToSimplifiedChinese(nil)
      #expect(view.text == "abc ｱｲｳ\n汉字")
      view.convertToTraditionalChinese(nil)
      #expect(view.text == "abc ｱｲｳ\n漢字")
    }

    @Test func 変換中は変換のコマンドが本文を変えない() {
      let (window, view) = makeEditor(text: "hello")
      defer { window.close() }
      view.select([caret(5)], primary: 0)
      view.setMarkedText("か", selectedRange: caret(1), replacementRange: caret(NSNotFound))
      view.uppercaseWord(nil)
      #expect(view.text == "helloか")
      #expect(view.hasMarkedText())
    }

    // MARK: - サービス

    @Test func サービスには旧来の名前の文字列の型でだけ応答し選択が無ければ受け取りだけに応答する() {
      let legacy = EditorView.legacyStringType
      let types: [NSPasteboard.PasteboardType?] = [nil, .string, legacy, .rtf, .tiff, .fileURL]
      // nil はその向きの型を問わない問い合わせで、それにも応答する。
      let cases: [(selection: NSRange, sends: [NSPasteboard.PasteboardType?])] = [
        (caret(2), [nil]), (NSRange(location: 0, length: 5), [nil, legacy]),
      ]
      let returns: [NSPasteboard.PasteboardType?] = [nil, legacy]
      for (selection, sends) in cases {
        let (window, view) = makeEditor(text: "hello world")
        defer { window.close() }
        view.select([selection], primary: 0)
        for send in types {
          for receive in types {
            let requestor = view.validRequestor(forSendType: send, returnType: receive) as AnyObject?
            let expected: AnyObject? = sends.contains(send) && returns.contains(receive) ? view : nil
            #expect(
              requestor === expected,
              "selection=\(selection) send=\(String(describing: send)) return=\(String(describing: receive))")
          }
        }
      }
    }

    private func makePasteboard() -> NSPasteboard {
      let pasteboard = NSPasteboard(name: NSPasteboard.Name("ediro-test-\(UUID().uuidString)"))
      pasteboard.clearContents()
      return pasteboard
    }

    @Test func サービスへの送り出しはコピーと同じく複数の選択を改行で繋ぐ() {
      let (window, view) = makeEditor(text: "one two three")
      defer { window.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      view.select([caret(1)], primary: 0)
      #expect(!view.writeSelection(to: pasteboard, types: [EditorView.legacyStringType]))
      view.select([NSRange(location: 0, length: 3), NSRange(location: 8, length: 5)], primary: 0)
      #expect(!view.writeSelection(to: pasteboard, types: [.rtf]))
      #expect(view.writeSelection(to: pasteboard, types: [EditorView.legacyStringType]))
      #expect(pasteboard.string(forType: .string) == "one\nthree")
    }

    @Test func 送り出した選択と同じ行数を受け取ったら一行ずつ元の選択に戻す() {
      let (window, view) = makeEditor(text: "one two three")
      defer { window.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      view.select([NSRange(location: 0, length: 3), caret(5), NSRange(location: 8, length: 5)], primary: 1)
      #expect(view.writeSelection(to: pasteboard, types: [EditorView.legacyStringType]))
      pasteboard.clearContents()
      pasteboard.setString("ONE!\nTHREE", forType: .string)
      #expect(view.readSelection(from: pasteboard))
      #expect(view.text == "ONE! two THREE")
      #expect(ranges(view) == [caret(4), caret(6), caret(14)])
      view.undo(nil)
      #expect(view.text == "one two three")
    }

    @Test func 範囲を選んだ選択が一つなら主のキャレットではなくその選択を置き換える() {
      let (window, view) = makeEditor(text: "one two three")
      defer { window.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      pasteboard.setString("TWO", forType: .string)
      view.select([NSRange(location: 4, length: 3), caret(0)], primary: 1)
      #expect(view.readSelection(from: pasteboard))
      #expect(view.text == "one TWO three")
    }

    @Test func 受け取った行の数が揃わなければ主の選択だけを置き換えほかの選択は残す() {
      let (window, view) = makeEditor(text: "a\nb c")
      defer { window.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      view.select([NSRange(location: 0, length: 3), NSRange(location: 4, length: 1)], primary: 0)
      #expect(view.writeSelection(to: pasteboard, types: [EditorView.legacyStringType]))
      pasteboard.clearContents()
      pasteboard.setString("A\nB\nC", forType: .string)
      #expect(view.readSelection(from: pasteboard))
      #expect(view.text == "A\nB\nC c")
      view.undo(nil)
      #expect(view.text == "a\nb c")
    }

    @Test func 受け取った末尾の改行は行の数に数えない() {
      let (window, view) = makeEditor(text: "one two three")
      defer { window.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      view.select([NSRange(location: 0, length: 3), NSRange(location: 8, length: 5)], primary: 0)
      pasteboard.setString("ONE\nTHREE\n", forType: .string)
      #expect(view.readSelection(from: pasteboard))
      #expect(view.text == "ONE two THREE")
    }

    @Test func 末尾の改行を除いて行の数が揃わなければほかの選択の文字を消さない() {
      let (window, view) = makeEditor(text: "one two three")
      defer { window.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      view.select([NSRange(location: 0, length: 3), NSRange(location: 8, length: 5)], primary: 0)
      pasteboard.setString("ONE\n", forType: .string)
      #expect(view.readSelection(from: pasteboard))
      #expect(view.text == "ONE\n two three")
    }

    @Test func 変換中は切り取りと変換と調べると翻訳の項目を使えない() throws {
      let (window, view) = makeEditor(text: "hello")
      defer { window.close() }
      view.select([NSRange(location: 0, length: 5)], primary: 0)
      let menu = view.contextMenu(
        for: ContextMenuRequest(clickedIndex: nil, lookUpRange: NSRange(location: 0, length: 5)))
      let actions = [
        #selector(EditorView.cut(_:)), #selector(EditorView.uppercaseWord(_:)),
        #selector(EditorView.lookUpFromMenu(_:)), #selector(EditorView.translateFromMenu(_:)),
      ]
      for action in actions { #expect(try view.validateUserInterfaceItem(#require(item(menu, action)))) }
      view.select([caret(5)], primary: 0)
      view.setMarkedText("か", selectedRange: caret(1), replacementRange: caret(NSNotFound))
      for action in actions { #expect(try !view.validateUserInterfaceItem(#require(item(menu, action)))) }
    }

    @Test func 改行を含む選択があれば行ごとに戻さず主の選択だけを置き換える() {
      let (window, view) = makeEditor(text: "foo x\nbar\nnext")
      defer { window.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      view.select([NSRange(location: 0, length: 3), NSRange(location: 6, length: 4)], primary: 1)
      pasteboard.setString("BAR\n", forType: .string)
      #expect(view.readSelection(from: pasteboard))
      #expect(view.text == "foo x\nBAR\nnext")
    }

    @Test func 右クリックで選び直しても表示を送らない() throws {
      let text = (1...200).map { "line \($0)" }.joined(separator: "\n")
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([caret(0)], primary: 0)
      view.scroll(.zero)
      let above = view.convert(NSPoint(x: 100, y: 3), to: nil)
      let event = try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: above, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
      _ = view.menu(for: event)
      #expect(ranges(view) != [caret(0)])
      #expect(view.visibleRect.minY == 0)
    }

    @Test func 強めのクリックは文字の無い所では調べない() throws {
      let (window, view) = makeEditor(text: "hello world")
      defer { window.close() }
      let below = view.convert(NSPoint(x: 100, y: 200), to: nil)
      let event = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: below, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
      #expect(view.definitionRequest(for: event) == nil)
    }

    @Test func 共有と読み上げは選択を無ければ本文全体を使う() {
      let (window, view) = makeEditor(text: "one two three")
      defer { window.close() }
      view.select([caret(2)], primary: 0)
      #expect(view.selectionOrWholeText == "one two three")
      view.select([NSRange(location: 4, length: 3)], primary: 0)
      #expect(view.selectionOrWholeText == "two")
      view.select([NSRange(location: 0, length: 3), caret(5), NSRange(location: 8, length: 5)], primary: 1)
      #expect(view.selectionOrWholeText == "one\nthree")
    }

    @Test func サービスから受け取った文字列で主の選択を置き換え一回で取り消せる() {
      let (window, view) = makeEditor(text: "one two three")
      defer { window.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      pasteboard.setString("TWO\r\n2", forType: .string)
      view.select([caret(0), NSRange(location: 4, length: 3), caret(13)], primary: 1)
      #expect(view.readSelection(from: pasteboard))
      #expect(view.text == "one TWO\n2 three")
      #expect(ranges(view) == [caret(0), caret(9), caret(15)])
      view.undo(nil)
      #expect(view.text == "one two three")
      pasteboard.clearContents()
      #expect(!view.readSelection(from: pasteboard))
    }

    @Test(arguments: [true, false], [true, false])
    func サービスのスマートペーストは設定がオンで印のある文字列にだけ前後の空白を補う(enabled: Bool, marked: Bool) {
      let smart = enabled && marked
      let spaced = ("hello world foo", 12)
      for (text, selection, (expected, after)) in [
        ("hellofoo", caret(5), smart ? spaced : ("helloworldfoo", 10)),
        ("helloXfoo", NSRange(location: 5, length: 1), smart ? spaced : ("helloworldfoo", 10)),
        // 前に空白があれば、後ろにだけ補う。
        ("hello foo", caret(6), smart ? spaced : ("hello worldfoo", 11)),
        // 前後に文字が無ければ補わない。
        ("", caret(0), ("world", 5)),
      ] {
        let (window, view) = makeEditor(text: text)
        defer { window.close() }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("world", forType: .string)
        if marked { pasteboard.setString("", forType: EditorView.smartPasteType) }
        view.smartInsertDeleteEnabled = enabled
        view.select([selection], primary: 0)

        #expect(view.readSelection(from: pasteboard))
        #expect(view.text == expected)
        #expect(ranges(view) == [caret(after)])
        view.undo(nil)
        #expect(view.text == text)
        #expect(ranges(view) == [selection])
        #expect(view.undoManager?.canUndo == false)
      }
    }

    @Test func サービスのスマートペーストも各選択へ配分して一回で取り消せる() {
      let text = "aXb cYd"
      let selections = [NSRange(location: 1, length: 1), caret(4), NSRange(location: 5, length: 1)]
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      view.smartInsertDeleteEnabled = true
      view.select(selections, primary: 1)
      pasteboard.setString("one\ntwo\n", forType: .string)
      pasteboard.setString("", forType: EditorView.smartPasteType)

      #expect(view.readSelection(from: pasteboard))
      #expect(view.text == "a one b c two d")
      #expect(ranges(view) == [caret(6), caret(8), caret(14)])
      #expect(view.session.primaryIndex == 1)
      view.undo(nil)
      #expect(view.text == text)
      #expect(ranges(view) == selections)
      #expect(view.session.primaryIndex == 1)
      #expect(view.undoManager?.canUndo == false)
    }

    @Test func サービスのスマートペーストを配分できなければ他の選択を保持する() {
      let text = "aXb cYd"
      let selections = [NSRange(location: 1, length: 1), NSRange(location: 5, length: 1)]
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      view.smartInsertDeleteEnabled = true
      view.select(selections, primary: 0)
      pasteboard.setString("one", forType: .string)
      pasteboard.setString("", forType: EditorView.smartPasteType)

      #expect(view.readSelection(from: pasteboard))
      #expect(view.text == "a one b cYd")
      #expect(ranges(view) == [caret(6), NSRange(location: 9, length: 1)])
      view.undo(nil)
      #expect(view.text == text)
      #expect(ranges(view) == selections)
      #expect(view.undoManager?.canUndo == false)
    }

    // MARK: - 調べる

    @Test func 調べる範囲と位置はその文字のベースラインの始点になる() throws {
      let (window, view) = makeEditor(text: "hello world\nsecond line")
      defer { window.close() }
      let range = NSRange(location: 12, length: 6)
      let request = view.definitionRequest(for: range)
      #expect(request.text.string == "second")
      let caret = view.layout.caretRect(at: 12)
      #expect(request.origin.x == caret.minX + view.textOrigin.x)
      // ベースラインは行の中ほどより下、行の下端より上にある。
      #expect(request.origin.y > caret.midY + view.textOrigin.y)
      #expect(request.origin.y < caret.maxY + view.textOrigin.y)
    }

    @Test func 強めのクリックはクリックした単語かそれを含む選択を調べる() throws {
      let (window, view) = makeEditor(text: "hello world foo")
      defer { window.close() }
      view.select([caret(0)], primary: 0)
      var request = view.definitionRequest(for: try mouseEvent(.leftMouseDown, at: 8, in: view))
      #expect(request?.text.string == "world")
      #expect(request?.origin == view.definitionRequest(for: NSRange(location: 6, length: 5)).origin)
      // 選択は変えない。
      #expect(ranges(view) == [caret(0)])

      view.select([NSRange(location: 6, length: 9)], primary: 0)
      request = view.definitionRequest(for: try mouseEvent(.leftMouseDown, at: 13, in: view))
      #expect(request?.text.string == "world foo")

      // 空白の上では調べない。
      request = view.definitionRequest(for: try mouseEvent(.leftMouseDown, at: 5, in: view))
      #expect(request == nil)
    }

    @Test func ビューの外からの調べるは主の選択かキャレットのある単語を調べる() throws {
      let (window, view) = makeEditor(text: "hello world")
      defer { window.close() }
      let outside = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: NSPoint(x: -50, y: -50), modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
      view.select([caret(8)], primary: 0)
      #expect(view.definitionRequest(for: outside)?.text.string == "world")
      view.select([caret(1), NSRange(location: 0, length: 11)], primary: 1)
      #expect(view.definitionRequest(for: outside)?.text.string == "hello world")
    }

    // MARK: - 翻訳

    @Test func 翻訳は範囲の上から出して訳文で置き換えられる() throws {
      let (window, view) = makeEditor(text: "hello world")
      defer { window.close() }
      defer { view.translation.isPresented = false }
      view.select([caret(0), NSRange(location: 7, length: 2), caret(11)], primary: 2)
      view.presentTranslation(for: NSRange(location: 6, length: 5))
      #expect(view.translation.isPresented)
      #expect(view.translation.text == "world")
      let anchor = try #require(view.translationAnchor)
      let rect = try #require(view.layout.selectionRects(NSRange(location: 6, length: 5)).first)
      #expect(anchor.frame == rect.offsetBy(dx: view.textOrigin.x, dy: view.textOrigin.y))
      // クリックは下の本文に通す。
      #expect(view.hitTest(view.convert(NSPoint(x: anchor.frame.midX, y: anchor.frame.midY), to: view.superview)) === view)

      // 長さの違う訳文で置き換えると、後ろの選択はその差だけ動き、範囲の中の選択は訳文の後ろに移る。
      let replace = try #require(view.translation.replace)
      replace("Welt!!")
      #expect(view.text == "hello Welt!!")
      #expect(ranges(view) == [caret(0), caret(12)])
      view.undo(nil)
      #expect(view.text == "hello world")
    }

    @Test func 翻訳を出した後に本文が変わっていたら置き換えない() throws {
      let (window, view) = makeEditor(text: "hello world")
      defer { window.close() }
      defer { view.translation.isPresented = false }
      view.presentTranslation(for: NSRange(location: 6, length: 5))
      view.select([caret(6)], primary: 0)
      view.insertText("X", replacementRange: caret(NSNotFound))
      let replace = try #require(view.translation.replace)
      replace("monde")
      #expect(view.text == "hello Xworld")
    }

    @Test func 訳を出した後に同じ文字が範囲へずれてきても置き換えない() throws {
      let (window, view) = makeEditor(text: "aa aa")
      defer { window.close() }
      defer { view.translation.isPresented = false }
      view.presentTranslation(for: NSRange(location: 3, length: 2))
      view.select([caret(0)], primary: 0)
      view.insertText("aa ", replacementRange: caret(NSNotFound))
      let replace = try #require(view.translation.replace)
      replace("XX")
      #expect(view.text == "aa aa aa")
    }

    @Test func 調べる対象に選択の前後の空白と改行は含めない() throws {
      let (window, view) = makeEditor(text: "one\n two \nthree")
      defer { window.close() }
      view.select([NSRange(location: 4, length: 6)], primary: 0)
      #expect(view.lookUpRange(clickedIndex: 6) == NSRange(location: 5, length: 3))
    }

    @Test func 翻訳を出したまま別の範囲を翻訳すると前の翻訳を閉じて出し直す() throws {
      let (window, view) = makeEditor(text: "hello world")
      defer { window.close() }
      view.presentTranslation(for: NSRange(location: 0, length: 5))
      let first = view.translation
      let firstAnchor = try #require(view.translationAnchor)
      view.presentTranslation(for: NSRange(location: 6, length: 5))
      defer { view.translation.isPresented = false }
      #expect(firstAnchor.superview == nil)
      #expect(view.translationAnchor?.superview === view)
      #expect(view.translation !== first)
      #expect(view.translation.isPresented)
      #expect(view.translation.text == "world")
      let replace = try #require(view.translation.replace)
      replace("monde")
      #expect(view.text == "hello monde")
    }

    @Test func 訳文の改行は本文と同じLFに揃えて置き換える() throws {
      let (window, view) = makeEditor(text: "hello world")
      defer { window.close() }
      defer { view.translation.isPresented = false }
      view.select([caret(11)], primary: 0)
      view.presentTranslation(for: NSRange(location: 6, length: 5))
      let replace = try #require(view.translation.replace)
      replace("a\r\nb")
      #expect(view.text == "hello a\nb")
      #expect(ranges(view) == [caret(9)])
    }

    @Test func メニュー項目以外から調べると翻訳が送られても何もしない() {
      let (window, view) = makeEditor(text: "hello")
      defer { window.close() }
      view.lookUpFromMenu(nil)
      view.translateFromMenu(nil)
      #expect(!view.translation.isPresented)
    }

    // MARK: - キーバインド

    @Test func 変換のコマンドはキーバインドからも届く() {
      let (window, view) = makeEditor(text: "hello")
      defer { window.close() }
      view.select([caret(2)], primary: 0)
      view.doCommand(by: #selector(NSResponder.capitalizeWord(_:)))
      #expect(view.text == "Hello")
    }
  }
}
