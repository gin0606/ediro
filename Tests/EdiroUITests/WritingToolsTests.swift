import AppKit
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったウィンドウとコントローラもテストの間は生かしておく。
private var retainedEditors: [(NSWindow, EditorTextController)] = []

/// コーディネータへの知らせを記録する。
private final class RecordingCoordinator: NSWritingToolsCoordinator {
  enum Call: Equatable {
    case update(NSRange, String, NSWritingToolsCoordinator.TextUpdateReason, UUID)
    case reflow(UUID)
    case stop
    case cancel([UUID])
  }

  var calls: [Call] = []

  override func updateRange(
    _ range: NSRange, with replacementText: NSAttributedString,
    reason: NSWritingToolsCoordinator.TextUpdateReason, forContextWithIdentifier contextID: UUID
  ) {
    calls.append(.update(range, replacementText.string, reason, contextID))
  }

  override func updateForReflowedTextInContextWithIdentifier(_ contextID: UUID) {
    calls.append(.reflow(contextID))
  }

  override func stopWritingTools() {
    calls.append(.stop)
  }

  #if canImport(AppKit, _version: 2700)
  /// 文法の誤りを示すアニメーションは、始めたことにして番号だけを返す。
  @available(macOS 27.0, *)
  override func startTextAnimation(
    _ textAnimation: NSWritingToolsCoordinator.TextAnimation, for range: NSRange,
    in context: NSWritingToolsCoordinator.Context, writingDirection: NSWritingDirection
  ) -> UUID? {
    UUID()
  }

  @available(macOS 27.0, *)
  override func cancelTextAnimations(identifiers: [UUID]) {
    calls.append(.cancel(identifiers))
  }
  #endif
}

extension AppKitTests {
  struct WritingToolsTests {
    private func makeEditor(text: String) -> (NSWindow, EditorView) {
      let controller = EditorTextController(state: makeState(text: text))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = controller.scrollView
      controller.editorView.setFrameSize(controller.scrollView.contentSize)
      window.makeFirstResponder(controller.editorView)
      window.orderFront(nil)
      retainedEditors.append((window, controller))
      return (window, controller.editorView)
    }

    private func ranges(_ view: EditorView) -> [NSRange] {
      view.session.selections.map { view.nsRange(of: $0.range) }
    }

    /// 委譲が同期で返したコンテキスト。
    private func context(
      _ view: EditorView, scope: NSWritingToolsCoordinator.ContextScope = .userSelection
    ) throws -> NSWritingToolsCoordinator.Context {
      let coordinator = try #require(view.writingToolsCoordinator)
      nonisolated(unsafe) var result: [NSWritingToolsCoordinator.Context] = []
      view.writingToolsCoordinator(coordinator, requestsContextsFor: scope) { result = $0 }
      try #require(result.count == 1)
      return result[0]
    }

    /// 委譲で置き換え、委譲が返した文字列を返す。置き換えなければ nil。
    @discardableResult
    private func replace(
      _ view: EditorView, _ range: NSRange, in context: NSWritingToolsCoordinator.Context,
      with text: String,
      reason: NSWritingToolsCoordinator.TextReplacementReason = .interactive
    ) throws -> String? {
      let coordinator = try #require(view.writingToolsCoordinator)
      nonisolated(unsafe) var returned: NSAttributedString?
      nonisolated(unsafe) var completed = false
      view.writingToolsCoordinator(
        coordinator, replace: range, in: context, proposedText: NSAttributedString(string: text),
        reason: reason, animationParameters: nil
      ) {
        returned = $0
        completed = true
      }
      #expect(completed)
      return returned?.string
    }

    private func select(
      _ view: EditorView, _ ranges: [NSRange], in context: NSWritingToolsCoordinator.Context
    ) throws {
      let coordinator = try #require(view.writingToolsCoordinator)
      nonisolated(unsafe) var completed = false
      view.writingToolsCoordinator(
        coordinator, select: ranges.map { NSValue(range: $0) }, in: context
      ) { completed = true }
      #expect(completed)
    }

    private func changeState(_ view: EditorView, to state: NSWritingToolsCoordinator.State) throws {
      let coordinator = try #require(view.writingToolsCoordinator)
      nonisolated(unsafe) var completed = false
      view.writingToolsCoordinator(coordinator, willChangeTo: state) { completed = true }
      #expect(completed)
    }

    /// 本文の範囲の、ビューの座標での選択の矩形。
    private func viewRects(_ view: EditorView, _ range: NSRange) -> [CGRect] {
      view.layout.selectionRects(range).map {
        $0.offsetBy(dx: view.textOrigin.x, dy: view.textOrigin.y)
      }
    }

    /// 矩形の中で、背景と色の違う画素の数。
    private func ink(_ view: EditorView, in rect: CGRect) throws -> Int {
      view.layoutSubtreeIfNeeded()
      let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: rep)
      let scale = CGFloat(rep.pixelsWide) / view.bounds.width
      let background = try #require(view.backgroundColor.usingColorSpace(.deviceRGB))
      var count = 0
      for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
          guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
          if abs(color.brightnessComponent - background.brightnessComponent) > 0.2 { count += 1 }
        }
      }
      return count
    }

    /// 矩形の中の、背景との明るさの差の合計。
    private func darkness(_ view: EditorView, in rect: CGRect) throws -> CGFloat {
      let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: rep)
      let scale = CGFloat(rep.pixelsWide) / view.bounds.width
      let background = try #require(view.backgroundColor.usingColorSpace(.deviceRGB))
      var total: CGFloat = 0
      for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
          guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
          total += abs(color.brightnessComponent - background.brightnessComponent)
        }
      }
      return total
    }

    /// プレビューの画像の文字の画素と、ビューに描いた同じ矩形の文字の画素の重なり (Jaccard 係数)。
    private func overlap(_ preview: NSTextPreview, with view: EditorView) throws -> Double {
      let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: rep)
      let viewScale = CGFloat(rep.pixelsWide) / view.bounds.width
      let image = NSBitmapImageRep(cgImage: preview.previewImage)
      // 画像はウィンドウの倍率で描き、幅と高さを切り上げている。
      let imageScale = view.window?.backingScaleFactor ?? 2
      let background = try #require(view.backgroundColor.usingColorSpace(.deviceRGB))
      var both = 0, either = 0
      for x in 0..<image.pixelsWide {
        for y in 0..<image.pixelsHigh {
          let inImage = (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
          let point = CGPoint(
            x: preview.presentationFrame.minX + CGFloat(x) / imageScale,
            y: preview.presentationFrame.minY + CGFloat(y) / imageScale)
          let color = rep.colorAt(x: Int(point.x * viewScale), y: Int(point.y * viewScale))?
            .usingColorSpace(.deviceRGB)
          let inView = color.map {
            abs($0.brightnessComponent - background.brightnessComponent) > 0.5
          } ?? false
          if inImage && inView { both += 1 }
          if inImage || inView { either += 1 }
        }
      }
      return either == 0 ? 0 : Double(both) / Double(either)
    }

    /// 画像の中で、透明でない画素の数と、緑が強い画素の数。
    private func pixels(_ image: CGImage) -> (opaque: Int, green: Int) {
      let rep = NSBitmapImageRep(cgImage: image)
      var opaque = 0, green = 0
      for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
          guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
            color.alphaComponent > 0.1
          else { continue }
          opaque += 1
          if color.greenComponent > color.redComponent + 0.2 { green += 1 }
        }
      }
      return (opaque, green)
    }

    // MARK: - コーディネータ

    /// Writing Tools が使えない環境では確かめられないので飛ばす。
    private static let writingToolsAvailable = ConditionTrait.enabled(
      "Writing Tools が使えない環境では確かめられない"
    ) { await MainActor.run { NSWritingToolsCoordinator.isWritingToolsAvailable } }

    @Test(writingToolsAvailable) func ウィンドウに載せたエディタのWritingToolsは完全版になる() throws {
      let (window, view) = makeEditor(text: "Hello world.")
      defer { window.close() }
      let coordinator = try #require(view.writingToolsCoordinator)
      #expect(coordinator.behavior == .complete)
      #expect(coordinator.preferredResultOptions == .plainText)
      #expect(coordinator.resultOptions == .plainText)
      #expect(coordinator.delegate === view)
    }

    @Test func 検査のクライアントはWriting_Toolsの扱いをコーディネータの値で伝える() throws {
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      let coordinator = try #require(view.writingToolsCoordinator)
      let checker = view.textChecker
      #expect(checker.writingToolsBehavior == .complete)
      #expect(checker.allowedWritingToolsResultOptions == .plainText)
      checker.writingToolsBehavior = .limited
      // エディタ全体の扱いと、書式なしのテキストだけを受け取ることは、ここから変えさせない。
      checker.allowedWritingToolsResultOptions = [.plainText, .list]
      #expect(coordinator.preferredBehavior == .complete)
      #expect(coordinator.preferredResultOptions == .plainText)
    }

    // MARK: - 本文と選択

    @Test func 選択があればその段落をコンテキストにして選択の範囲を渡す() throws {
      let text = "first line\nsecond line here\nthird"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let second = (text as NSString).range(of: "second line here\n")
      view.select([NSRange(location: second.location + 7, length: 4)], primary: 0)
      let context = try self.context(view)
      #expect(context.attributedString.string == "second line here\n")
      #expect(context.range == NSRange(location: 7, length: 4))
    }

    @Test func 選択が無いか全文の依頼なら本文全体を渡す() throws {
      let text = "first line\nsecond"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([NSRange(location: 3, length: 0)], primary: 0)
      let full = NSRange(location: 0, length: (text as NSString).length)
      for scope in [NSWritingToolsCoordinator.ContextScope.userSelection, .fullDocument] {
        let context = try self.context(view, scope: scope)
        #expect(context.attributedString.string == text)
        #expect(context.range == full)
      }
      view.select([NSRange(location: 0, length: 5)], primary: 0)
      let visible = try self.context(view, scope: .visibleArea)
      #expect(visible.attributedString.string == text)
      #expect(visible.range == full)
    }

    @Test func 見えている範囲の依頼では見えている文字とその段落を渡す() throws {
      let text = (0..<80).map { "line \($0)" }.joined(separator: "\n")
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.scroll(NSPoint(x: 0, y: 400))
      let visible = view.visibleRect
      try #require(visible.minY > 0)
      let context = try self.context(view, scope: .visibleArea)
      let record = try #require(view.writingTools.contexts[context.identifier])
      let range = NSRange(
        location: record.start + context.range.location, length: context.range.length)
      let string = text as NSString
      // 見えている最初と最後の行の文字を含み、上の見えない行と、下の見えない行を含まない。
      let top = view.layout.offset(at: CGPoint(x: 1, y: visible.minY + 4 - view.textOrigin.y))
      let bottom = view.layout.offset(at: CGPoint(x: 1, y: visible.maxY - 4 - view.textOrigin.y))
      #expect(NSLocationInRange(top, range))
      #expect(NSLocationInRange(bottom, range))
      #expect(!NSLocationInRange(string.range(of: "line 0\n").location, range))
      #expect(!NSLocationInRange(string.range(of: "line 79").location, range))
      // 文字列は、範囲に掛かる段落。
      let span = string.paragraphRange(for: range)
      #expect(record.start == span.location)
      #expect(context.attributedString.string == string.substring(with: span))
    }

    @Test func 見えている範囲の依頼では折り返した長い段落の見えている所だけを扱わせる() throws {
      let text = String(repeating: "word ", count: 2000)
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.scroll(NSPoint(x: 0, y: 2000))
      let context = try self.context(view, scope: .visibleArea)
      let record = try #require(view.writingTools.contexts[context.identifier])
      #expect(record.start == 0)
      #expect(record.length == (text as NSString).length)
      let top = view.layout.offset(at: CGPoint(x: 1, y: view.visibleRect.minY + 4 - view.textOrigin.y))
      #expect(context.range.location > 0)
      #expect(NSLocationInRange(top, context.range))
      #expect(NSMaxRange(context.range) < record.length)
    }

    @Test func 複数の選択では主の選択を渡す() throws {
      let text = "alpha beta\ngamma delta"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let gamma = (text as NSString).range(of: "gamma")
      view.select([NSRange(location: 0, length: 5), gamma], primary: 1)
      let context = try self.context(view)
      #expect(context.attributedString.string == "gamma delta")
      #expect(context.range == NSRange(location: 0, length: 5))
    }

    @Test func コンテキストを渡す前に変換中の文字を確定する() throws {
      let (window, view) = makeEditor(text: "ab")
      defer { window.close() }
      view.select([NSRange(location: 2, length: 0)], primary: 0)
      view.setMarkedText(
        "か", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      let context = try self.context(view, scope: .fullDocument)
      #expect(!view.hasMarkedText())
      #expect(context.attributedString.string == "abか")
    }

    @Test func 置き換えはエンジンの本文に入り入れた文字を返す() throws {
      let text = "intro\nThis are a test.\nend"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let sentence = (text as NSString).range(of: "This are a test.")
      view.select([sentence], primary: 0)
      let context = try self.context(view)
      // ほかの選択は置き換えに合わせてずれる。置き換えた範囲の終わりのキャレットは、入れた
      // 文字の後ろに移る。
      view.select(
        [NSRange(location: 2, length: 0), NSRange(location: 14, length: 0), NSRange(location: 24, length: 0)],
        primary: 0)
      #expect(try replace(view, NSRange(location: 5, length: 3), in: context, with: "is") == "is")
      #expect(view.text == "intro\nThis is a test.\nend")
      #expect(
        ranges(view) == [
          NSRange(location: 2, length: 0), NSRange(location: 13, length: 0),
          NSRange(location: 23, length: 0),
        ])
      // コンテキストの後ろの位置は、置き換えで変わった長さだけずれる。
      #expect(try replace(view, NSRange(location: 14, length: 1), in: context, with: "!") == "!")
      #expect(view.text == "intro\nThis is a test!\nend")
      // 改行は LF に揃えて入れ、揃えた文字を返す。
      #expect(try replace(view, NSRange(location: 0, length: 4), in: context, with: "A\r\nB") == "A\nB")
      #expect(view.text == "intro\nA\nB is a test!\nend")
      #expect(view.layout.storage.string == view.text)
    }

    @Test func 範囲外や変換中の置き換えは断る() throws {
      let (window, view) = makeEditor(text: "abc def")
      defer { window.close() }
      let context = try self.context(view, scope: .fullDocument)
      #expect(try replace(view, NSRange(location: 5, length: 9), in: context, with: "x") == nil)
      let unknown = NSWritingToolsCoordinator.Context(
        attributedString: NSAttributedString(string: "abc def"), range: NSRange(location: 0, length: 7))
      #expect(try replace(view, NSRange(location: 0, length: 1), in: unknown, with: "x") == nil)
      view.select([NSRange(location: 7, length: 0)], primary: 0)
      view.setMarkedText(
        "か", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(try replace(view, NSRange(location: 0, length: 1), in: context, with: "x") == nil)
      #expect(view.text == "abc defか")
    }

    @Test func Writing_Toolsがコンテキストの端に入れた文字はコンテキストに含める() throws {
      let (window, view) = makeEditor(text: "abc")
      defer { window.close() }
      let context = try self.context(view, scope: .fullDocument)
      try replace(view, NSRange(location: 0, length: 0), in: context, with: "X")
      #expect(try replace(view, NSRange(location: 0, length: 1), in: context, with: "Y") == "Y")
      #expect(view.text == "Yabc")
      try replace(view, NSRange(location: 4, length: 0), in: context, with: "!")
      #expect(try replace(view, NSRange(location: 5, length: 0), in: context, with: "?") == "?")
      #expect(view.text == "Yabc!?")
    }

    @Test func 文字の途中を指す範囲は置き換えない() throws {
      let text = "a😀b and more"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let context = try self.context(view, scope: .fullDocument)
      #expect(try replace(view, NSRange(location: 0, length: 2), in: context, with: "x") == nil)
      #expect(try replace(view, NSRange(location: 2, length: 1), in: context, with: "x") == nil)
      #expect(view.text == text)
    }

    @Test func 置き換えでは表示を送らない() throws {
      let text = (0..<80).map { "line \($0)" }.joined(separator: "\n")
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([NSRange(location: (text as NSString).length, length: 0)], primary: 0)
      view.scroll(.zero)
      let before = view.visibleRect.origin
      let context = try self.context(view, scope: .fullDocument)
      try replace(view, NSRange(location: 0, length: 4), in: context, with: "LINE")
      try select(view, [NSRange(location: 0, length: 4)], in: context)
      #expect(view.visibleRect.origin == before)
      // 見えていない所を選ぶときは、その選択まで送る。
      let last = (text as NSString).range(of: "line 79")
      try select(view, [last], in: context)
      #expect(view.visibleRect.intersects(viewRects(view, last)[0]))
    }

    @Test func 変換中は選択を動かさない() throws {
      let (window, view) = makeEditor(text: "abc def")
      defer { window.close() }
      let context = try self.context(view, scope: .fullDocument)
      view.select([NSRange(location: 7, length: 0)], primary: 0)
      view.setMarkedText(
        "か", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      let selected = ranges(view)
      try select(view, [NSRange(location: 0, length: 3)], in: context)
      #expect(ranges(view) == selected)
      #expect(view.hasMarkedText())
    }

    @Test func 選択はコンテキストの位置から本文の選択になる() throws {
      let text = "one\ntwo three\nfour"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([(text as NSString).range(of: "three")], primary: 0)
      let context = try self.context(view)
      try select(view, [NSRange(location: 0, length: 3)], in: context)
      #expect(ranges(view) == [NSRange(location: 4, length: 3)])
      try select(view, [NSRange(location: 0, length: 0), NSRange(location: 4, length: 5)], in: context)
      #expect(ranges(view) == [NSRange(location: 4, length: 0), NSRange(location: 8, length: 5)])
    }

    // MARK: - 取り消し

    @Test func Writing_Toolsの一回分は一回の取り消しで戻る() throws {
      let text = "Ths is a tst of the edtor."
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([NSRange(location: 0, length: 0)], primary: 0)
      view.type("> ")
      let typed = view.text
      let context = try self.context(view, scope: .fullDocument)
      try changeState(view, to: .interactiveStreaming)
      try replace(view, NSRange(location: 2, length: 3), in: context, with: "This")
      try select(view, [NSRange(location: 2, length: 4)], in: context)
      try replace(view, NSRange(location: 12, length: 3), in: context, with: "test")
      try changeState(view, to: .interactiveResting)
      try select(view, [NSRange(location: 12, length: 4)], in: context)
      try replace(view, NSRange(location: 24, length: 5), in: context, with: "editor")
      try changeState(view, to: .inactive)
      #expect(view.text == "> This is a test of the editor.")

      view.undo(nil)
      #expect(view.text == typed)
      view.redo(nil)
      #expect(view.text == "> This is a test of the editor.")
      view.undo(nil)
      view.undo(nil)
      #expect(view.text == text)

      // 一回分が終わった後の編集は、別に取り消す。
      view.redo(nil)
      view.redo(nil)
      view.select([NSRange(location: (view.text as NSString).length, length: 0)], primary: 0)
      view.type("!")
      view.undo(nil)
      #expect(view.text == "> This is a test of the editor.")
    }

    @Test func 続けて行ったWriting_Toolsはそれぞれ一回の取り消しで戻る() throws {
      let (window, view) = makeEditor(text: "a b")
      defer { window.close() }
      for (index, word) in ["x", "y"].enumerated() {
        let context = try self.context(view, scope: .fullDocument)
        try changeState(view, to: .interactiveResting)
        try replace(view, NSRange(location: index * 2, length: 1), in: context, with: word)
        try select(view, [NSRange(location: 0, length: 0)], in: context)
        try changeState(view, to: .inactive)
      }
      #expect(view.text == "x y")
      view.undo(nil)
      #expect(view.text == "x b")
      view.undo(nil)
      #expect(view.text == "a b")
    }

    @Test func 動いていないときの置き換えはそれぞれ一回の取り消しで戻る() throws {
      for reason in [NSWritingToolsCoordinator.TextReplacementReason.interactive, .noninteractive] {
        let (window, view) = makeEditor(text: "a b c")
        defer { window.close() }
        let context = try self.context(view, scope: .fullDocument)
        try replace(view, NSRange(location: 0, length: 1), in: context, with: "x", reason: reason)
        try replace(view, NSRange(location: 2, length: 1), in: context, with: "y", reason: reason)
        view.undo(nil)
        #expect(view.text == "x b c", "\(reason.rawValue)")
      }
    }

    @Test func 新しい依頼は前の置き換えと別に取り消す() throws {
      let (window, view) = makeEditor(text: "a b c")
      defer { window.close() }
      // 終わったという知らせが無いまま、次の依頼が来る。
      var context = try self.context(view, scope: .fullDocument)
      try changeState(view, to: .interactiveResting)
      try replace(view, NSRange(location: 0, length: 1), in: context, with: "x")
      context = try self.context(view, scope: .fullDocument)
      try replace(view, NSRange(location: 2, length: 1), in: context, with: "y")
      view.undo(nil)
      #expect(view.text == "x b c")
    }

    @Test func 実行中に変換して確定しても後の置き換えはまとめて取り消す() throws {
      let (window, view) = makeEditor(text: "a b c")
      defer { window.close() }
      let context = try self.context(view, scope: .fullDocument)
      try changeState(view, to: .interactiveResting)
      try replace(view, NSRange(location: 0, length: 1), in: context, with: "x")
      view.select([NSRange(location: 5, length: 0)], primary: 0)
      view.setMarkedText(
        "か", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      view.unmarkText()
      try replace(view, NSRange(location: 2, length: 1), in: context, with: "y")
      try select(view, [NSRange(location: 2, length: 1)], in: context)
      try replace(view, NSRange(location: 4, length: 1), in: context, with: "z")
      try changeState(view, to: .inactive)
      #expect(view.text == "x y zか")
      view.undo(nil)
      #expect(view.text == "x b cか")
    }

    // MARK: - 位置と画像

    @Test func 境界と下線の形は本文の配置の位置にある() throws {
      let text = "short\n" + String(repeating: "wrapped words ", count: 8)
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let context = try self.context(view, scope: .fullDocument)
      let target = NSRange(location: 6, length: (text as NSString).length - 6)
      let rects = viewRects(view, target)
      #expect(rects.count > 1, "折り返した行ごとに分かれる")
      #expect(view.boundingPaths(for: target, in: context).map(\.bounds) == rects)
      let underlines = view.underlinePaths(for: target, in: context)
      #expect(underlines.count == rects.count)
      for (path, rect) in zip(underlines, rects) {
        #expect(abs(path.bounds.minX - rect.minX) < 0.01)
        #expect(abs(path.bounds.maxX - rect.maxX) < 0.01)
        #expect(abs(path.bounds.midY - (rect.maxY - 1)) < 0.01)
      }
    }

    @Test func 空の範囲の形と画像はキャレットの位置にある() throws {
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      let context = try self.context(view, scope: .fullDocument)
      let empty = NSRange(location: 0, length: 0)
      let caret = view.layout.caretRect(at: 0).offsetBy(dx: view.textOrigin.x, dy: view.textOrigin.y)
      let paths = view.boundingPaths(for: empty, in: context)
      #expect(paths.count == 1)
      #expect(abs(paths[0].bounds.midX - caret.midX) < 0.01)
      #expect(paths[0].bounds.minY == caret.minY && paths[0].bounds.maxY == caret.maxY)
      #expect(view.textPreview(of: empty, in: context)?.presentationFrame == paths[0].bounds)
    }

    @Test func プレビューの画像の位置は本文の配置の位置にある() throws {
      let text = "first line\nsecond line"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.select([(text as NSString).range(of: "second line")], primary: 0)
      let context = try self.context(view)
      let range = NSRange(location: 7, length: 4)
      let rects = viewRects(view, NSRange(location: 18, length: 4))
      let preview = try #require(view.textPreview(of: range, in: context))
      #expect(preview.presentationFrame == rects[0])
      #expect(preview.candidateRects.map(\.rectValue) == rects)
      let scale = view.window?.backingScaleFactor ?? 2
      #expect(preview.previewImage.width == Int((rects[0].width * scale).rounded(.up)))
      let drawn = pixels(preview.previewImage)
      #expect(drawn.opaque > 0)
      #expect(drawn.opaque < preview.previewImage.width * preview.previewImage.height, "背景は透明")

      // 矩形の依頼は、その矩形の画像と、矩形に掛かるコンテキストの文字の矩形を返す。
      let line = viewRects(view, NSRange(location: 11, length: 11))[0]
      let rect = NSRect(x: 0, y: line.minY, width: view.bounds.width, height: line.height)
      let rectPreview = try #require(view.textPreview(of: rect, in: context))
      #expect(rectPreview.presentationFrame == rect)
      #expect(rectPreview.candidateRects.map(\.rectValue) == [line.intersection(rect)])
      #expect(pixels(rectPreview.previewImage).opaque > 0)

      // 依頼の矩形が表示領域からはみ出しても、ビューの外の分だけを除いて返す。
      let tall = NSRect(x: 0, y: line.minY, width: view.bounds.width, height: view.bounds.height)
      #expect(try #require(view.textPreview(of: tall, in: context)).presentationFrame == tall.intersection(view.bounds))
    }

    @Test func 範囲のプレビューは表示領域に見えている所だけを返す() throws {
      let text = (0..<80).map { "line \($0)" }.joined(separator: "\n")
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      view.scroll(NSPoint(x: 0, y: 400))
      let visible = view.visibleRect
      let context = try self.context(view, scope: .fullDocument)
      let full = NSRange(location: 0, length: (text as NSString).length)
      let preview = try #require(view.textPreview(of: full, in: context))
      let shown = viewRects(view, full).map { $0.intersection(visible) }.filter { !$0.isEmpty }
      #expect(preview.candidateRects.map(\.rectValue) == shown)
      #expect(preview.presentationFrame == shown.dropFirst().reduce(shown[0]) { $0.union($1) })
      #expect(visible.contains(preview.presentationFrame))
      // 全部が表示領域の外なら返さない。上でも下でも、空の範囲でも。
      #expect(view.textPreview(of: NSRange(location: 0, length: 6), in: context) == nil)
      let last = (text as NSString).range(of: "line 79")
      #expect(view.textPreview(of: last, in: context) == nil)
      #expect(view.textPreview(of: NSRange(location: full.length, length: 0), in: context) == nil)
      // 見えていない所を隠しても、見えている所は隠さない。
      let coordinator = try #require(view.writingToolsCoordinator)
      view.writingToolsCoordinator(coordinator, prepareFor: .remove, for: last, in: context) {}
      #expect(view.writingToolsHiddenRects(in: visible).hidden.isEmpty)
    }

    @Test func 折り返した範囲のプレビューは各行の矩形を覆い本文と同じ所に文字を描く() throws {
      let text = "head\n" + String(repeating: "wrapped words ", count: 8)
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let context = try self.context(view, scope: .fullDocument)
      let range = NSRange(location: 5, length: (text as NSString).length - 5)
      let rects = viewRects(view, range)
      try #require(rects.count > 1)
      let preview = try #require(view.textPreview(of: range, in: context))
      #expect(preview.presentationFrame == rects.dropFirst().reduce(rects[0]) { $0.union($1) })
      #expect(preview.candidateRects.map(\.rectValue) == rects)
      #expect(try overlap(preview, with: view) > 0.5)
      // 行の途中から始まり途中で終わる範囲の画像には、範囲の外の文字を描かない。
      let middle = NSRange(location: 10, length: (text as NSString).length - 20)
      let partial = try #require(view.textPreview(of: middle, in: context))
      let candidates = partial.candidateRects.map(\.rectValue)
      let image = NSBitmapImageRep(cgImage: partial.previewImage)
      let scale = view.window?.backingScaleFactor ?? 2
      var outside = 0
      for x in 0..<image.pixelsWide {
        for y in 0..<image.pixelsHigh {
          let point = CGPoint(
            x: partial.presentationFrame.minX + (CGFloat(x) + 0.5) / scale,
            y: partial.presentationFrame.minY + (CGFloat(y) + 0.5) / scale)
          if (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1,
            !candidates.contains(where: { $0.contains(point) })
          {
            outside += 1
          }
        }
      }
      #expect(outside == 0)
      // 短い一語の画像も、本文と同じ所に文字を描く。
      let head = try #require(view.textPreview(of: NSRange(location: 0, length: 4), in: context))
      #expect(try overlap(head, with: view) > 0.3)
    }

    @Test func アニメーションの間は範囲の本文を隠して終わったら戻す() throws {
      let text = "Hello world, this is text."
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let coordinator = try #require(view.writingToolsCoordinator)
      let context = try self.context(view, scope: .fullDocument)
      let range = NSRange(location: 6, length: 5)
      // 隣の文字の縁が掛からないよう、矩形の内側で数える。
      let rect = viewRects(view, range)[0].insetBy(dx: 1, dy: 0)
      let other = viewRects(view, NSRange(location: 0, length: 5))[0]
      let shown = try ink(view, in: rect)
      #expect(shown > 0)

      view.writingToolsCoordinator(coordinator, prepareFor: .anticipate, for: range, in: context) {}
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden == viewRects(view, range))
      #expect(try ink(view, in: rect) == 0)
      #expect(try ink(view, in: other) > 0)
      // 画像は隠している本文も描く。
      let preview = try #require(view.textPreview(of: range, in: context))
      #expect(pixels(preview.previewImage).opaque > 0)

      view.writingToolsCoordinator(coordinator, finish: .anticipate, for: range, in: context) {}
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden.isEmpty)
      #expect(try ink(view, in: rect) == shown)
    }

    @Test func 重なるアニメーションでも本文を隠し待機中は薄くし後ろを動かすときは末尾まで隠す() throws {
      let text = "Hello world, this is text."
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let coordinator = try #require(view.writingToolsCoordinator)
      let context = try self.context(view, scope: .fullDocument)
      let full = NSRange(location: 0, length: (text as NSString).length)
      let world = NSRange(location: 6, length: 5)
      let worldRect = viewRects(view, world)[0].insetBy(dx: 1, dy: 0)
      let helloRect = viewRects(view, NSRange(location: 0, length: 5))[0].insetBy(dx: 1, dy: 0)
      let textRect = viewRects(view, NSRange(location: 21, length: 4))[0].insetBy(dx: 1, dy: 0)
      let shown = try darkness(view, in: worldRect)

      view.writingToolsCoordinator(coordinator, prepareFor: .anticipate, for: full, in: context) {}
      view.writingToolsCoordinator(coordinator, prepareFor: .remove, for: world, in: context) {}
      #expect(try ink(view, in: worldRect) == 0)
      #expect(try ink(view, in: helloRect) == 0)
      view.writingToolsCoordinator(coordinator, finish: .anticipate, for: full, in: context) {}
      view.writingToolsCoordinator(coordinator, finish: .remove, for: world, in: context) {}

      view.writingToolsCoordinator(
        coordinator, prepareFor: .anticipateInactive, for: world, in: context) {}
      let dimmed = try darkness(view, in: worldRect)
      #expect(dimmed > shown * 0.3 && dimmed < shown * 0.7)
      view.writingToolsCoordinator(
        coordinator, finish: .anticipateInactive, for: world, in: context) {}
      #expect(abs(try darkness(view, in: worldRect) - shown) < shown * 0.01)

      view.writingToolsCoordinator(coordinator, prepareFor: .translate, for: world, in: context) {}
      #expect(try ink(view, in: worldRect) == 0)
      #expect(try ink(view, in: textRect) == 0)
      #expect(try ink(view, in: helloRect) > 0)
      view.writingToolsCoordinator(coordinator, finish: .translate, for: world, in: context) {}
      #expect(try ink(view, in: textRect) > 0)
    }

    @Test func 後ろの文字を動かすアニメーションは準備と違う範囲で終えても戻す() throws {
      let text = "Hello world, this is text."
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let coordinator = try #require(view.writingToolsCoordinator)
      let context = try self.context(view, scope: .fullDocument)
      view.writingToolsCoordinator(
        coordinator, prepareFor: .translate, for: NSRange(location: 11, length: 0), in: context) {}
      #expect(!view.writingToolsHiddenRects(in: view.bounds).hidden.isEmpty)
      view.writingToolsCoordinator(
        coordinator, finish: .translate, for: NSRange(location: 6, length: 5), in: context) {}
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden.isEmpty)

      // 文字を入れるだけの置き換えでも、入れた範囲で終えれば戻す。
      view.writingToolsCoordinator(
        coordinator, prepareFor: .translate, for: NSRange(location: 11, length: 0), in: context) {}
      try replace(view, NSRange(location: 11, length: 0), in: context, with: ",")
      view.writingToolsCoordinator(
        coordinator, finish: .translate, for: NSRange(location: 11, length: 1), in: context) {}
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden.isEmpty)

      // 準備の後に前の文字が増えても、ずれた位置で終えれば戻す。
      view.writingToolsCoordinator(
        coordinator, prepareFor: .translate, for: NSRange(location: 11, length: 0), in: context) {}
      view.select([NSRange(location: 3, length: 0)], primary: 0)
      view.insertText("XX", replacementRange: NSRange(location: NSNotFound, length: 0))
      view.writingToolsCoordinator(
        coordinator, finish: .translate, for: NSRange(location: 8, length: 5), in: context) {}
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden.isEmpty)
    }

    @Test func 書き換えを流し込んでいる間は選択を見せない() throws {
      let (window, view) = makeEditor(text: "Hello world")
      defer { window.close() }
      let hello = NSRange(location: 0, length: 5)
      let rect = viewRects(view, hello)[0]
      view.select([NSRange(location: 11, length: 0)], primary: 0)
      let unselected = try darkness(view, in: rect)
      view.select([hello], primary: 0)
      let selected = try darkness(view, in: rect)
      #expect(selected > unselected * 1.2)
      _ = try self.context(view, scope: .fullDocument)
      try changeState(view, to: .interactiveStreaming)
      #expect(abs(try darkness(view, in: rect) - unselected) < unselected * 0.01)
      try changeState(view, to: .interactiveResting)
      #expect(abs(try darkness(view, in: rect) - selected) < selected * 0.01)
    }

    @Test func 隠している本文はWriting_Toolsの置き換えに合わせて伸び縮みする() throws {
      let text = "Hello world, this is text."
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let coordinator = try #require(view.writingToolsCoordinator)
      let context = try self.context(view, scope: .fullDocument)
      let world = NSRange(location: 6, length: 5)
      view.writingToolsCoordinator(coordinator, prepareFor: .remove, for: world, in: context) {}
      try replace(view, world, in: context, with: "big wide world")
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden == viewRects(view, NSRange(location: 6, length: 14)))
      try replace(view, NSRange(location: 6, length: 14), in: context, with: "all")
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden == viewRects(view, NSRange(location: 6, length: 3)))
      // 端に入れた文字も一緒に隠す。
      try replace(view, NSRange(location: 9, length: 0), in: context, with: "!")
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden == viewRects(view, NSRange(location: 6, length: 4)))
      // 利用者が範囲の先頭に掛けて消した文字の分も縮める。
      view.select([NSRange(location: 4, length: 3)], primary: 0)
      view.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(view.text == "Hellll!, this is text.")
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden == viewRects(view, NSRange(location: 4, length: 3)))
      // 利用者が範囲の端に入れた文字は隠さない。
      view.select([NSRange(location: 7, length: 0)], primary: 0)
      view.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden == viewRects(view, NSRange(location: 4, length: 3)))
      #expect(try ink(view, in: viewRects(view, NSRange(location: 7, length: 1))[0].insetBy(dx: 1, dy: 0)) > 0)
    }

    @Test func 隠している本文は編集に合わせてずれる() throws {
      let text = "Hello world, this is text."
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let coordinator = try #require(view.writingToolsCoordinator)
      let context = try self.context(view, scope: .fullDocument)
      let world = NSRange(location: 6, length: 5)
      view.writingToolsCoordinator(coordinator, prepareFor: .anticipate, for: world, in: context) {}
      view.select([NSRange(location: 0, length: 0)], primary: 0)
      view.insertText("XX", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden == viewRects(view, NSRange(location: 8, length: 5)))
      view.writingToolsCoordinator(coordinator, finish: .anticipate, for: world, in: context) {}
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden.isEmpty)
    }

    // MARK: - 利用者の編集

    @Test func 実行中の利用者の編集をコーディネータに知らせる() throws {
      let text = "intro\nThis are a test.\nend"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      view.select([(text as NSString).range(of: "are")], primary: 0)
      let context = try self.context(view)
      try changeState(view, to: .interactiveResting)
      let id = context.identifier

      // コンテキストの中の打鍵は、コンテキストの中の範囲で知らせる。
      view.select([NSRange(location: 11, length: 3)], primary: 0)
      view.insertText("is", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(recording.calls == [.update(NSRange(location: 5, length: 3), "is", .typing, id)])

      // 取り消しも知らせる。
      recording.calls = []
      view.undo(nil)
      #expect(recording.calls == [.update(NSRange(location: 5, length: 2), "are", .undoRedo, id)])

      // 前の編集は、位置がずれたことだけを知らせ、Writing Tools の置き換えの位置もずらす。
      recording.calls = []
      view.select([NSRange(location: 0, length: 0)], primary: 0)
      view.insertText(">> ", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(recording.calls == [.reflow(id)])
      try replace(view, NSRange(location: 5, length: 3), in: context, with: "is")
      #expect(view.text == ">> intro\nThis is a test.\nend")

      // Writing Tools 自身の置き換えは知らせず、コンテキストの長さは置き換えの分だけ変わる。
      recording.calls = []
      try replace(view, NSRange(location: 0, length: 4), in: context, with: "It")
      #expect(recording.calls.isEmpty)
      #expect(view.text == ">> intro\nIt is a test.\nend")
      let length = ("It is a test.\n" as NSString).length
      #expect(try replace(view, NSRange(location: length, length: 1), in: context, with: "x") == nil)
      #expect(try replace(view, NSRange(location: length - 1, length: 1), in: context, with: "\n") != nil)

      // 後ろの編集は知らせない。
      view.select([NSRange(location: (view.text as NSString).length, length: 0)], primary: 0)
      view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(recording.calls.isEmpty)
    }

    @Test func コンテキストの末尾に入った文字は配置の変化として知らせる() throws {
      let (window, view) = makeEditor(text: "abc")
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      let id = try self.context(view, scope: .fullDocument).identifier
      try changeState(view, to: .interactiveResting)
      view.select([NSRange(location: 3, length: 0)], primary: 0)
      view.insertText("d", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(recording.calls == [.reflow(id)])
    }

    @Test func 空のコンテキストに打った文字はコンテキストの中の変更として知らせる() throws {
      let (window, view) = makeEditor(text: "")
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      let context = try self.context(view, scope: .fullDocument)
      try changeState(view, to: .interactiveResting)
      view.insertText("Hi", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(recording.calls == [.update(NSRange(location: 0, length: 0), "Hi", .typing, context.identifier)])
      #expect(try replace(view, NSRange(location: 0, length: 2), in: context, with: "Hello") == "Hello")
    }

    @Test func 空の範囲のアニメーションは本文を隠さない() throws {
      let text = "Hello world"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let coordinator = try #require(view.writingToolsCoordinator)
      let context = try self.context(view, scope: .fullDocument)
      view.writingToolsCoordinator(
        coordinator, prepareFor: .remove, for: NSRange(location: 2, length: 0), in: context) {}
      #expect(view.writingToolsHiddenRects(in: view.bounds).hidden.isEmpty)
    }

    @Test func 動いていない依頼のコンテキストをまたぐ編集では止めずにコンテキストを捨てる() async throws {
      let text = "intro\nThis are a test.\nend"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      view.select([(text as NSString).range(of: "are")], primary: 0)
      let id = try self.context(view).identifier
      view.select([NSRange(location: 3, length: 6)], primary: 0)
      view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
      // 止めるのは通知の後なので、しばらく待って確かめる。
      #expect(!(await waitUntil({ recording.calls.contains(.stop) })))
      #expect(recording.calls.isEmpty)
      #expect(view.writingTools.contexts[id] == nil)
    }

    @Test func 複数のキャレットの打鍵は前の編集と中の編集に分けて知らせる() throws {
      let text = "intro\nThis are a test.\nend"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      view.select([(text as NSString).range(of: "are")], primary: 0)
      let context = try self.context(view)
      let id = context.identifier
      view.select([NSRange(location: 1, length: 0), NSRange(location: 11, length: 0)], primary: 0)
      view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(view.text == "ixntro\nThis xare a test.\nend")
      #expect(Set(recording.calls.map(String.init(describing:))) == Set([
        String(describing: RecordingCoordinator.Call.update(NSRange(location: 5, length: 0), "x", .typing, id)),
        String(describing: RecordingCoordinator.Call.reflow(id)),
      ]))
      #expect(recording.calls.count == 2)
      try replace(view, NSRange(location: 5, length: 4), in: context, with: "is")
      #expect(view.text == "ixntro\nThis is a test.\nend")
    }

    @Test func 一度の編集の知らせは変更前の位置で後ろから送り配置の変化は一度だけ送る() throws {
      let text = "intro\nThis are a test.\nend"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      view.select([(text as NSString).range(of: "This are a test.")], primary: 0)
      let context = try self.context(view)
      let id = context.identifier
      view.select(
        [
          NSRange(location: 0, length: 0), NSRange(location: 2, length: 0),
          NSRange(location: 6, length: 0), NSRange(location: 11, length: 0),
          NSRange(location: 15, length: 0),
        ], primary: 0)
      view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(view.text == "xinxtro\nxThis xare xa test.\nend")
      // コンテキストの先頭に入った文字は前の編集として扱う。前の 3 つの編集の知らせは一度にする。
      #expect(
        recording.calls == [
          .update(NSRange(location: 9, length: 0), "x", .typing, id),
          .update(NSRange(location: 5, length: 0), "x", .typing, id), .reflow(id),
        ])
      try replace(view, NSRange(location: 5, length: 4), in: context, with: "is")
      #expect(view.text == "xinxtro\nxThis is xa test.\nend")
    }

    @Test func コンテキストの末尾から始まる編集は後ろの編集として扱う() throws {
      let text = "first\nsecond"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      view.select([NSRange(location: 0, length: 5)], primary: 0)
      let id = try self.context(view).identifier
      try changeState(view, to: .interactiveResting)
      // 次の段落の最初の文字を消す。
      view.select([NSRange(location: 6, length: 1)], primary: 0)
      view.insertText("S", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(recording.calls.isEmpty)
      #expect(view.writingTools.contexts[id] != nil)
    }

    @Test func 外観を付け直して組み直したときも配置の変化として知らせる() throws {
      let (window, view) = makeEditor(text: "abc")
      defer { window.close() }
      let controller = try #require(retainedEditors.last?.1)
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      let id = try self.context(view, scope: .fullDocument).identifier
      controller.highlight()
      #expect(recording.calls == [.reflow(id)])
      // コンテキストを捨てた後は送らない。
      try changeState(view, to: .inactive)
      recording.calls = []
      controller.highlight()
      #expect(recording.calls.isEmpty)
    }

    @Test func 前の長さの変わらない編集と幅の変化も配置の変化として知らせる() throws {
      let text = "intro\nThis are a test.\nend"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      view.select([(text as NSString).range(of: "are")], primary: 0)
      let id = try self.context(view).identifier
      view.select([NSRange(location: 0, length: 1)], primary: 0)
      view.insertText("I", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(recording.calls == [.reflow(id)])
      recording.calls = []
      view.setFrameSize(NSSize(width: view.frame.width - 50, height: view.frame.height))
      #expect(recording.calls == [.reflow(id)])
    }

    @Test func コンテキストの境界をまたぐ編集ではWriting_Toolsを止める() async throws {
      let text = "intro\nThis are a test.\nend"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      view.select([(text as NSString).range(of: "are")], primary: 0)
      let context = try self.context(view)
      try changeState(view, to: .interactiveStreaming)
      view.select([NSRange(location: 3, length: 6)], primary: 0)
      view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
      // コーディネータが終わりを知らせなくても、流し込みの間の表示をやめる。
      #expect(view.writingTools.state == .inactive)
      #expect(await waitUntil({ recording.calls.contains(.stop) }))
      #expect(!recording.calls.contains { if case .update = $0 { true } else { false } })
      // 止めた後の置き換えは、位置が分からないので断る。
      #expect(try replace(view, NSRange(location: 0, length: 1), in: context, with: "y") == nil)
    }

    @Test func 止めるまでの間に来た新しい依頼は止めない() async throws {
      let text = "intro\nThis are a test.\nend"
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      view.select([(text as NSString).range(of: "are")], primary: 0)
      _ = try self.context(view)
      try changeState(view, to: .interactiveResting)
      view.select([NSRange(location: 3, length: 6)], primary: 0)
      view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
      _ = try self.context(view, scope: .fullDocument)
      #expect(!(await waitUntil({ recording.calls.contains(.stop) })))
    }

    @Test func 本文を外から差し替えるとWriting_Toolsを止める() throws {
      let (window, view) = makeEditor(text: "abc")
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      view.writingToolsCoordinator = recording
      let context = try self.context(view, scope: .fullDocument)
      view.replaceText("other")
      #expect(recording.calls == [.stop])
      #expect(try replace(view, NSRange(location: 0, length: 1), in: context, with: "y") == nil)
      #expect(view.text == "other")
    }

    // MARK: - 文法の提示 (macOS 27)
    //
    // macOS 27 SDK の API を使うので、それより前の SDK (AppKit 2700 より前) では外す。

    #if canImport(AppKit, _version: 2700)

    /// `index` の文字に文法の誤りの印が付いているか。
    private func hasGrammarMark(_ view: EditorView, at index: Int) -> Bool {
      let grammar = NSAttributedString.SpellingState.grammar.rawValue
      let state = view.textChecker.annotations.attribute(.spellingState, at: index, effectiveRange: nil)
      return (state as? String).flatMap(Int.init).map { $0 & grammar != 0 } ?? false
    }

    /// 文法の誤りの印が付くまで待つ。
    private func editorWithGrammarMark(_ text: String, issue: String) async throws -> (
      NSWindow, EditorView, NSRange
    ) {
      let (window, view) = makeEditor(text: text)
      let range = (text as NSString).range(of: issue)
      view.select([NSRange(location: (text as NSString).length, length: 0)], primary: 0)
      view.isContinuousSpellCheckingEnabled = true
      let marked = await waitUntil(
        { hasGrammarMark(view, at: range.location) },
        timeout: .seconds(3))
      if !marked { window.close() }
      try #require(marked)
      return (window, view, range)
    }

    @available(macOS 27.0, *)
    @Test func 文法の結果はいま印を付けている誤りをコンテキストの位置で返す() async throws {
      let text = "Intro line.\nHe go to school yesterday. "
      let (window, view, verb) = try await editorWithGrammarMark(text, issue: "go")
      defer { window.close() }
      let coordinator = try #require(view.writingToolsCoordinator)
      view.select([(text as NSString).range(of: "He go to school")], primary: 0)
      let context = try self.context(view)
      let contextStart = (text as NSString).range(of: "He go").location
      nonisolated(unsafe) var results: [NSTextCheckingResult] = []
      view.writingToolsCoordinator(coordinator, requestsGrammarResultsFor: context) { results = $0 }
      let result = try #require(results.first)
      #expect(result.resultType == .grammar)
      // 結果の範囲は文、詳細の範囲は文の先頭から数えた誤りの範囲。
      let resultInText = NSRange(
        location: result.range.location + contextStart, length: result.range.length)
      #expect(resultInText == (text as NSString).range(of: "He go to school yesterday."))
      let detail = try #require(result.grammarDetails?.first)
      let issue = try #require((detail[NSGrammarRange] as? NSValue)?.rangeValue)
      #expect(NSRange(location: resultInText.location + issue.location, length: issue.length) == verb)
      #expect((detail[NSGrammarUserDescription] as? String)?.isEmpty == false)
      #expect((detail[NSGrammarCorrections] as? [String])?.isEmpty == false)

      // 文法の検査をオフにすると、結果を返さない。
      view.isGrammarCheckingEnabled = false
      view.writingToolsCoordinator(coordinator, requestsGrammarResultsFor: context) { results = $0 }
      #expect(results.isEmpty)
    }

    @available(macOS 27.0, *)
    @Test func 文法の提示で検査を切ると文法の検査の入切が変わる() async throws {
      let (window, view, verb) = try await editorWithGrammarMark(
        "He go to school yesterday. ", issue: "go")
      defer { window.close() }
      let coordinator = try #require(view.writingToolsCoordinator)
      view.writingToolsCoordinator(coordinator, setGrammarCheckingEnabled: false)
      #expect(!view.isGrammarCheckingEnabled)
      #expect(!hasGrammarMark(view, at: verb.location))
      view.writingToolsCoordinator(coordinator, setGrammarCheckingEnabled: true)
      #expect(view.isGrammarCheckingEnabled)
      #expect(
        await waitUntil(
          { hasGrammarMark(view, at: verb.location) },
          timeout: .seconds(3)))
    }

    @available(macOS 27.0, *)
    @Test(writingToolsAvailable)
    func 新しく付いた文法の誤りの印をアニメーションで示し終わったらコンテキストを捨てる() async throws {
      let (window, view, verb) = try await editorWithGrammarMark(
        "He go to school yesterday. ", issue: "go")
      defer { window.close() }
      let id = try #require(view.writingTools.indications.keys.first)
      let record = try #require(view.writingTools.contexts[id])
      #expect(record.context.range == verb)
      #expect(
        await waitUntil(
          { view.writingTools.contexts.isEmpty && view.writingToolsHiddenRects(in: view.bounds).hidden.isEmpty },
          timeout: .seconds(5)))

      // 同じ段落を検査し直して同じ印を付け直しても、示し直さない。新しい誤りは示す。
      view.insertText(" They is happy. ", replacementRange: NSRange(location: NSNotFound, length: 0))
      let newIssue = (view.text as NSString).range(of: "is", options: .backwards)
      var indicated: [NSRange] = []
      let found = await waitUntil(
        {
          for id in view.writingTools.indications.keys {
            guard let record = view.writingTools.contexts[id] else { continue }
            indicated.append(
              NSRange(
                location: record.start + record.context.range.location,
                length: record.context.range.length))
          }
          return indicated.contains(newIssue)
        }, timeout: .seconds(3))
      #expect(found)
      #expect(!indicated.contains { NSIntersectionRange($0, verb).length > 0 })
      #expect(hasGrammarMark(view, at: verb.location))
    }

    @available(macOS 27.0, *)
    @Test(writingToolsAvailable)
    func 文法の誤りを示している間にその段落を編集するとアニメーションを取りやめる() throws {
      let text = "Intro.\nHe go to school yesterday."
      let (window, view) = makeEditor(text: text)
      defer { window.close() }
      let recording = RecordingCoordinator(delegate: view)
      recording.preferredBehavior = .complete
      view.writingToolsCoordinator = recording
      let verb = (text as NSString).range(of: "go")
      view.grammarIssuesIndicated([verb])
      let (id, animation) = try #require(view.writingTools.indications.first)
      // 前の段落の編集では取りやめない。
      view.select([NSRange(location: 0, length: 0)], primary: 0)
      view.insertText("A", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(!recording.calls.contains { if case .cancel = $0 { true } else { false } })
      #expect(view.writingTools.contexts[id] != nil)
      // 誤りより後ろの編集でも取りやめず、コンテキストの中の変更として知らせる。
      recording.calls = []
      let yesterday = (view.text as NSString).range(of: "yesterday")
      view.select([NSRange(location: yesterday.location, length: 0)], primary: 0)
      view.insertText("Ok ", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(view.writingTools.contexts[id] != nil)
      let inContext = ("He go to school " as NSString).length
      #expect(
        recording.calls == [.update(NSRange(location: inContext, length: 0), "Ok ", .typing, id)])
      view.select([NSRange(location: verb.location + 3, length: 0)], primary: 0)
      view.insertText("e", replacementRange: NSRange(location: NSNotFound, length: 0))
      #expect(recording.calls.contains(.cancel([animation])))
      #expect(view.writingTools.contexts[id] == nil)
      #expect(view.writingTools.indications.isEmpty)

      // 新しい依頼でも取りやめる。
      view.grammarIssuesIndicated([NSRange(location: verb.location + 1, length: 3)])
      let second = try #require(view.writingTools.indications.first?.value)
      _ = try self.context(view, scope: .fullDocument)
      #expect(recording.calls.contains(.cancel([second])))

      // Writing Tools が動き始めたら取りやめ、動いている間は示さない。
      #expect(view.grammarIssuesIndicated([verb]) == [verb])
      let pending = try #require(view.writingTools.indications.first?.value)
      try changeState(view, to: .interactiveResting)
      #expect(recording.calls.contains(.cancel([pending])))
      #expect(view.grammarIssuesIndicated([verb]).isEmpty)
      #expect(view.writingTools.indications.isEmpty)
      // 終わった後は示す。
      try changeState(view, to: .inactive)
      #expect(view.grammarIssuesIndicated([verb]) == [verb])

      // 文法の検査や入力中の検査を切ると、示している途中のアニメーションも取りやめる。
      let third = try #require(view.writingTools.indications.first?.value)
      view.isGrammarCheckingEnabled = false
      #expect(recording.calls.contains(.cancel([third])))
      #expect(view.writingTools.indications.isEmpty)
      view.isGrammarCheckingEnabled = true
      view.isContinuousSpellCheckingEnabled = true
      #expect(view.grammarIssuesIndicated([verb]) == [verb])
      let fourth = try #require(view.writingTools.indications.first?.value)
      view.isContinuousSpellCheckingEnabled = false
      #expect(recording.calls.contains(.cancel([fourth])))
    }

    @available(macOS 27.0, *)
    @Test(writingToolsAvailable)
    func 段落の端にある誤りに接する編集でも文法の誤りのアニメーションを取りやめる() throws {
      for (text, issue, caret) in [("He go", "go", 5), ("go home now.", "go", 0)] {
        let (window, view) = makeEditor(text: text)
        defer { window.close() }
        let recording = RecordingCoordinator(delegate: view)
        recording.preferredBehavior = .complete
        view.writingToolsCoordinator = recording
        view.grammarIssuesIndicated([(text as NSString).range(of: issue)])
        let animation = try #require(view.writingTools.indications.first?.value)
        view.select([NSRange(location: caret, length: 0)], primary: 0)
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(recording.calls.contains(.cancel([animation])), "\(text)")
        #expect(view.writingTools.indications.isEmpty, "\(text)")
      }
    }

    @available(macOS 27.0, *)
    @Test func 文法の提示で続けて受け入れた候補はそれぞれ一回で取り消せる() async throws {
      let text = "He go to school yesterday. "
      let (window, view, verb) = try await editorWithGrammarMark(text, issue: "go")
      defer { window.close() }
      let context = try self.context(view, scope: .fullDocument)
      try replace(view, verb, in: context, with: "went", reason: .temporary)
      try replace(view, NSRange(location: verb.location, length: 4), in: context, with: "went", reason: .accepted)
      let school = (view.text as NSString).range(of: "school")
      try select(view, [school], in: context)
      try replace(view, school, in: context, with: "work", reason: .temporary)
      try replace(view, NSRange(location: school.location, length: 4), in: context, with: "work", reason: .accepted)
      #expect(view.text == "He went to work yesterday. ")
      view.undo(nil)
      #expect(view.text == "He went to school yesterday. ")
      view.undo(nil)
      #expect(view.text == text)
    }

    @available(macOS 27.0, *)
    @Test func 文法の提示のプレビューは下線の有無を描き分ける() async throws {
      let (window, view, verb) = try await editorWithGrammarMark(
        "He go to school yesterday. ", issue: "go")
      defer { window.close() }
      let coordinator = try #require(view.writingToolsCoordinator)
      let context = try self.context(view, scope: .fullDocument)
      nonisolated(unsafe) var plain: [NSTextPreview]?
      nonisolated(unsafe) var underlined: [NSTextPreview]?
      view.writingToolsCoordinator(
        coordinator, requestsPreviewFor: .indicateGrammar, of: verb, in: context,
        textDecoration: .none
      ) { plain = $0 }
      view.writingToolsCoordinator(
        coordinator, requestsPreviewFor: .indicateGrammar, of: verb, in: context,
        textDecoration: .grammarUnderline
      ) { underlined = $0 }
      // 表示のとおりの画像には、文法の誤りの印が描かれる。
      let shown = try #require(view.textPreview(of: verb, in: context))
      #expect(pixels(shown.previewImage).green > 0)
      let without = try #require(plain?.first)
      let with = try #require(underlined?.first)
      #expect(without.presentationFrame == viewRects(view, verb)[0])
      #expect(with.presentationFrame == without.presentationFrame)
      #expect(pixels(without.previewImage).green == 0)
      #expect(pixels(with.previewImage).green > 0)
      // 表示の文法の誤りの印は、プレビューを描いた後も残る。
      #expect(renderedMarks(view)[verb] == NSAttributedString.SpellingState.grammar.rawValue)
    }

    /// 本文の写しに付いた、誤りの印の rendering attribute。
    private func renderedMarks(_ view: EditorView) -> [NSRange: Int] {
      let manager = view.layout.layoutManager
      let start = manager.documentRange.location
      var marks: [NSRange: Int] = [:]
      manager.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, range in
        if let state = attributes[.spellingState] as? Int {
          let location = manager.offset(from: start, to: range.location)
          marks[NSRange(location: location, length: manager.offset(from: range.location, to: range.endLocation))] = state
        }
        return true
      }
      return marks
    }

    @available(macOS 27.0, *)
    @Test func 文法の提示で退けた誤りは検査し直しても印を付けない() async throws {
      let text = "He go to school yesterday. "
      let (window, view, verb) = try await editorWithGrammarMark(text, issue: "go")
      defer { window.close() }
      let context = try self.context(view, scope: .fullDocument)
      try replace(view, verb, in: context, with: "goes", reason: .temporary)
      #expect(view.text == "He goes to school yesterday. ")
      try replace(view, NSRange(location: verb.location, length: 4), in: context, with: "go", reason: .rejected)
      #expect(view.text == text)
      #expect(!hasGrammarMark(view, at: verb.location))
      // 一時的な置き換えと退けた置き換えは、一回の取り消しにまとまる。
      #expect(view.document.canUndo)
      view.undo(nil)
      #expect(view.text == text)
      #expect(!view.document.canUndo)

      // 同じ段落を検査し直して別の誤りに印が付いても、退けた誤りには付けない。
      view.select([NSRange(location: (text as NSString).length, length: 0)], primary: 0)
      view.insertText("They is happy. ", replacementRange: NSRange(location: NSNotFound, length: 0))
      let other = (view.text as NSString).range(of: "is", options: .backwards)
      #expect(await waitUntil({ hasGrammarMark(view, at: other.location) }, timeout: .seconds(3)))
      #expect(!hasGrammarMark(view, at: verb.location))
    }

    @available(macOS 27.0, *)
    @Test func 文法の提示で受け入れた置き換えは一回で取り消せる() async throws {
      let text = "He go to school yesterday. "
      let (window, view, verb) = try await editorWithGrammarMark(text, issue: "go")
      defer { window.close() }
      let context = try self.context(view, scope: .fullDocument)
      try replace(view, verb, in: context, with: "goes", reason: .temporary)
      try select(view, [NSRange(location: verb.location, length: 4)], in: context)
      try replace(view, NSRange(location: verb.location, length: 4), in: context, with: "went", reason: .accepted)
      #expect(view.text == "He went to school yesterday. ")
      view.select([NSRange(location: 0, length: 0)], primary: 0)
      view.type("A")
      view.undo(nil)
      #expect(view.text == "He went to school yesterday. ")
      view.undo(nil)
      #expect(view.text == text)
    }
    #endif
  }
}
