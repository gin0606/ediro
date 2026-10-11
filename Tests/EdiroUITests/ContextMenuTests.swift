import AppKit
import ObjectiveC
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったウィンドウとコントローラもテストの間は生かしておく。
private var retainedEditors: [(NSWindow, EditorTextController)] = []

/// 本文と選択から始めて、`location` の文字の上で右クリックする場面。
nonisolated struct ContextMenuScenario: CustomTestStringConvertible, Sendable {
  let text: String
  let selection: NSRange
  let click: Int

  init(_ text: String, _ location: Int, _ length: Int, click: Int) {
    self.text = text
    self.selection = NSRange(location: location, length: length)
    self.click = click
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

    // MARK: - 参照 NSTextView との差分

    nonisolated static let menuScenarios: [ContextMenuScenario] = [
      // 選択の上と、選択やキャレットに接しない単語の上
      .init("This is a word.", 0, 4, click: 1),
      .init("This is a word.", 0, 4, click: 11),
      .init("This is a word.", 3, 3, click: 1),
      .init("This is a word.", 0, 7, click: 5),
      // 選択の端に接する空白の上では選択を変えず、調べる対象は無い。
      .init("This is a word.", 0, 7, click: 7),
      // キャレットに接する文字の上では選択を変えない。
      .init("This is a word.", 2, 0, click: 1),
      .init("hello world", 2, 0, click: 2),
      .init("hello world", 3, 0, click: 2),
      .init("hello world", 1, 0, click: 2),
      .init("hello world", 8, 0, click: 9),
      .init("hello world", 11, 0, click: 9),
      .init("This is a word.", 4, 0, click: 4),
      // 空白と句読点の上: 選ぶが、調べる・共有の対象にしない。
      .init("This is a word.", 0, 0, click: 4),
      .init("This is a word.", 0, 0, click: 14),
      .init("a, b", 0, 0, click: 1),
      .init("a, b", 1, 1, click: 1),
      .init("a b", 1, 1, click: 1),
      .init(", ,", 1, 0, click: 1),
      .init(", ,", 0, 3, click: 1),
      // 題名: 改行は空白に、30 文字を超える分は省く。
      .init("ab cd\nef gh", 0, 8, click: 1),
      .init("This is a much longer sentence that goes on.", 0, 44, click: 1),
      .init("This is a much longer sentence that goes on.", 0, 31, click: 1),
      .init("  leading and trailing  x", 0, 24, click: 3),
      // 題名は UTF-16 で 30 を超える分を省く。
      .init(String(repeating: "😀", count: 20) + " xyz", 0, 44, click: 0),
      // 複数の符号単位からなる文字の直後のキャレットは、その文字に接しない。
      .init("😀 foo", 2, 0, click: 0),
      .init("e\u{301} foo", 2, 0, click: 0),
      // 変換のサブメニューの出し分け
      .init("全角ＡＢＣ　テスト です", 0, 0, click: 7),
      .init("全角ＡＢＣ　テスト です", 0, 5, click: 1),
      .init("ＡＢＣ zz", 0, 3, click: 1),
      .init("ｱｲｳ zz", 0, 3, click: 1),
      .init("abc テスト zz", 0, 7, click: 1),
      .init("１２３ zz", 0, 3, click: 1),
      .init("漢字 zz", 0, 2, click: 0),
      .init("汉字 zz", 0, 2, click: 0),
      .init("! zz", 0, 1, click: 0),
      .init("日本 zz", 0, 2, click: 0),
      // 誤りの単語の上。候補などはスペルチェックの項目なので、比べる対象から外す。
      .init("This is a mispeled word.", 0, 0, click: 12),
    ]

    /// 比べる項目の内容。
    private struct Item: Equatable, CustomStringConvertible {
      var title: String
      var action: String?
      var tag: Int?
      var enabled: Bool?
      var state: NSControl.StateValue
      var alternate: Bool
      var key: String?
      var submenu: [Item]?

      var description: String {
        var fields = [title]
        if let action { fields.append(action) }
        if let tag { fields.append("tag=\(tag)") }
        if enabled == false { fields.append("disabled") }
        if state == .on { fields.append("on") }
        if alternate { fields.append("alternate") }
        if let key { fields.append("key=\(key)") }
        let head = fields.joined(separator: " | ")
        guard let submenu else { return head }
        return head + " [" + submenu.map(\.description).joined(separator: ", ") + "]"
      }

      static let separator = Item(
        title: "---", enabled: false, state: .off, alternate: false)
    }

    /// 参照 NSTextView が private の action で出す項目のうち、このエディタが公開 API で代わりに
    /// するもの。action はこのエディタのものと比べず、同じ名前に寄せる。
    private static let substitutedActions: [String: String] = [
      "_rvMenuItemAction": "lookUp", "lookUpFromMenu:": "lookUp", "translateFromMenu:": "lookUp",
    ]

    /// 比べる対象から外す項目。
    /// - Search With Google と Report a Concern: NSTextView は private の action で出し、
    ///   代わりの公開 API が無いので、このエディタは出さない。
    /// - 誤りの単語の候補、Ignore Spelling、Learn Spelling: スペルチェックの項目で、
    ///   このエディタはまだ持たない。スペルチェックを実装したら比べる。
    private static let excludedActions: Set<String> = [
      "_searchWithGoogleFromMenu:", "_invokeProofreadingFeedbackReportConcern:",
      "_changeSpellingFromMenu:", "_ignoreSpellingFromMenu:", "_learnSpellingFromMenu:",
    ]

    /// 比べる対象から外すサブメニュー。そのサブメニューが含む action で見分ける。
    /// - Layout Orientation: 縦書きは扱わない。
    /// - Spelling and Grammar と Substitutions: スペルチェックと自動置換の項目で、このエディタは
    ///   まだ持たない。それらを実装したら比べる。
    private static let excludedSubmenuActions: Set<String> = [
      "changeLayoutOrientation:", "showGuessPanel:", "orderFrontSubstitutionsPanel:",
    ]

    /// 有効かどうかを比べない項目。Writing Tools の項目の有効・無効は、このビューが Writing
    /// Tools に対応するまで NSTextView と同じにならない。対応したら比べる。
    private static let enabledElsewhere: Set<String> = ["showWritingTools:"]

    private func isExcluded(_ item: NSMenuItem) -> Bool {
      if let action = item.action, Self.excludedActions.contains(NSStringFromSelector(action)) {
        return true
      }
      // Ignore Spelling と Learn Spelling は、NSTextCheckingController を宛先にする。
      if let target = item.target, String(describing: type(of: target)).contains("TextChecking") {
        return true
      }
      return item.submenu?.items.contains {
        $0.action.map { Self.excludedSubmenuActions.contains(NSStringFromSelector($0)) } == true
      } == true
    }

    /// AppKit が表示の前に行う検証と同じ手順で、項目が有効かを求める。
    private func isEnabled(_ item: NSMenuItem, in view: NSView) -> Bool {
      guard let action = item.action else { return item.isEnabled }
      if item.submenu != nil { return true }
      let target = item.target ?? (view.responds(to: action) ? view : nil)
      guard let object = target as? NSObject else { return false }
      let validation = #selector(NSMenuItemValidation.validateMenuItem(_:))
      if object.responds(to: validation) {
        typealias Validate = @convention(c) (NSObject, Selector, NSMenuItem) -> ObjCBool
        let validate = unsafeBitCast(object.method(for: validation), to: Validate.self)
        return validate(object, validation, item).boolValue
      }
      if let validator = object as? NSUserInterfaceValidations {
        return validator.validateUserInterfaceItem(item)
      }
      return item.isEnabled
    }

    /// 区切りの連続と前後の区切りは、表示で見分けられないので一つにまとめて比べる。
    private func describe(_ menu: NSMenu, in view: NSView) -> [Item] {
      // 項目を開く直前に埋めるメニューも、埋めてから比べる。
      menu.delegate?.menuNeedsUpdate?(menu)
      var items: [Item] = []
      for item in menu.items where !isExcluded(item) {
        if item.isSeparatorItem {
          if let last = items.last, last != .separator { items.append(.separator) }
          continue
        }
        let action = item.action.map(NSStringFromSelector)
        let substituted = action.flatMap { Self.substitutedActions[$0] }
        items.append(
          Item(
            title: item.title, action: substituted ?? action,
            tag: substituted == nil ? item.tag : nil,
            enabled: action.map(Self.enabledElsewhere.contains) == true
              ? nil : isEnabled(item, in: view),
            state: item.state, alternate: item.isAlternate,
            key: item.isAlternate || !item.keyEquivalent.isEmpty
              ? "\(item.keyEquivalent.debugDescription) \(item.keyEquivalentModifierMask.rawValue)"
              : nil,
            submenu: item.submenu.map { describe($0, in: view) }))
      }
      if items.last == .separator { items.removeLast() }
      return items
    }

    @Test(arguments: menuScenarios)
    func 右クリックメニューの項目とクリック後の選択が参照と同じになる(scenario: ContextMenuScenario) throws {
      let reference = ReferenceTextView(text: scenario.text)
      defer { reference.close() }
      reference.textView.setSelectedRange(scenario.selection)
      let click = try #require(reference.rightMouseDown(at: scenario.click))
      let referenceMenu = try #require(reference.textView.menu(for: click))
      let expected = describe(referenceMenu, in: reference.textView)

      let (window, view) = makeEditor(text: scenario.text)
      defer { window.close() }
      view.select([scenario.selection], primary: 0)
      let menu = try #require(view.menu(for: try mouseEvent(.rightMouseDown, at: scenario.click, in: view)))
      #expect(describe(menu, in: view) == expected)
      #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
    }

    @Test func 空の本文の右クリックメニューも参照と同じになる() throws {
      let reference = ReferenceTextView(text: "")
      defer { reference.close() }
      let point = NSPoint(x: 100, y: 250)
      func event(_ window: NSWindow) throws -> NSEvent {
        try #require(
          NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1))
      }
      let referenceMenu = try #require(reference.textView.menu(for: try event(reference.window)))
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      let menu = try #require(view.menu(for: try event(window)))
      #expect(describe(menu, in: view) == describe(referenceMenu, in: reference.textView))
    }

    /// 文字の無い所を押す場面。`line` の文字がある表示上の行の高さで、横は行の右か左の端。
    nonisolated struct PointScenario: CustomTestStringConvertible, Sendable {
      enum Side: Sendable { case right, left, above, below }
      let line: Int
      let side: Side
      var testDescription: String { "line of \(line) \(side)" }
    }

    nonisolated static let pointText = "hello\nworld wide\n\nlast"
    nonisolated static let pointScenarios: [PointScenario] = [
      .init(line: 0, side: .right), .init(line: 0, side: .left), .init(line: 6, side: .right),
      .init(line: 6, side: .left), .init(line: 17, side: .right), .init(line: 18, side: .right),
      .init(line: 18, side: .left), .init(line: 18, side: .below), .init(line: 0, side: .above),
    ]

    /// ウィンドウの座標で、行の高さ `y` の右か左の端、または本文の下を押すイベント。
    private func event(
      _ scenario: PointScenario, lineY: CGFloat, window: NSWindow, below: CGFloat, above: CGFloat
    )
      throws -> NSEvent
    {
      let point =
        switch scenario.side {
        case .right: NSPoint(x: 300, y: lineY)
        case .left: NSPoint(x: 3, y: lineY)
        case .below: NSPoint(x: 100, y: below)
        case .above: NSPoint(x: 100, y: above)
        }
      return try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
    }

    @Test(arguments: pointScenarios)
    func 文字の無い所の右クリックも参照と同じ選択とメニューになる(scenario: PointScenario) throws {
      let reference = ReferenceTextView(text: Self.pointText)
      defer { reference.close() }
      reference.textView.setSelectedRange(NSRange(location: 2, length: 0))
      let screen = reference.textView.firstRect(
        forCharacterRange: NSRange(location: scenario.line, length: 1), actualRange: nil)
      let referenceY = reference.window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY)).y
      let referenceMenu = try #require(
        reference.textView.menu(
          for: try event(
            scenario, lineY: referenceY, window: reference.window, below: 20,
            above: reference.textView.convert(NSPoint(x: 0, y: 3), to: nil).y)))

      let (window, view) = makeEditor(text: Self.pointText)
      defer { window.close() }
      view.select([caret(2)], primary: 0)
      let rect = try #require(
        view.layout.selectionRects(NSRange(location: scenario.line, length: 1)).first
          ?? Optional(view.layout.caretRect(at: scenario.line)))
      let y = view.convert(NSPoint(x: 0, y: rect.midY + view.textOrigin.y), to: nil).y
      let above = view.convert(NSPoint(x: 0, y: 3), to: nil).y
      let menu = try #require(
        view.menu(for: try event(scenario, lineY: y, window: window, below: 20, above: above)))
      #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
      #expect(describe(menu, in: view) == describe(referenceMenu, in: reference.textView))
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

    @Test func 複数の選択では右クリックした選択があれば選択を変えない() throws {
      let reference = ReferenceTextView(text: "one two three four")
      defer { reference.close() }
      let (window, view) = makeEditor(text: "one two three four")
      defer { window.close() }
      let selections = [NSRange(location: 0, length: 3), NSRange(location: 8, length: 5)]
      for click in [9, 15] {
        reference.textView.selectedRanges = selections.map { NSValue(range: $0) }
        let event = try #require(reference.rightMouseDown(at: click))
        _ = reference.textView.menu(for: event)
        view.select(selections, primary: 0)
        _ = view.menu(for: try mouseEvent(.rightMouseDown, at: click, in: view))
        #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
      }
    }

    // MARK: - 自分で組み立てる項目

    private func item(_ menu: NSMenu, _ action: Selector) -> NSMenuItem? {
      for item in menu.items {
        if item.action == action { return item }
        if let submenu = item.submenu, let found = self.item(submenu, action) { return found }
      }
      return nil
    }

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
      // 変換中は切り取れない。
      view.setMarkedText("か", selectedRange: caret(1), replacementRange: caret(NSNotFound))
      #expect(try !view.validateUserInterfaceItem(#require(item(menu, #selector(EditorView.cut(_:))))))
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

    @Test func サービスに応答する型と向きが参照と同じになる() {
      let types: [NSPasteboard.PasteboardType?] = [
        nil, .string, EditorView.legacyStringType, .rtf, .tiff, .fileURL,
      ]
      for selection in [caret(2), NSRange(location: 0, length: 5)] {
        let reference = ReferenceTextView(text: "hello world")
        defer { reference.close() }
        reference.textView.setSelectedRange(selection)
        let (window, view) = makeEditor(text: "hello world")
        defer { window.close() }
        view.select([selection], primary: 0)
        for send in types {
          for receive in types {
            let expected = reference.textView.validRequestor(forSendType: send, returnType: receive)
            let actual = view.validRequestor(forSendType: send, returnType: receive)
            let expectsSelf = (expected as AnyObject?) === reference.textView
            #expect(
              ((actual as AnyObject?) === view) == expectsSelf,
              "selection=\(selection) send=\(String(describing: send)) return=\(String(describing: receive))"
            )
            if !expectsSelf {
              #expect((actual as AnyObject?) == nil)
            }
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

    @Test func 変換中は変換と調べると翻訳の項目を使えない() throws {
      let (window, view) = makeEditor(text: "hello")
      defer { window.close() }
      view.select([NSRange(location: 0, length: 5)], primary: 0)
      let menu = view.contextMenu(
        for: ContextMenuRequest(clickedIndex: nil, lookUpRange: NSRange(location: 0, length: 5)))
      let actions = [
        #selector(EditorView.uppercaseWord(_:)), #selector(EditorView.lookUpFromMenu(_:)),
        #selector(EditorView.translateFromMenu(_:)),
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

    @Test func サービスからの受け取りは参照と同じ本文と選択になる() {
      let reference = ReferenceTextView(text: "one two three")
      defer { reference.close() }
      let (window, view) = makeEditor(text: "one two three")
      defer { window.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      pasteboard.setString("TWO", forType: .string)
      reference.textView.setSelectedRange(NSRange(location: 4, length: 3))
      view.select([NSRange(location: 4, length: 3)], primary: 0)
      #expect(reference.textView.readSelection(from: pasteboard))
      #expect(view.readSelection(from: pasteboard))
      #expect(view.text == reference.textView.string)
      #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
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

    @Test(arguments: [PointScenario(line: 6, side: .right), PointScenario(line: 6, side: .below)])
    func 改行で終わる本文の最後の行の右と本文の下の右クリックは参照と同じになる(scenario: PointScenario) throws {
      let text = "hello\nworld\n"
      let reference = ReferenceTextView(text: text)
      defer { reference.close() }
      reference.textView.setSelectedRange(NSRange(location: 1, length: 0))
      let screen = reference.textView.firstRect(
        forCharacterRange: NSRange(location: scenario.line, length: 1), actualRange: nil)
      let referenceY = reference.window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY)).y
      let referenceMenu = try #require(
        reference.textView.menu(
          for: try event(scenario, lineY: referenceY, window: reference.window, below: 20, above: 0)))
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([caret(1)], primary: 0)
      let rect = try #require(view.layout.selectionRects(NSRange(location: scenario.line, length: 1)).first)
      let y = view.convert(NSPoint(x: 0, y: rect.midY + view.textOrigin.y), to: nil).y
      let menu = try #require(
        view.menu(for: try event(scenario, lineY: y, window: window, below: 20, above: 0)))
      #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
      #expect(describe(menu, in: view) == describe(referenceMenu, in: reference.textView))
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

    @Test func 改行で終わる本文の後ろの空の行の右クリックは参照と同じになる() throws {
      let reference = ReferenceTextView(text: "hello\nworld\n")
      defer { reference.close() }
      reference.textView.setSelectedRange(caret(1))
      let (window, view) = makeEditor(text: "hello\nworld\n")
      defer { window.close() }
      view.select([caret(1)], primary: 0)
      func event(_ window: NSWindow, y: CGFloat) throws -> NSEvent {
        try #require(
          NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 100, y: y), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
      }
      // 3 行目 (空の行) の高さ。各ビューの最後の行の矩形から求める。
      let referenceRect = reference.textView.firstRect(
        forCharacterRange: NSRange(location: 6, length: 1), actualRange: nil)
      let referenceY = reference.window.convertPoint(
        fromScreen: NSPoint(x: referenceRect.midX, y: referenceRect.midY - referenceRect.height)).y
      let referenceMenu = try #require(
        reference.textView.menu(for: try event(reference.window, y: referenceY)))
      let lines = view.layout.lineFrames()
      let last = try #require(lines.last)
      let y = view.convert(NSPoint(x: 0, y: last.midY + view.textOrigin.y), to: nil).y
      let menu = try #require(view.menu(for: try event(window, y: y)))
      #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
      #expect(describe(menu, in: view) == describe(referenceMenu, in: reference.textView))
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
