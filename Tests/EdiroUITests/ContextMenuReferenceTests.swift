import AppKit
import ObjectiveC
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったウィンドウとコントローラもテストの間は生かしておく。
private var retainedEditors: [(NSWindow, EditorTextController)] = []

extension AppKitTests {
  /// 右クリックメニュー、右クリックで選ぶ範囲、サービスの応答とスマートペーストを、参照 NSTextView
  /// (置き換え前のエディタと同じ設定の NSTextView) と比べる。OS を更新した後に手で走らせ、標準の
  /// 振る舞いが変わっていないかを見る。
  ///
  /// EDIRO_INVENTORY=1 swift test --filter ContextMenuReferenceTests
  ///
  /// 標準の右クリックメニューの中身は OS の版と開発機の設定 (Writing Tools が使えるかなど) で
  /// 変わるので、既定の `swift test` では走らせない。エディタの仕様は ContextMenuTests が明示した
  /// 値で確かめる。ここで落ちたら、差の項目を見て、標準が変わったのか、エディタが標準から外れたのか
  /// を見分ける。たとえば Writing Tools が使えるのに NSTextView がその項目を出さない OS では、
  /// Writing Tools の 3 項目がエディタにだけあるという差で落ちる。
  @Suite(.enabled(if: ProcessInfo.processInfo.environment["EDIRO_INVENTORY"] == "1"))
  struct ContextMenuReferenceTests {
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

    /// `location` の文字の中央を右クリックするイベント。
    private func rightMouseDown(at location: Int, in view: EditorView) throws -> NSEvent {
      let character = view.layout.storage.mutableString.rangeOfComposedCharacterSequence(at: location)
      let rect = try #require(view.layout.selectionRects(character).first)
      let point = view.convert(
        NSPoint(x: rect.midX + view.textOrigin.x, y: rect.midY + view.textOrigin.y), to: nil)
      return try rightMouseDown(at: point, in: try #require(view.window))
    }

    /// ウィンドウ座標の `point` を右クリックするイベント。
    private func rightMouseDown(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
    }

    /// ウィンドウの座標で、行の高さ `lineY` の右か左の端、または本文の下か上を押すイベント。
    private func event(
      _ side: ContextMenuTests.PointScenario.Side, lineY: CGFloat, window: NSWindow, below: CGFloat,
      above: CGFloat
    ) throws -> NSEvent {
      let point =
        switch side {
        case .right: NSPoint(x: 300, y: lineY)
        case .left: NSPoint(x: 3, y: lineY)
        case .below: NSPoint(x: 100, y: below)
        case .above: NSPoint(x: 100, y: above)
        }
      return try rightMouseDown(at: point, in: window)
    }

    // MARK: - 比べる項目

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

    /// 比べる対象から外す項目。Search With Google と Report a Concern は、NSTextView が
    /// private の action で出し、代わりの公開 API が無いので、このエディタは出さない。
    private static let excludedActions: Set<String> = [
      "_searchWithGoogleFromMenu:", "_invokeProofreadingFeedbackReportConcern:",
    ]

    /// 比べる対象から外すサブメニュー。そのサブメニューが含む action で見分ける。縦書き
    /// (Layout Orientation) は扱わない。
    private static let excludedSubmenuActions: Set<String> = ["changeLayoutOrientation:"]

    /// 有効かどうかを比べない項目。NSTextView は Writing Tools の項目に自分で応答するが、この
    /// ビューは応答せず、応答連鎖の先の NSApplication が応答する。テストのプロセスでは
    /// NSApplication はこの項目を無効にする (参照 NSTextView を第一応答者にしても無効) ので比べない。
    private static let enabledElsewhere: Set<String> = ["showWritingTools:"]

    private func isExcluded(_ item: NSMenuItem) -> Bool {
      if let action = item.action, Self.excludedActions.contains(NSStringFromSelector(action)) {
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

    /// 二つのメニューを比べる。差があれば、どちらにだけある項目かを書いて落とす。
    private func expectSameMenu(
      _ menu: NSMenu, in view: EditorView, as referenceMenu: NSMenu, in textView: NSTextView,
      sourceLocation: SourceLocation = #_sourceLocation
    ) {
      let actual = describe(menu, in: view)
      let expected = describe(referenceMenu, in: textView)
      guard actual != expected else { return }
      var lines: [String] = []
      for change in actual.difference(from: expected) {
        switch change {
        case .remove(_, let item, _): lines.append("参照にだけある: \(item)")
        case .insert(_, let item, _): lines.append("エディタにだけある: \(item)")
        }
      }
      let message = (["右クリックメニューが参照と違う"] + lines).joined(separator: "\n")
      Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }

    // MARK: - 右クリックメニューと選択

    @Test(arguments: ContextMenuTests.menuScenarios)
    func 右クリックメニューの項目とクリック後の選択が参照と同じになる(scenario: ContextMenuScenario) throws {
      let reference = ReferenceTextView(text: scenario.text)
      defer { reference.close() }
      reference.textView.setSelectedRange(scenario.selection)
      let click = try #require(reference.rightMouseDown(at: scenario.click))
      let referenceMenu = try #require(reference.textView.menu(for: click))

      let (window, view) = makeEditor(text: scenario.text)
      defer { window.close() }
      view.select([scenario.selection], primary: 0)
      let menu = try #require(view.menu(for: try rightMouseDown(at: scenario.click, in: view)))
      expectSameMenu(menu, in: view, as: referenceMenu, in: reference.textView)
      #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
    }

    @Test func 空の本文の右クリックメニューも参照と同じになる() throws {
      let reference = ReferenceTextView(text: "")
      defer { reference.close() }
      let point = NSPoint(x: 100, y: 250)
      let referenceMenu = try #require(
        reference.textView.menu(for: try rightMouseDown(at: point, in: reference.window)))
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      let menu = try #require(view.menu(for: try rightMouseDown(at: point, in: window)))
      expectSameMenu(menu, in: view, as: referenceMenu, in: reference.textView)
    }

    @Test(arguments: ContextMenuTests.pointScenarios)
    func 文字の無い所の右クリックも参照と同じ選択とメニューになる(scenario: ContextMenuTests.PointScenario) throws {
      let text = ContextMenuTests.pointText
      let reference = ReferenceTextView(text: text)
      defer { reference.close() }
      reference.textView.setSelectedRange(caret(2))
      let screen = reference.textView.firstRect(
        forCharacterRange: NSRange(location: scenario.line, length: 1), actualRange: nil)
      let referenceY = reference.window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY)).y
      let referenceMenu = try #require(
        reference.textView.menu(
          for: try event(
            scenario.side, lineY: referenceY, window: reference.window, below: 20,
            above: reference.textView.convert(NSPoint(x: 0, y: 3), to: nil).y)))

      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([caret(2)], primary: 0)
      let rect = try #require(
        view.layout.selectionRects(NSRange(location: scenario.line, length: 1)).first
          ?? Optional(view.layout.caretRect(at: scenario.line)))
      let y = view.convert(NSPoint(x: 0, y: rect.midY + view.textOrigin.y), to: nil).y
      let above = view.convert(NSPoint(x: 0, y: 3), to: nil).y
      let menu = try #require(
        view.menu(for: try event(scenario.side, lineY: y, window: window, below: 20, above: above)))
      #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
      expectSameMenu(menu, in: view, as: referenceMenu, in: reference.textView)
    }

    @Test(arguments: [ContextMenuTests.PointScenario.Side.right, .below])
    func 改行で終わる本文の最後の行の右と本文の下の右クリックは参照と同じになる(
      side: ContextMenuTests.PointScenario.Side
    ) throws {
      let text = "hello\nworld\n"
      let reference = ReferenceTextView(text: text)
      defer { reference.close() }
      reference.textView.setSelectedRange(caret(1))
      let screen = reference.textView.firstRect(
        forCharacterRange: NSRange(location: 6, length: 1), actualRange: nil)
      let referenceY = reference.window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY)).y
      let referenceMenu = try #require(
        reference.textView.menu(
          for: try event(side, lineY: referenceY, window: reference.window, below: 20, above: 0)))
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([caret(1)], primary: 0)
      let rect = try #require(view.layout.selectionRects(NSRange(location: 6, length: 1)).first)
      let y = view.convert(NSPoint(x: 0, y: rect.midY + view.textOrigin.y), to: nil).y
      let menu = try #require(
        view.menu(for: try event(side, lineY: y, window: window, below: 20, above: 0)))
      #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
      expectSameMenu(menu, in: view, as: referenceMenu, in: reference.textView)
    }

    @Test func 改行で終わる本文の後ろの空の行の右クリックは参照と同じになる() throws {
      let reference = ReferenceTextView(text: "hello\nworld\n")
      defer { reference.close() }
      reference.textView.setSelectedRange(caret(1))
      let (window, view) = makeEditor(text: "hello\nworld\n")
      defer { window.close() }
      view.select([caret(1)], primary: 0)
      // 3 行目 (空の行) の高さ。各ビューの最後の行の矩形から求める。
      let referenceRect = reference.textView.firstRect(
        forCharacterRange: NSRange(location: 6, length: 1), actualRange: nil)
      let referenceY = reference.window.convertPoint(
        fromScreen: NSPoint(x: referenceRect.midX, y: referenceRect.midY - referenceRect.height)).y
      let referenceMenu = try #require(
        reference.textView.menu(
          for: try rightMouseDown(at: NSPoint(x: 100, y: referenceY), in: reference.window)))
      let last = try #require(view.layout.lineFrames().last)
      let y = view.convert(NSPoint(x: 0, y: last.midY + view.textOrigin.y), to: nil).y
      let menu = try #require(view.menu(for: try rightMouseDown(at: NSPoint(x: 100, y: y), in: window)))
      #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
      expectSameMenu(menu, in: view, as: referenceMenu, in: reference.textView)
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
        _ = view.menu(for: try rightMouseDown(at: click, in: view))
        #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
      }
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

    @Test(arguments: [true, false], [true, false])
    func サービスのスマートペーストは参照と同じ本文と選択になる(enabled: Bool, marked: Bool) {
      for (text, selection) in [
        ("hellofoo", caret(5)),
        ("helloXfoo", NSRange(location: 5, length: 1)),
        ("hello foo", caret(6)),
        ("", caret(0)),
      ] {
        let reference = ReferenceTextView(text: text)
        defer { reference.close() }
        let (window, view) = makeEditor(text: text)
        defer { window.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ediro-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("world", forType: .string)
        if marked { pasteboard.setString("", forType: EditorView.smartPasteType) }
        reference.textView.smartInsertDeleteEnabled = enabled
        view.smartInsertDeleteEnabled = enabled
        reference.textView.setSelectedRange(selection)
        view.select([selection], primary: 0)

        let expectedAccepted = reference.textView.readSelection(from: pasteboard)
        #expect(expectedAccepted)
        #expect(view.readSelection(from: pasteboard) == expectedAccepted)
        #expect(view.text == reference.textView.string)
        #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
      }
    }
  }
}
