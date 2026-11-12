import AppKit
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったウィンドウとコントローラもテストの間は生かしておく。
private var retainedEditors: [(NSWindow, EditorTextController)] = []

/// 本文と、Cmd+クリックで開かずにこれまでどおりのクリックになる位置。
nonisolated struct PlainClickScenario: CustomTestStringConvertible, Sendable {
  let text: String
  let click: Int

  init(_ text: String, click: Int) {
    self.text = text
    self.click = click
  }

  var testDescription: String { "\(text.debugDescription) click=\(click)" }
}

extension AppKitTests {
  struct LinkTests {
    /// 開いた URL を記録するエディタ。ブラウザは開かず、警告音が鳴ればテストを失敗させる。
    /// `key` が false なら、キーでないウィンドウに載せる。
    private func makeEditor(text: String, key: Bool = true) -> (NSWindow, EditorView, () -> [URL]) {
      let controller = EditorTextController(state: makeState(text: text))
      let windowClass: NSWindow.Type = key ? KeyWindow.self : NSWindow.self
      let window = windowClass.init(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = controller.scrollView
      controller.editorView.setFrameSize(controller.scrollView.contentSize)
      window.makeFirstResponder(controller.editorView)
      retainedEditors.append((window, controller))
      let view = controller.editorView
      var opened: [URL] = []
      view.links.open = {
        opened.append($0)
        return true
      }
      view.links.beep = { Issue.record("警告音が鳴った") }
      return (window, view, { opened })
    }

    private func ranges(_ view: EditorView) -> [NSRange] {
      view.session.selections.map { view.nsRange(of: $0.range) }
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    /// `location` の文字の、左端から `fraction` の所の点 (ウィンドウの座標)。既定は中央。
    private func point(
      at location: Int, fraction: CGFloat = 0.5, in view: EditorView
    ) throws -> NSPoint {
      let character = view.layout.storage.mutableString.rangeOfComposedCharacterSequence(
        at: location)
      let rect = try #require(view.layout.selectionRects(character).first)
      return view.convert(
        NSPoint(
          x: rect.minX + rect.width * fraction + view.textOrigin.x,
          y: rect.midY + view.textOrigin.y), to: nil)
    }

    private func mouseEvent(
      _ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
      modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: modifiers,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
    }

    private func click(
      _ view: EditorView, at point: NSPoint, in window: NSWindow,
      modifiers: NSEvent.ModifierFlags = [.command], clickCount: Int = 1
    ) throws {
      view.mouseDown(
        with: try mouseEvent(
          .leftMouseDown, at: point, in: window, modifiers: modifiers, clickCount: clickCount))
      view.mouseUp(
        with: try mouseEvent(
          .leftMouseUp, at: point, in: window, modifiers: modifiers, clickCount: clickCount))
    }

    // MARK: - URL を開く

    @Test func URLの文字の上のCmdクリックでURLを開きキャレットを動かさない() throws {
      let text = "see https://example.com/a now"
      let (window, view, opened) = makeEditor(text: text)
      defer { window.close() }
      view.select([caret(1)], primary: 0)
      for location in [4, 12, 24] {
        try click(view, at: try point(at: location, in: view), in: window)
      }
      #expect(opened() == Array(repeating: URL(string: "https://example.com/a")!, count: 3))
      #expect(ranges(view) == [caret(1)])
    }

    @Test func URLのどの文字のどこを押しても開く() throws {
      let cases: [(text: String, url: NSRange)] = [
        ("see https://example.com now", NSRange(location: 4, length: 19)),
        // 右から左に書く文字の中の URL と、URL の中の右から左に書く文字。表示上の隣と論理上の
        // 前後が食い違う。
        ("אבג https://example.com דהו", NSRange(location: 4, length: 19)),
        ("see https://he.wikipedia.org/wiki/עברית now", NSRange(location: 4, length: 35)),
        // 幅の無い文字の前の文字
        ("https://example.com/a\u{200B}b", NSRange(location: 0, length: 21)),
        // 折り返した段落の 2 行目以降
        (
          String(repeating: "word ", count: 20) + "see https://he.wikipedia.org/wiki/עברית now",
          NSRange(location: 104, length: 35)
        ),
        (
          String(repeating: "word ", count: 20) + "https://example.com/a\u{200B}b",
          NSRange(location: 100, length: 21)
        ),
      ]
      for (text, url) in cases {
        let (window, view, opened) = makeEditor(text: text)
        defer { window.close() }
        var clicks = 0
        for index in url.location..<NSMaxRange(url) {
          let string = view.layout.storage.mutableString
          guard string.rangeOfComposedCharacterSequence(at: index).location == index,
            string.character(at: index) != 0x200B
          else { continue }
          for fraction in [0.1, 0.5, 0.9] {
            try click(view, at: try point(at: index, fraction: fraction, in: view), in: window)
            clicks += 1
            #expect(opened().count == clicks, "\(text) index=\(index) fraction=\(fraction)")
            #expect(
              opened().last?.absoluteString.removingPercentEncoding
                == (text as NSString).substring(with: url), "\(text) index=\(index)")
          }
        }
      }
    }

    @Test func 選択範囲の中のURLもCmdクリックで開き選択を変えない() throws {
      let text = "see https://example.com now"
      let (window, view, opened) = makeEditor(text: text)
      defer { window.close() }
      let all = NSRange(location: 0, length: (text as NSString).length)
      view.select([all], primary: 0)
      try click(view, at: try point(at: 10, in: view), in: window)
      #expect(opened() == [URL(string: "https://example.com")!])
      #expect(ranges(view) == [all])
    }

    @Test func 複数の選択があってもCmdクリックで選択を変えない() throws {
      let (window, view, opened) = makeEditor(text: "a http://example.com b")
      defer { window.close() }
      view.select([caret(0), NSRange(location: 21, length: 1)], primary: 1)
      try click(view, at: try point(at: 8, in: view), in: window)
      #expect(opened() == [URL(string: "http://example.com")!])
      #expect(ranges(view) == [caret(0), NSRange(location: 21, length: 1)])
      #expect(view.session.primaryIndex == 1)
    }

    @Test func 開く範囲と開くURLはurlトークンで決まる() throws {
      let cases: [(text: String, click: Int, url: String)] = [
        // Markdown のリンクは行き先で開き、閉じ括弧は含めない。
        ("[label](https://example.com/a)", 10, "https://example.com/a"),
        ("[a](<https://example.com/a b>)", 8, "https://example.com/a%20b"),
        // 自動リンクは括弧の内側を開く。
        ("<https://example.com/a>", 3, "https://example.com/a"),
        // URL に使えない文字はパーセントエンコードする。
        (
          "https://ja.wikipedia.org/wiki/日本語。", 31,
          "https://ja.wikipedia.org/wiki/%E6%97%A5%E6%9C%AC%E8%AA%9E"
        ),
        ("first\nhttps://example.com/2", 8, "https://example.com/2"),
      ]
      for (text, location, expected) in cases {
        let (window, view, opened) = makeEditor(text: text)
        defer { window.close() }
        try click(view, at: try point(at: location, in: view), in: window)
        #expect(opened().map(\.absoluteString) == [expected], "\(text)")
      }
    }

    @Test func バックスラッシュエスケープは自動リンクの中でだけ解かない() throws {
      let cases: [(text: String, click: Int, url: String)] = [
        (#"[a](<https://example.com/a\>b>)"#, 7, "https://example.com/a%3Eb"),
        // 記号でない文字の前と、エスケープしたバックスラッシュの後のバックスラッシュは残す。
        (#"[a](https://example.com/a\b\\c)"#, 6, "https://example.com/a%5Cb%5Cc"),
        (#"<https://example.com/a\_b>"#, 3, "https://example.com/a%5C_b"),
        // 直前で終わるリンクの中ではない。
        (#"[x](https://a.example)<https://example.com/a\_b>"#, 26, "https://example.com/a%5C_b"),
      ]
      for (text, location, expected) in cases {
        let (window, view, opened) = makeEditor(text: text)
        defer { window.close() }
        try click(view, at: try point(at: location, in: view), in: window)
        #expect(opened().map(\.absoluteString) == [expected], "\(text)")
      }
    }

    @Test func 開けないときは警告音を鳴らしキャレットを動かさない() throws {
      // URL として読めない行き先と、開くのに失敗した URL。
      let cases: [(text: String, opens: Bool, opened: [String])] = [
        ("[a](<https://exa mple.com/>)", true, []),
        ("see https://example.com now", false, ["https://example.com"]),
      ]
      for (text, opens, expected) in cases {
        let (window, view, _) = makeEditor(text: text)
        defer { window.close() }
        var opened: [URL] = []
        var beeps = 0
        view.links.open = {
          opened.append($0)
          return opens
        }
        view.links.beep = { beeps += 1 }
        view.select([caret(1)], primary: 0)
        try click(view, at: try point(at: 10, in: view), in: window)
        #expect(opened.map(\.absoluteString) == expected, "\(text)")
        #expect(beeps == 1, "\(text)")
        #expect(ranges(view) == [caret(1)], "\(text)")
      }
    }

    @Test func 変換中の文字を確定してからURLを開く() throws {
      let (window, view, opened) = makeEditor(text: "https://example.com ")
      defer { window.close() }
      view.select([caret(20)], primary: 0)
      view.setMarkedText(
        "あ", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(view.hasMarkedText())
      try click(view, at: try point(at: 3, in: view), in: window)
      #expect(!view.hasMarkedText())
      #expect(view.text == "https://example.com あ")
      #expect(opened() == [URL(string: "https://example.com")!])
      #expect(ranges(view) == [caret(21)])
    }

    @Test func Cmdのダブルクリックは一度だけ開き二回目以降はこれまでどおり選ぶ() throws {
      let text = "see https://example.com now\nnext"
      let (window, view, opened) = makeEditor(text: text)
      defer { window.close() }
      let (plainWindow, plain, _) = makeEditor(text: text)
      defer { plainWindow.close() }
      view.select([caret(0)], primary: 0)
      plain.select([caret(0)], primary: 0)
      let target = try point(at: 10, in: view)
      try click(view, at: target, in: window, clickCount: 1)
      #expect(ranges(view) == [caret(0)])
      for count in 2...3 {
        try click(view, at: target, in: window, clickCount: count)
        try click(plain, at: target, in: plainWindow, modifiers: [], clickCount: count)
        #expect(ranges(view) == ranges(plain), "clickCount=\(count)")
      }
      #expect(ranges(view) == [NSRange(location: 0, length: 28)])
      #expect(opened() == [URL(string: "https://example.com")!])
    }

    @Test func 普通のクリックに続けたCmdクリックでも開く() throws {
      let (window, view, opened) = makeEditor(text: "see https://example.com now")
      defer { window.close() }
      let target = try point(at: 10, in: view)
      try click(view, at: target, in: window, modifiers: [], clickCount: 1)
      let placed = ranges(view)
      // 間を置かずに押すと、Cmd を押していても二回目のクリックとして届く。
      try click(view, at: target, in: window, clickCount: 2)
      #expect(opened() == [URL(string: "https://example.com")!])
      #expect(ranges(view) == placed)
    }

    @Test func 端末依存の修飾キーやCapsLockが乗っていても開く() throws {
      let (window, view, opened) = makeEditor(text: "see https://example.com now")
      defer { window.close() }
      // 実機のイベントには、左右どちらの Cmd かを表すビット (左 Cmd なら 0x8) が乗る。
      let leftCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)
      for modifiers in [leftCommand, [.command, .capsLock]] {
        try click(view, at: try point(at: 10, in: view), in: window, modifiers: modifiers)
      }
      #expect(opened().count == 2)
    }

    @Test func URLの上から始めたCmdドラッグは開かずに選ぶ() throws {
      let text = "see https://example.com now"
      let (window, view, opened) = makeEditor(text: text)
      defer { window.close() }
      let (plainWindow, plain, _) = makeEditor(text: text)
      defer { plainWindow.close() }
      let start = try point(at: 10, in: view)
      let end = try point(at: 25, in: view)
      let drags: [(EditorView, NSWindow, NSEvent.ModifierFlags)] = [
        (view, window, .command), (plain, plainWindow, []),
      ]
      for (editor, editorWindow, modifiers) in drags {
        editor.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: editorWindow, modifiers: modifiers))
        editor.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: end, in: editorWindow, modifiers: modifiers))
        editor.mouseUp(with: try mouseEvent(.leftMouseUp, at: end, in: editorWindow, modifiers: modifiers))
      }
      #expect(opened().isEmpty)
      #expect(ranges(view) == ranges(plain))
      #expect(ranges(view) == [NSRange(location: 10, length: 15)])
    }

    @Test func URLを含む選択はCmdを押していてもドラッグで運べる() throws {
      let (window, view, opened) = makeEditor(text: "see https://example.com now")
      defer { window.close() }
      view.select([NSRange(location: 4, length: 19)], primary: 0)
      var began = false
      view.dragAndDrop.beginSession = { _, _, _ in began = true }
      let start = try point(at: 10, in: view)
      view.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: window, modifiers: .command))
      view.mouseDragged(
        with: try mouseEvent(
          .leftMouseDragged, at: NSPoint(x: start.x + 20, y: start.y), in: window, modifiers: .command))
      #expect(began)
      #expect(opened().isEmpty)
    }

    @Test func キーでないウィンドウでもURLの上のCmdクリックは受け取って開く() throws {
      let (window, view, opened) = makeEditor(text: "see https://example.com now", key: false)
      defer { window.close() }
      view.select([caret(0)], primary: 0)
      let onURL = try point(at: 10, in: view)
      let press = try mouseEvent(.leftMouseDown, at: onURL, in: window, modifiers: .command)
      #expect(view.acceptsFirstMouse(for: press))
      #expect(!view.acceptsFirstMouse(for: try mouseEvent(.leftMouseDown, at: onURL, in: window)))
      #expect(
        !view.acceptsFirstMouse(
          for: try mouseEvent(.leftMouseDown, at: try point(at: 1, in: view), in: window, modifiers: .command)))
      #expect(
        !view.acceptsFirstMouse(
          for: try mouseEvent(.leftMouseDown, at: onURL, in: window, modifiers: .command, clickCount: 2)))
      for modifiers: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option], [.command, .control]] {
        #expect(
          !view.acceptsFirstMouse(
            for: try mouseEvent(.leftMouseDown, at: onURL, in: window, modifiers: modifiers)))
      }
      try click(view, at: onURL, in: window)
      #expect(opened() == [URL(string: "https://example.com")!])
      #expect(ranges(view) == [caret(0)])
    }

    @Test func キーでないウィンドウではURLの上からのCmdドラッグで選ばない() throws {
      let (window, view, opened) = makeEditor(text: "see https://example.com now", key: false)
      defer { window.close() }
      view.select([caret(0)], primary: 0)
      let start = try point(at: 10, in: view)
      let end = try point(at: 25, in: view)
      view.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: window, modifiers: .command))
      view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: end, in: window, modifiers: .command))
      view.mouseUp(with: try mouseEvent(.leftMouseUp, at: end, in: window, modifiers: .command))
      #expect(opened().isEmpty)
      #expect(ranges(view) == [caret(0)])
    }

    @Test func キーでないウィンドウでもURLを含む選択はCmdドラッグで運べる() throws {
      let (window, view, opened) = makeEditor(text: "see https://example.com now", key: false)
      defer { window.close() }
      view.select([NSRange(location: 4, length: 19)], primary: 0)
      var began = false
      view.dragAndDrop.beginSession = { _, _, _ in began = true }
      let start = try point(at: 10, in: view)
      view.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: window, modifiers: .command))
      view.mouseDragged(
        with: try mouseEvent(
          .leftMouseDragged, at: NSPoint(x: start.x + 20, y: start.y), in: window, modifiers: .command))
      #expect(began)
      #expect(opened().isEmpty)
    }

    @Test func 押している間の小さな動きではドラッグにせず離したときに開く() throws {
      let (window, view, opened) = makeEditor(text: "see https://example.com now")
      defer { window.close() }
      view.select([caret(0)], primary: 0)
      let start = try point(at: 10, in: view)
      view.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: window, modifiers: .command))
      let nudged = NSPoint(x: start.x + 1, y: start.y)
      view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: nudged, in: window, modifiers: .command))
      view.mouseUp(with: try mouseEvent(.leftMouseUp, at: nudged, in: window, modifiers: .command))
      #expect(opened() == [URL(string: "https://example.com")!])
      #expect(ranges(view) == [caret(0)])
    }

    @Test func 別の行のURLはその行のurlトークンから探す() throws {
      let (window, view, opened) = makeEditor(text: "see https://example.com\nhttps://example.org now")
      defer { window.close() }
      try moveMouse(view, to: try point(at: 10, in: view), in: window)
      let second = try point(at: 30, in: view)
      try moveMouse(view, to: second, in: window)
      #expect(view.links.toolTip?.range == NSRange(location: 24, length: 19))
      try click(view, at: second, in: window)
      try click(view, at: try point(at: 10, in: view), in: window)
      #expect(opened() == [URL(string: "https://example.org")!, URL(string: "https://example.com")!])
    }

    @Test func 本文を書き換えた後は書き換えた後のURLを開く() throws {
      let (window, view, opened) = makeEditor(text: "see https://example.com now")
      defer { window.close() }
      try click(view, at: try point(at: 10, in: view), in: window)
      // 行の長さを変えずに書き換えても、書き換えた後のトークンから開く。
      view.select([NSRange(location: 12, length: 7)], primary: 0)
      view.type("elpmaxe")
      try click(view, at: try point(at: 10, in: view), in: window)
      #expect(opened() == [URL(string: "https://example.com")!, URL(string: "https://elpmaxe.com")!])
    }

    // MARK: - 下線

    @Test func 下線はCmdクリックで開く範囲と一致する() throws {
      // 代表的な入力と、そのうち下線の付く URL の数。
      let cases: [(text: String, urls: Int)] = [
        ("see https://example.com/a now", 1),
        ("## 見出しの https://example.com/h", 1),
        ("> 引用の https://example.com/q", 1),
        ("**太字の https://example.com/b**", 1),
        ("*斜体の https://example.com/e*", 1),
        ("[label](https://example.com/l)", 1),
        ("[https://example.com/x](https://example.com/y)", 1),
        ("# [見出しのリンク](https://example.com/hl)", 1),
        ("<https://example.com/auto>", 1),
        ("https://example.comを参照", 1),
        ("https://en.wikipedia.org/wiki/M*A*S*H", 1),
        ("see `https://example.com/code` now", 0),
        ("```\nhttps://example.com/fence\n```", 0),
        ("see example.com and www.example.com", 0),
        ("a https://a.example\n> b **https://b.example** [c](https://c.example) `https://d.example`", 3),
      ]
      for (text, urls) in cases {
        let (window, view, _) = makeEditor(text: text)
        defer { window.close() }
        let storage = view.layout.storage
        let underlined = underlinedRanges(storage)
        #expect(underlined.count == urls, "\(text)")
        var openable: [NSRange] = []
        for index in 0..<storage.length {
          let range = view.link(containing: index)?.range
          if let range, openable.last != range { openable.append(range) }
          let underline = storage.attribute(.underlineStyle, at: index, effectiveRange: nil)
          #expect((underline != nil) == (range != nil), "\(text) index=\(index)")
        }
        #expect(underlined == openable, "\(text)")
      }
    }

    // MARK: - これまでどおりのクリック

    nonisolated static let plainClickScenarios: [PlainClickScenario] = [
      // スキームの無い URL と、http・https でないスキームの URL
      .init("see example.com now", click: 6),
      .init("see ftp://example.com now", click: 8),
      // Markdown のリンクのラベルと記号、自動リンクの括弧
      .init("[label](https://example.com)", click: 2),
      .init("[label](https://example.com)", click: 7),
      .init("x <https://example.com>", click: 2),
      .init("x <https://example.com>", click: 22),
      // コードの中の URL
      .init("see `https://example.com` now", click: 8),
      .init("```\nhttps://example.com\n```", click: 8),
      // 太字の記号
      .init("x **https://example.com**", click: 3),
      // URL の後ろの文字
      .init("https://example.comを参照", click: 20),
      .init("see https://example.com now", click: 25),
      // URL の直前の文字
      .init("see https://example.com now", click: 3),
      .init("x (https://example.com)", click: 2),
      // 右から左に書く文字の中の URL の隣の文字
      .init("אבג https://example.com דהו", click: 2),
      .init("אבג https://example.com דהו", click: 24),
    ]

    @Test(arguments: plainClickScenarios)
    func URLでない文字の上のCmdクリックは普通のクリックになる(scenario: PlainClickScenario) throws {
      let (window, view, opened) = makeEditor(text: scenario.text)
      defer { window.close() }
      let target = try point(at: scenario.click, in: view)
      try click(view, at: target, in: window)
      #expect(opened().isEmpty)
      let (plainWindow, plain, _) = makeEditor(text: scenario.text)
      defer { plainWindow.close() }
      try click(plain, at: target, in: plainWindow, modifiers: [])
      #expect(ranges(view) == ranges(plain))
      #expect(ranges(view).first?.location != 0)
    }

    @Test func URLの文字に掛からない位置のCmdクリックでは開かない() throws {
      let text = "https://example.com\nhttps://example.org"
      let (window, view, opened) = makeEditor(text: text)
      defer { window.close() }
      let lines = view.layout.visualLines()
      for line in lines.prefix(2) {
        // 行の右の余白
        let right = view.convert(
          NSPoint(x: line.frame.maxX + 100 + view.textOrigin.x, y: line.frame.midY + view.textOrigin.y),
          to: nil)
        try click(view, at: right, in: window)
      }
      // 本文より下の余白
      let below = view.convert(NSPoint(x: 20, y: 250), to: nil)
      try click(view, at: below, in: window)
      #expect(opened().isEmpty)
      #expect(ranges(view) == [caret((text as NSString).length)])
    }

    @Test(arguments: [
      NSEvent.ModifierFlags(), [.command, .shift], [.command, .option], [.command, .control],
    ])
    func Cmdだけでないクリックでは開かない(modifiers: NSEvent.ModifierFlags) throws {
      let text = "see https://example.com now"
      let (window, view, opened) = makeEditor(text: text)
      defer { window.close() }
      view.select([caret(1)], primary: 0)
      let target = try point(at: 10, in: view)
      try click(view, at: target, in: window, modifiers: modifiers)
      #expect(opened().isEmpty)
      let (plainWindow, plain, _) = makeEditor(text: text)
      defer { plainWindow.close() }
      plain.select([caret(1)], primary: 0)
      try click(plain, at: target, in: plainWindow, modifiers: modifiers.subtracting(.command))
      #expect(ranges(view) == ranges(plain))
      #expect(ranges(view) != [caret(1)])
    }

    // MARK: - ツールチップ

    private func moveMouse(_ view: EditorView, to point: NSPoint, in window: NSWindow) throws {
      view.mouseMoved(with: try mouseEvent(.mouseMoved, at: point, in: window))
    }

    /// `point` (ウィンドウの座標) に付いているツールチップの文言。
    private func toolTip(_ view: EditorView, at point: NSPoint) -> String? {
      let local = view.convert(point, from: nil)
      guard let toolTip = view.links.toolTip,
        let index = toolTip.rects.firstIndex(where: { $0.contains(local) })
      else { return nil }
      return view.view(view, stringForToolTip: toolTip.tags[index], point: local, userData: nil)
    }

    @Test func URLの上にマウスを置くとツールチップを出す() throws {
      let text = "see https://example.com and https://example.org"
      let (window, view, _) = makeEditor(text: text)
      defer { window.close() }
      let first = try point(at: 10, in: view)
      let second = try point(at: 35, in: view)
      let between = try point(at: 25, in: view)
      try moveMouse(view, to: first, in: window)
      #expect(toolTip(view, at: first) == "⌘-click to open link")
      #expect(toolTip(view, at: try point(at: 4, in: view)) == "⌘-click to open link")
      #expect(toolTip(view, at: between) == nil)
      // URL の外へ動くと外し、別の URL に入るとその URL に付け替える。
      try moveMouse(view, to: between, in: window)
      #expect(view.links.toolTip == nil)
      try moveMouse(view, to: second, in: window)
      #expect(toolTip(view, at: second) == "⌘-click to open link")
      #expect(toolTip(view, at: first) == nil)
      view.mouseExited(with: try mouseEvent(.mouseMoved, at: second, in: window))
      #expect(view.links.toolTip == nil)
    }

    @Test func 後の段落のURLにもその文字の上にだけツールチップを出す() throws {
      let text = "first line here\nhttps://example.com"
      let (window, view, _) = makeEditor(text: text)
      defer { window.close() }
      let onURL = try point(at: 20, in: view)
      try moveMouse(view, to: onURL, in: window)
      #expect(toolTip(view, at: onURL) == "⌘-click to open link")
      #expect(toolTip(view, at: try point(at: 4, in: view)) == nil)
    }

    /// URL の行がどれも見えているなら、前後の表示行が隠れていてもスクロールの後に付け直さない。
    /// `bottom` なら URL の行の下端を見えている所の下端に、そうでなければ上端を上端に合わせ、
    /// `offset` だけずらす。
    @Test(arguments: [
      // URL の行の上が切れている
      ("see https://example.com now" + String(repeating: "\nline", count: 100), false, 4.0),
      // 長い段落の終わりの URL で、段落の前の表示行が隠れている
      (
        String(repeating: "word ", count: 400) + "https://example.com now"
          + String(repeating: "\nline", count: 100), false, -20.0
      ),
      // 段落の中の行区切りの直後の URL で、そのすぐ前の表示行から隠れている
      (
        String(repeating: "word ", count: 400) + "\u{2028}https://example.com now"
          + String(repeating: "\nline", count: 100), false, 0.5
      ),
      // 長い段落の始めの URL で、段落の後の表示行が隠れている
      (
        String(repeating: "line\n", count: 20) + "https://example.com "
          + String(repeating: "word ", count: 400), false, -20.0
      ),
      // 同じく、URL の行のすぐ下から隠れている
      (
        String(repeating: "line\n", count: 20) + "https://example.com "
          + String(repeating: "word ", count: 400), true, -1.0
      ),
    ] as [(String, Bool, CGFloat)])
    func 同じURLの中で動いてもツールチップを付け直さない(
      text: String, bottom: Bool, offset: CGFloat
    ) throws {
      let (window, view, _) = makeEditor(text: text)
      defer { window.close() }
      let url = (text as NSString).range(of: "https://example.com")
      let line = try #require(
        view.layout.selectionRects(NSRange(location: url.location, length: 1)).first)
      let y =
        bottom
        ? line.maxY - view.visibleRect.height : line.minY
      view.scroll(NSPoint(x: 0, y: y + view.textOrigin.y + offset))
      try moveMouse(view, to: try point(at: url.location + 4, in: view), in: window)
      let tags = try #require(view.links.toolTip?.tags)
      #expect(!tags.isEmpty)
      view.scroll(NSPoint(x: 0, y: view.visibleRect.minY + 2))
      try moveMouse(view, to: try point(at: url.location + 11, in: view), in: window)
      #expect(view.links.toolTip?.tags == tags)
    }

    @Test func URLの上からビューに入るとツールチップを出す() throws {
      let (window, view, _) = makeEditor(text: "see https://example.com now")
      defer { window.close() }
      let onURL = try point(at: 10, in: view)
      view.mouseEntered(with: try mouseEvent(.mouseMoved, at: onURL, in: window))
      #expect(toolTip(view, at: onURL) == "⌘-click to open link")
    }

    @Test func ウィンドウから外れるとツールチップを外す() throws {
      let (window, view, _) = makeEditor(text: "see https://example.com now")
      defer { window.close() }
      try moveMouse(view, to: try point(at: 10, in: view), in: window)
      #expect(view.links.toolTip != nil)
      let scrollView = try #require(view.enclosingScrollView)
      scrollView.documentView = nil
      #expect(view.window == nil)
      #expect(view.links.toolTip == nil)
    }

    @Test func 見えている所の全体でマウスの出入りと移動を受け取る() {
      let (window, view, _) = makeEditor(text: "")
      defer { window.close() }
      #expect(
        view.trackingAreas.contains {
          $0.owner === view
            && $0.options.isSuperset(of: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect])
        })
    }

    @Test func 幅が変わるとツールチップを外す() throws {
      let (window, view, _) = makeEditor(text: "see https://example.com now")
      defer { window.close() }
      try moveMouse(view, to: try point(at: 8, in: view), in: window)
      #expect(view.links.toolTip != nil)
      view.setFrameSize(NSSize(width: view.frame.width - 50, height: view.frame.height))
      #expect(view.links.toolTip == nil)
    }

    @Test func ツールチップはurlトークンの文字の上にだけ付く() throws {
      let text = """
        [https://a.example](https://b.example)
        `https://c.example` and https://d.example
        <https://e.example> x@example.com www.f.example
        ## see **https://g.example**
        see example.com
        """
      let string = text as NSString
      let urls = ["https://b.example", "https://d.example", "https://e.example", "https://g.example"]
        .map { string.range(of: $0, options: .backwards) }
      let (window, view, _) = makeEditor(text: text)
      defer { window.close() }
      for index in 0..<string.length where string.character(at: index) != 0x0A {
        try moveMouse(view, to: try point(at: index, in: view), in: window)
        #expect(
          view.links.toolTip?.range == urls.first { NSLocationInRange(index, $0) },
          "index=\(index)")
      }
      // URL で終わる行の右の余白へ URL の上から動くと外す。
      try moveMouse(view, to: try point(at: NSMaxRange(urls[1]) - 1, in: view), in: window)
      #expect(view.links.toolTip?.range == urls[1])
      let line = try #require(
        view.layout.visualLines().first { NSMaxRange($0.range) == NSMaxRange(urls[1]) + 1 })
      let right = view.convert(
        NSPoint(x: line.frame.maxX + 100 + view.textOrigin.x, y: line.frame.midY + view.textOrigin.y),
        to: nil)
      try moveMouse(view, to: right, in: window)
      #expect(view.links.toolTip == nil)
    }

    @Test func 折り返したURLは行ごとに文字の上にだけツールチップを付けて全体を開く() throws {
      let url = "https://example.com/" + String(repeating: "a", count: 30) + "/"
        + String(repeating: "b", count: 60) + "/cc"
      let text = "x \(url) y"
      let (window, view, opened) = makeEditor(text: text)
      defer { window.close() }
      let range = (text as NSString).range(of: url)
      let firstLine = try #require(view.layout.selectionRects(range).first)
      let lastCharacter = try point(at: NSMaxRange(range) - 1, in: view)
      try moveMouse(view, to: lastCharacter, in: window)
      #expect(view.links.toolTip?.range == range)
      #expect((view.links.toolTip?.rects.count ?? 0) > 1)
      #expect(toolTip(view, at: lastCharacter) == "⌘-click to open link")
      // 1 行目の URL の最後の文字より右の、選択なら覆う余白
      let firstLineEnd = (range.location..<NSMaxRange(range))
        .flatMap { view.layout.selectionRects(NSRange(location: $0, length: 1)) }
        .filter { $0.minY == firstLine.minY }.map(\.maxX).max() ?? 0
      let gap = view.convert(
        NSPoint(x: firstLineEnd + 4 + view.textOrigin.x, y: firstLine.midY + view.textOrigin.y), to: nil)
      #expect(firstLineEnd + 4 < firstLine.maxX)
      #expect(toolTip(view, at: gap) == nil)
      try click(view, at: gap, in: window)
      #expect(opened().isEmpty)
      try click(view, at: lastCharacter, in: window)
      #expect(opened().map(\.absoluteString) == [url])
    }

    @Test func 見えない所まで続くURLは見えている行にだけツールチップを付けスクロール後に付け直す() throws {
      let url = "https://example.com/" + String(repeating: "abcdefg/", count: 1_000)
      let text = "[x](\(url))"
      let (window, view, opened) = makeEditor(text: text)
      defer { window.close() }
      let range = (text as NSString).range(of: url)
      let scrollView = try #require(view.enclosingScrollView)
      #expect(view.frame.height > scrollView.contentSize.height * 2)
      try moveMouse(view, to: try point(at: range.location, in: view), in: window)
      let rects = try #require(view.links.toolTip?.rects)
      #expect(!rects.isEmpty)
      #expect(rects.allSatisfy { $0.intersects(view.visibleRect) })
      // スクロールしていなければ、同じ URL の中で動いても付け直さない。
      let tags = view.links.toolTip?.tags
      try moveMouse(view, to: try point(at: range.location + 5, in: view), in: window)
      #expect(view.links.toolTip?.tags == tags)
      // 見えない所の文字には、スクロールしてマウスを動かすまで付けない。
      let below = NSMaxRange(range) - 1
      let lowRect = try #require(view.layout.selectionRects(NSRange(location: below, length: 1)).first)
      view.scroll(NSPoint(x: 0, y: lowRect.minY + view.textOrigin.y - 100))
      let target = try point(at: below, in: view)
      #expect(toolTip(view, at: target) == nil)
      try moveMouse(view, to: target, in: window)
      #expect(toolTip(view, at: target) == "⌘-click to open link")
      #expect(view.links.toolTip?.rects.allSatisfy { $0.intersects(view.visibleRect) } == true)
      // 戻ると、上の見えていなかった行に付け直す。
      view.scroll(.zero)
      let top = try point(at: range.location, in: view)
      #expect(toolTip(view, at: top) == nil)
      try moveMouse(view, to: top, in: window)
      #expect(toolTip(view, at: top) == "⌘-click to open link")
      try click(view, at: top, in: window)
      #expect(opened().map(\.absoluteString) == [url])
    }

    @Test func ツールチップはCmdクリックで開く文字の上に付く() throws {
      // 幅の無い文字の位置で折り返すと、その前後の文字の矩形が崩れる。
      let texts = [
        "x https://example.com/" + String(repeating: "a", count: 30) + "\u{200B}"
          + String(repeating: "b", count: 60),
        "see https://he.wikipedia.org/wiki/עברית now",
      ]
      for text in texts {
        let (window, view, _) = makeEditor(text: text)
        defer { window.close() }
        let url = try #require(view.link(containing: (text as NSString).range(of: "https").location))
        try moveMouse(view, to: try point(at: url.range.location, in: view), in: window)
        #expect(view.links.toolTip?.range == url.range)
        for index in url.range.location..<NSMaxRange(url.range) {
          for fraction in [0.1, 0.5, 0.9] {
            let target = try point(at: index, fraction: fraction, in: view)
            let opens = view.link(at: view.containerPoint(window: target)) != nil
            #expect((toolTip(view, at: target) != nil) == opens, "\(index) \(fraction)")
          }
        }
      }
    }

    @Test func 本文が変わるとツールチップを外す() throws {
      let (window, view, _) = makeEditor(text: "https://example.com")
      defer { window.close() }
      try moveMouse(view, to: try point(at: 3, in: view), in: window)
      #expect(view.links.toolTip != nil)
      view.select([caret(0)], primary: 0)
      view.type("x ")
      #expect(view.links.toolTip == nil)
    }
  }
}
