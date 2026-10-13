import AppKit
import Testing
import TestSupport

@testable import EdiroUI

/// 呼び出し側が受け取らなかったウィンドウとコントローラもテストの間は生かしておく。
private var retainedEditors: [(NSWindow, EditorTextController)] = []

/// ドラッグの情報の代わり。位置、ペーストボード、運ぶ元、運ぶ元が許す操作を決めて渡す。
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
  var draggingDestinationWindow: NSWindow?
  var draggingSourceOperationMask: NSDragOperation
  var draggingLocation: NSPoint
  var draggedImageLocation: NSPoint { draggingLocation }
  var draggedImage: NSImage? { nil }
  var draggingPasteboard: NSPasteboard
  var draggingSource: Any?
  var draggingSequenceNumber: Int { 1 }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  func enumerateDraggingItems(
    options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  func resetSpringLoading() {}

  init(
    window: NSWindow?, location: NSPoint, pasteboard: NSPasteboard,
    mask: NSDragOperation = .every, source: Any? = nil
  ) {
    draggingDestinationWindow = window
    draggingLocation = location
    draggingPasteboard = pasteboard
    draggingSourceOperationMask = mask
    draggingSource = source
  }
}

/// 時間を進める代わりに、テストが `fire()` で間隔ごとの処理を呼ぶタイマー。
final class ManualAutoscrollTimer: AutoscrollTimer {
  let tick: () -> Bool
  private(set) var isValid = true

  init(tick: @escaping () -> Bool) { self.tick = tick }

  func fire() { if isValid, !tick() { invalidate() } }
  func invalidate() { isValid = false }
}

/// キーのウィンドウとして振る舞うウィンドウ。テストのプロセスのウィンドウはキーにならないので、
/// キーのウィンドウへの操作を確かめるときに使う。
final class KeyWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}

/// ペーストボードに書く内容。ドロップとペーストを参照 NSTextView と比べる。
nonisolated struct PasteboardContent: CustomTestStringConvertible, Sendable {
  enum Kind: Sendable {
    case string, html, rtf, url, file, twoFiles, directory, fileAndString, urlAndString
    case htmlAndString, image, emptyString, directoryWithSlash, htmlWithImage, rtfdWithImage
    case shiftJISHTML, htmlWithoutEncoding, htmlWithCharsetText, twoWebURLs, webAndFileURL
  }

  let kind: Kind
  let testDescription: String

  init(_ kind: Kind, _ description: String) {
    self.kind = kind
    testDescription = description
  }

  static let all: [PasteboardContent] = [
    .init(.string, "文字列"), .init(.html, "HTML のみ"), .init(.rtf, "RTF"), .init(.url, "URL のみ"),
    .init(.file, "ファイル URL"), .init(.twoFiles, "ファイル URL 二つ"),
    .init(.directory, "ディレクトリの URL"), .init(.fileAndString, "ファイル URL と文字列"),
    .init(.urlAndString, "URL と文字列"), .init(.htmlAndString, "HTML と文字列"),
    .init(.image, "画像のみ"), .init(.emptyString, "空の文字列"),
    .init(.directoryWithSlash, "末尾にスラッシュのあるフォルダの URL"),
    .init(.htmlWithImage, "画像を含む HTML"), .init(.rtfdWithImage, "画像を含む RTFD"),
    .init(.shiftJISHTML, "Shift_JIS を示す HTML"), .init(.twoWebURLs, "Web の URL 二つ"),
    .init(.webAndFileURL, "Web の URL とファイル URL"),
    .init(.htmlWithoutEncoding, "文字コードを示さない HTML"),
    .init(.htmlWithCharsetText, "本文に charset を含む HTML"),
  ]

  @MainActor static var image: NSImage {
    NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
      NSColor.red.setFill()
      rect.fill()
      return true
    }
  }

  @MainActor static var pngBase64: String {
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!.base64EncodedString()
  }

  @MainActor func write(to pasteboard: NSPasteboard) throws {
    let directory = TestArtifacts.directory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "dropped file.md")
    try "# file contents\n".write(to: file, atomically: true, encoding: .utf8)
    let second = directory.appending(path: "日本語.txt")
    try "x".write(to: second, atomically: true, encoding: .utf8)
    let url = URL(string: "https://example.com/a?b=c%20d")!
    pasteboard.clearContents()
    switch kind {
    case .string: pasteboard.setString("plain text", forType: .string)
    case .html:
      pasteboard.setString(
        "<meta charset=\"utf-8\"><b>太字</b> text<p>段落</p>", forType: .html)
    case .rtf:
      let rtf = try NSAttributedString(string: "rtf テキスト").data(
        from: NSRange(location: 0, length: 8),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
      pasteboard.setData(rtf, forType: .rtf)
    case .url: pasteboard.writeObjects([url as NSURL])
    case .file: pasteboard.writeObjects([file as NSURL])
    case .twoFiles: pasteboard.writeObjects([file as NSURL, second as NSURL])
    case .directory: pasteboard.writeObjects([directory as NSURL])
    case .fileAndString:
      pasteboard.writeObjects([file as NSURL])
      pasteboard.addTypes([.string], owner: nil)
      pasteboard.setString("dropped file.md", forType: .string)
    case .urlAndString:
      pasteboard.writeObjects([url as NSURL])
      pasteboard.addTypes([.string], owner: nil)
      pasteboard.setString("title", forType: .string)
    case .htmlAndString:
      pasteboard.declareTypes([.html, .string], owner: nil)
      pasteboard.setString("<b>h</b>", forType: .html)
      pasteboard.setString("s", forType: .string)
    case .image:
      pasteboard.writeObjects([Self.image])
    case .emptyString: pasteboard.setString("", forType: .string)
    case .directoryWithSlash:
      let folder = URL(filePath: directory.path(percentEncoded: false) + "/", directoryHint: .isDirectory)
      pasteboard.writeObjects([folder as NSURL])
    case .htmlWithImage:
      pasteboard.setString(
        "<meta charset=\"utf-8\">before<img src=\"data:image/png;base64,\(Self.pngBase64)\">after",
        forType: .html)
    case .rtfdWithImage:
      let attachment = NSTextAttachment()
      attachment.image = Self.image
      let text = NSMutableAttributedString(string: "pre")
      text.append(NSAttributedString(attachment: attachment))
      text.append(NSAttributedString(string: "post"))
      let rtfd = try #require(
        text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
      pasteboard.setData(rtfd, forType: .rtfd)
    case .shiftJISHTML:
      let html = "<meta charset=\"shift_jis\"><p>日本語</p>"
      pasteboard.setData(html.data(using: .shiftJIS)!, forType: .html)
    case .htmlWithoutEncoding:
      pasteboard.setString("<b>太字</b> text", forType: .html)
    case .htmlWithCharsetText:
      pasteboard.setString("<p>charset 日本語</p>", forType: .html)
    case .twoWebURLs:
      pasteboard.writeObjects([url as NSURL, URL(string: "https://example.org/2")! as NSURL])
    case .webAndFileURL:
      pasteboard.writeObjects([url as NSURL, file as NSURL])
    }
  }
}

extension AppKitTests {
  struct DragAndDropTests {
    /// 参照 NSTextView と同じ大きさのウィンドウに載せたエディタ。
    private func makeEditor(text: String, key: Bool = true) -> (NSWindow, EditorView) {
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
      return (window, controller.editorView)
    }

    private func makePasteboard() -> NSPasteboard {
      NSPasteboard(name: NSPasteboard.Name("ediro-test-\(UUID().uuidString)"))
    }

    private func ranges(_ view: EditorView) -> [NSRange] {
      view.session.selections.map { view.nsRange(of: $0.range) }
    }

    private func select(_ view: EditorView, _ ranges: [NSRange]) {
      view.select(ranges, primary: 0)
    }

    /// `location` の文字の、左端から `fraction` の所の点 (ウィンドウの座標)。
    private func point(
      at location: Int, fraction: CGFloat = 0.25, in view: EditorView
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

    /// このビューから選択を運び始めた状態にする。実際のドラッグの開始はシステムの操作を待つので、
    /// 運んでいる範囲だけを置き、ペーストボードにはドラッグと同じ文字を書く。
    private func startOwnDrag(_ view: EditorView, _ pasteboard: NSPasteboard) {
      view.dragAndDrop.dragged = (
        view.session.selections.filter { !$0.isEmpty }.map { view.nsRange(of: $0.range) },
        view.textVersion
      )
      pasteboard.clearContents()
      pasteboard.setString(view.selectedTexts.joined(separator: "\n"), forType: .string)
    }

    // MARK: - ドロップ位置

    @Test func ドロップ位置は点に最も近い文字の境界になる() throws {
      let (_, view) = makeEditor(text: "hello world\nsecond line")
      #expect(view.dropOffset(at: try point(at: 6, fraction: 0.2, in: view)) == 6)
      #expect(view.dropOffset(at: try point(at: 6, fraction: 0.8, in: view)) == 7)
      #expect(view.dropOffset(at: try point(at: 12, fraction: 0.2, in: view)) == 12)
      // 行の右の何も無い所は、その行の末尾。
      let lineEnd = try point(at: 10, fraction: 0.5, in: view)
      #expect(view.dropOffset(at: NSPoint(x: lineEnd.x + 100, y: lineEnd.y)) == 11)
      // 本文の下は本文の末尾。
      let last = try point(at: 22, in: view)
      #expect(view.dropOffset(at: NSPoint(x: last.x, y: last.y - 100)) == 23)
    }

    @Test func ドロップ中はドロップ位置にキャレットを示し_離れたら消す() throws {
      let (window, view) = makeEditor(text: "hello world")
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      pasteboard.setString("x", forType: .string)
      let info = FakeDraggingInfo(
        window: window, location: try point(at: 6, in: view), pasteboard: pasteboard)
      #expect(view.draggingEntered(info) == .copy)
      #expect(view.dragAndDrop.dropOffset == 6)
      info.draggingLocation = try point(at: 2, in: view)
      #expect(view.draggingUpdated(info) == .copy)
      #expect(view.dragAndDrop.dropOffset == 2)
      view.draggingExited(info)
      #expect(view.dragAndDrop.dropOffset == nil)
    }

    // MARK: - ビュー内の移動とコピー

    @Test func ビュー内のドラッグは移動し_一回の取り消しで戻る() throws {
      let (window, view) = makeEditor(text: "hello world foo")
      select(view, [NSRange(location: 0, length: 5)])
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      startOwnDrag(view, pasteboard)
      let info = FakeDraggingInfo(
        window: window, location: try point(at: 12, in: view), pasteboard: pasteboard,
        mask: [.copy, .move, .generic], source: view)
      #expect(view.draggingEntered(info) == .move)
      #expect(view.performDragOperation(info))
      view.concludeDragOperation(info)
      #expect(view.text == " world hellofoo")
      #expect(ranges(view) == [NSRange(location: 7, length: 5)])
      // ドロップの側で消したので、ドラッグの終わりには何もしない。
      view.finishDragging(operation: .move)
      #expect(view.text == " world hellofoo")

      view.undo(nil)
      #expect(view.text == "hello world foo")
      #expect(ranges(view) == [NSRange(location: 0, length: 5)])
      view.redo(nil)
      #expect(view.text == " world hellofoo")
    }

    @Test func 前へ移動すると入れた文字を選ぶ() throws {
      let (window, view) = makeEditor(text: "hello world foo")
      select(view, [NSRange(location: 12, length: 3)])
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      startOwnDrag(view, pasteboard)
      let info = FakeDraggingInfo(
        window: window, location: try point(at: 0, in: view), pasteboard: pasteboard,
        mask: [.copy, .move, .generic], source: view)
      #expect(view.performDragOperation(info))
      #expect(view.text == "foohello world ")
      #expect(ranges(view) == [NSRange(location: 0, length: 3)])
    }

    @Test func 複数の選択は改行で繋いで一か所に移す() throws {
      let (window, view) = makeEditor(text: "aa bb cc dd")
      select(view, [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      startOwnDrag(view, pasteboard)
      #expect(pasteboard.string(forType: .string) == "aa\ncc")
      let info = FakeDraggingInfo(
        window: window, location: try point(at: 3, in: view), pasteboard: pasteboard,
        mask: [.copy, .move, .generic], source: view)
      #expect(view.performDragOperation(info))
      #expect(view.text == " aa\nccbb  dd")
      #expect(ranges(view) == [NSRange(location: 1, length: 5)])
      view.undo(nil)
      #expect(view.text == "aa bb cc dd")
      #expect(ranges(view) == [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])
    }

    @Test func 複数の選択を_その一つの端へ移す() throws {
      let (window, view) = makeEditor(text: "aa bb cc dd")
      select(view, [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      startOwnDrag(view, pasteboard)
      let info = FakeDraggingInfo(
        window: window, location: try point(at: 8, in: view), pasteboard: pasteboard,
        mask: [.copy, .move, .generic], source: view)
      #expect(view.performDragOperation(info))
      #expect(view.text == " bb aa\ncc dd")
      #expect(ranges(view) == [NSRange(location: 4, length: 5)])
    }

    @Test(arguments: [2, 5, 0])
    func 運んだ範囲の中や端に落としても本文は変わらない(location: Int) throws {
      let (window, view) = makeEditor(text: "hello world")
      select(view, [NSRange(location: 0, length: 5)])
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      startOwnDrag(view, pasteboard)
      let info = FakeDraggingInfo(
        window: window, location: try point(at: location, in: view), pasteboard: pasteboard,
        mask: [.copy, .move, .generic], source: view)
      _ = view.performDragOperation(info)
      #expect(view.text == "hello world")
      #expect(ranges(view) == [NSRange(location: 0, length: 5)])
      #expect(!view.document.canUndo)
    }

    /// ⌥ を押している間は、システムが運ぶ元の許す操作をコピーに絞る。
    @Test func オプションを押したドラッグはコピーする() throws {
      let (window, view) = makeEditor(text: "hello world foo")
      select(view, [NSRange(location: 0, length: 5)])
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      startOwnDrag(view, pasteboard)
      let info = FakeDraggingInfo(
        window: window, location: try point(at: 12, in: view), pasteboard: pasteboard,
        mask: .copy, source: view)
      #expect(view.draggingEntered(info) == .copy)
      #expect(view.performDragOperation(info))
      #expect(view.text == "hello world hellofoo")
      #expect(ranges(view) == [NSRange(location: 12, length: 5)])
      // コピーしたので、ドラッグの終わりに元の文字を消さない。
      view.finishDragging(operation: .copy)
      #expect(view.text == "hello world hellofoo")
      view.undo(nil)
      #expect(view.text == "hello world foo")
    }

    @Test func ほかのビューへ移動したときは元の文字を一回の取り消しで戻るように消す() {
      let (_, view) = makeEditor(text: "aa bb cc")
      select(view, [NSRange(location: 0, length: 3), NSRange(location: 6, length: 2)])
      view.dragAndDrop.dragged = (ranges(view), view.textVersion)
      view.finishDragging(operation: .move)
      #expect(view.text == "bb ")
      #expect(view.dragAndDrop.dragged == nil)
      view.undo(nil)
      #expect(view.text == "aa bb cc")
    }

    @Test func ドラッグの間に本文が変わっていたら元の文字を消さない() {
      let (_, view) = makeEditor(text: "aa bb cc")
      select(view, [NSRange(location: 0, length: 2)])
      view.dragAndDrop.dragged = (ranges(view), view.textVersion)
      view.type("x")
      view.finishDragging(operation: .move)
      #expect(view.text == "x bb cc")
    }

    // MARK: - 外部からのドロップ

    @Test func 外からの文字はドロップ位置に入れて選び_一回の取り消しで戻る() throws {
      let (window, view) = makeEditor(text: "hello world")
      select(view, [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      pasteboard.setString("new\r\ntext", forType: .string)
      let info = FakeDraggingInfo(
        window: window, location: try point(at: 6, in: view), pasteboard: pasteboard)
      #expect(view.draggingEntered(info) == .copy)
      #expect(view.performDragOperation(info))
      #expect(view.text == "hello new\ntextworld")
      #expect(ranges(view) == [NSRange(location: 6, length: 8)])
      view.undo(nil)
      #expect(view.text == "hello world")
      #expect(ranges(view) == [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)])
    }

    @Test func 変換中の文字は確定してからドロップする() throws {
      let (window, view) = makeEditor(text: "ab")
      select(view, [NSRange(location: 2, length: 0)])
      view.setMarkedText(
        "か", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      pasteboard.setString("x", forType: .string)
      let info = FakeDraggingInfo(
        window: window, location: try point(at: 1, in: view), pasteboard: pasteboard)
      #expect(view.performDragOperation(info))
      #expect(!view.hasMarkedText())
      #expect(view.text == "axbか")
    }

    @Test func 変換位置から離れてドロップしても表示していた位置へ挿入する() throws {
      let original = (1...100).map { "line \($0)" }.joined(separator: "\n")
      let (window, view) = makeEditor(text: original)
      select(view, [NSRange(location: (original as NSString).length, length: 0)])
      view.setMarkedText(
        "かな", selectedRange: NSRange(location: 0, length: 1),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      view.scroll(.zero)
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      pasteboard.setString("x", forType: .string)
      let info = FakeDraggingInfo(
        window: window, location: try point(at: 1, in: view), pasteboard: pasteboard)
      #expect(view.draggingEntered(info) == .copy)
      #expect(view.dragAndDrop.dropOffset == 1)
      #expect(view.performDragOperation(info))
      #expect(!view.hasMarkedText())
      #expect(view.text == "lx" + original.dropFirst() + "かな")
      view.undo(nil)
      #expect(view.text == original + "かな")
    }

    @Test func 文字にできないものや移動だけを許すものは受け付けない() throws {
      let (window, view) = makeEditor(text: "hello")
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      try PasteboardContent(.image, "").write(to: pasteboard)
      let image = FakeDraggingInfo(
        window: window, location: try point(at: 1, in: view), pasteboard: pasteboard)
      #expect(view.draggingEntered(image) == [])
      #expect(!view.performDragOperation(image))

      pasteboard.clearContents()
      pasteboard.setString("x", forType: .string)
      let moveOnly = FakeDraggingInfo(
        window: window, location: try point(at: 1, in: view), pasteboard: pasteboard, mask: .move)
      #expect(view.draggingEntered(moveOnly) == [])
      let generic = FakeDraggingInfo(
        window: window, location: try point(at: 1, in: view), pasteboard: pasteboard,
        mask: .generic)
      #expect(view.draggingEntered(generic) == .generic)
      view.draggingExited(generic)
      #expect(view.text == "hello")
    }

    // MARK: - 参照 NSTextView との差分

    @Test(arguments: PasteboardContent.all)
    func ドロップで入る文字が参照と同じになる(content: PasteboardContent) throws {
      let reference = ReferenceTextView(text: "hello world")
      defer { reference.close() }
      reference.textView.updateDragTypeRegistration()
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      try content.write(to: pasteboard)
      let rect = reference.textView.firstRect(
        forCharacterRange: NSRange(location: 6, length: 1), actualRange: nil)
      let referencePoint = reference.window.convertPoint(
        fromScreen: NSPoint(x: rect.minX + 1, y: rect.midY))
      let referenceInfo = FakeDraggingInfo(
        window: reference.window, location: referencePoint, pasteboard: pasteboard)
      _ = reference.textView.draggingEntered(referenceInfo)
      let referenceAccepted = reference.textView.performDragOperation(referenceInfo)
      reference.textView.concludeDragOperation(referenceInfo)

      let (window, view) = makeEditor(text: "hello world")
      let info = FakeDraggingInfo(
        window: window, location: try point(at: 6, fraction: 0.1, in: view), pasteboard: pasteboard)
      _ = view.draggingEntered(info)
      let accepted = view.performDragOperation(info)
      view.concludeDragOperation(info)

      #expect(accepted == referenceAccepted)
      #expect(view.text == reference.textView.string)
      if accepted {
        #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
      }
    }

    /// ⌘V と、サービスから文字列を受け取る `readSelection(from:)` も、ドロップと同じ読み取りで
    /// 文字にする。参照 NSTextView の `readSelection(from:)` と比べる。
    @Test(arguments: PasteboardContent.all)
    func ペーストで入る文字が参照と同じになる(content: PasteboardContent) throws {
      let reference = ReferenceTextView(text: "hello world")
      defer { reference.close() }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      try content.write(to: pasteboard)
      reference.textView.setSelectedRange(NSRange(location: 6, length: 0))
      let referenceAccepted = reference.textView.readSelection(from: pasteboard)

      let (_, pasted) = makeEditor(text: "hello world")
      select(pasted, [NSRange(location: 6, length: 0)])
      pasted.paste(from: pasteboard)
      #expect(pasted.text == reference.textView.string)

      let (_, read) = makeEditor(text: "hello world")
      select(read, [NSRange(location: 6, length: 0)])
      #expect(read.readSelection(from: pasteboard) == referenceAccepted)
      #expect(read.text == reference.textView.string)
    }

    @Test func ペーストできるかは文字にできる型があるかで決まる() throws {
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      for content in PasteboardContent.all {
        try content.write(to: pasteboard)
        let expected = ![.image].contains(content.kind)
        #expect(EditorView.canPaste(from: pasteboard) == expected, "\(content.testDescription)")
      }
    }

    // MARK: - ドラッグの開始

    @Test func 選択の上を押して動かさずに離すとキャレットを置く() throws {
      let (window, view) = makeEditor(text: "hello world")
      select(view, [NSRange(location: 0, length: 5)])
      let down = try point(at: 2, in: view)
      view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, in: window))
      // ドラッグを始めるかが決まるまで、選択は変えない。
      #expect(ranges(view) == [NSRange(location: 0, length: 5)])
      view.mouseDragged(
        with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: down.x + 1, y: down.y), in: window))
      #expect(ranges(view) == [NSRange(location: 0, length: 5)])
      view.mouseUp(with: try mouseEvent(.leftMouseUp, at: down, in: window))
      #expect(ranges(view) == [NSRange(location: 2, length: 0)])
    }

    @Test func 選択の外から押したドラッグは選択を広げる() throws {
      let (window, view) = makeEditor(text: "hello world")
      select(view, [NSRange(location: 0, length: 5)])
      view.mouseDown(with: try mouseEvent(.leftMouseDown, at: try point(at: 6, in: view), in: window))
      view.mouseDragged(
        with: try mouseEvent(
          .leftMouseDragged, at: try point(at: 9, fraction: 0.9, in: view), in: window))
      view.mouseUp(with: try mouseEvent(.leftMouseUp, at: try point(at: 9, in: view), in: window))
      #expect(ranges(view) == [NSRange(location: 6, length: 4)])
    }

    @Test func 選択の上でもシフトを押していれば選択を広げる() throws {
      let (window, view) = makeEditor(text: "hello world")
      select(view, [NSRange(location: 0, length: 5)])
      view.mouseDown(
        with: try mouseEvent(
          .leftMouseDown, at: try point(at: 2, in: view), in: window, modifiers: .shift))
      #expect(ranges(view) == [NSRange(location: 0, length: 2)])
    }

    @Test func 選択の上での二回目のクリックは単語を選ぶ() throws {
      let (window, view) = makeEditor(text: "hello world")
      select(view, [NSRange(location: 0, length: 11)])
      view.mouseDown(
        with: try mouseEvent(.leftMouseDown, at: try point(at: 7, in: view), in: window, clickCount: 2))
      #expect(ranges(view) == [NSRange(location: 6, length: 5)])
    }

    @Test func 選択の上を押してしきい値を超えて動かすとドラッグを始める() throws {
      let (window, view) = makeEditor(text: "aa bb cc dd")
      select(view, [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])
      var sessions: [[NSDraggingItem]] = []
      view.dragAndDrop.beginSession = { _, items, _ in sessions.append(items) }
      let down = try point(at: 1, in: view)
      view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, in: window))
      view.mouseDragged(
        with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: down.x + 2, y: down.y), in: window))
      #expect(sessions.isEmpty)
      view.mouseDragged(
        with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: down.x + 4, y: down.y), in: window))
      view.mouseDragged(
        with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: down.x + 8, y: down.y), in: window))
      #expect(sessions.count == 1)
      let item = try #require(sessions.first?.first)
      #expect((item.item as? NSString) == "aa\ncc")
      #expect(item.imageComponents?.isEmpty == false)
      let dragged = try #require(view.dragAndDrop.dragged)
      #expect(dragged.ranges == [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])
      #expect(dragged.textVersion == view.textVersion)
      // 選択はそのまま。
      #expect(ranges(view) == [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)])

      // 始めたドラッグをビューの中に落とすと移動になる。
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      pasteboard.clearContents()
      pasteboard.writeObjects([try #require(item.item as? NSString)])
      let info = FakeDraggingInfo(
        window: window, location: try point(at: 3, in: view), pasteboard: pasteboard,
        mask: EditorView.sourceOperationMask(for: .withinApplication), source: view)
      #expect(view.draggingEntered(info) == .move)
      #expect(view.performDragOperation(info))
      #expect(view.text == " aa\nccbb  dd")
    }

    @Test func 運ぶ元はアプリの中へは移動もでき_ほかのアプリへはコピーにする() {
      #expect(EditorView.sourceOperationMask(for: .withinApplication) == [.copy, .move, .generic])
      #expect(EditorView.sourceOperationMask(for: .outsideApplication) == [.copy, .generic])
    }

    @Test func キーでないウィンドウで選択の上を押して離しても選択を変えない() throws {
      let (window, view) = makeEditor(text: "hello world", key: false)
      select(view, [NSRange(location: 0, length: 5)])
      let down = try point(at: 2, in: view)
      let event = try mouseEvent(.leftMouseDown, at: down, in: window)
      #expect(view.acceptsFirstMouse(for: event))
      #expect(view.shouldDelayWindowOrdering(for: event))
      view.mouseDown(with: event)
      view.mouseUp(with: try mouseEvent(.leftMouseUp, at: down, in: window))
      #expect(ranges(view) == [NSRange(location: 0, length: 5)])
      // 選択の外の押下は、ウィンドウを前に出すだけで受け取らない。
      let outside = try mouseEvent(.leftMouseDown, at: try point(at: 8, in: view), in: window)
      #expect(!view.acceptsFirstMouse(for: outside))
      #expect(!view.shouldDelayWindowOrdering(for: outside))
    }

    @Test func ドラッグの画像は選んだ文字だけを描く() throws {
      let (_, view) = makeEditor(text: "aa bb cc")
      select(view, [NSRange(location: 4, length: 0)])
      let selected = [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)]
      let frame = view.dragImageFrame(of: selected)
      let image = try #require(view.dragImage(of: selected, in: frame))
      let rep = try #require(image.representations.first as? NSBitmapImageRep)
      let scale = CGFloat(rep.pixelsWide) / frame.width
      /// ビューの座標の矩形の中の、色の付いた画素の数。
      func paintedPixels(in rect: CGRect) -> Int {
        let local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        var count = 0
        for x in Int(local.minX * scale)..<Int(local.maxX * scale) {
          for y in Int(local.minY * scale)..<Int(local.maxY * scale) {
            if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { count += 1 }
          }
        }
        return count
      }
      func rect(_ range: NSRange) -> CGRect {
        view.layout.selectionRects(range)[0].offsetBy(dx: view.textOrigin.x, dy: view.textOrigin.y)
      }
      // 選んだ文字は描き、間の選んでいない文字とキャレットは描かない。
      #expect(paintedPixels(in: rect(selected[0])) > 0)
      #expect(paintedPixels(in: rect(selected[1])) > 0)
      #expect(paintedPixels(in: rect(NSRange(location: 2, length: 4))) == 0)
      // 上下が反転していない: 文字は行の上半分にも下半分にもかかる (下線ではない)。
      let first = rect(selected[0])
      #expect(
        paintedPixels(in: CGRect(x: first.minX, y: first.minY, width: first.width, height: first.height / 2)) > 0)
    }

    // MARK: - 自動スクロール

    @Test func 選択のドラッグでマウスが表示の外で止まっても表示を送り続ける() throws {
      let text = (1...100).map { "line \($0)" }.joined(separator: "\n")
      let (window, view) = makeEditor(text: text)
      var timers: [ManualAutoscrollTimer] = []
      view.dragAndDrop.makeAutoscrollTimer = { _, tick in
        let timer = ManualAutoscrollTimer(tick: tick)
        timers.append(timer)
        return timer
      }
      view.mouseDown(with: try mouseEvent(.leftMouseDown, at: try point(at: 0, in: view), in: window))
      // ウィンドウの下の外 (ウィンドウの座標は下が 0)。
      let below = NSPoint(x: 50, y: -20)
      view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: below, in: window))
      let timer = try #require(timers.last)
      #expect(timers.count == 1)
      var top = view.visibleRect.minY
      var end = NSMaxRange(ranges(view)[0])
      for _ in 0..<5 {
        timer.fire()
        #expect(view.visibleRect.minY > top)
        #expect(NSMaxRange(ranges(view)[0]) > end)
        #expect(ranges(view)[0].location == 0)
        top = view.visibleRect.minY
        end = NSMaxRange(ranges(view)[0])
      }
      // 表示の中に戻ったら止める。
      view.mouseDragged(
        with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 50, y: 150), in: window))
      #expect(!timer.isValid)
      view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: below, in: window))
      let second = try #require(timers.last)
      #expect(timers.count == 2)
      view.mouseUp(with: try mouseEvent(.leftMouseUp, at: below, in: window))
      #expect(!second.isValid)
    }

    @Test func ドロップ中にマウスが表示の端で止まっても表示を送り続ける() throws {
      let text = (1...100).map { "line \($0)" }.joined(separator: "\n")
      let (window, view) = makeEditor(text: text)
      var timers: [ManualAutoscrollTimer] = []
      view.dragAndDrop.makeAutoscrollTimer = { _, tick in
        let timer = ManualAutoscrollTimer(tick: tick)
        timers.append(timer)
        return timer
      }
      let pasteboard = makePasteboard()
      defer { pasteboard.releaseGlobally() }
      pasteboard.setString("x", forType: .string)
      // 表示の下端から少し内側。
      let info = FakeDraggingInfo(window: window, location: NSPoint(x: 50, y: 4), pasteboard: pasteboard)
      #expect(view.draggingEntered(info) == .copy)
      let timer = try #require(timers.last)
      var top = view.visibleRect.minY
      let drop = try #require(view.dragAndDrop.dropOffset)
      // 端の近くに入ってすぐは送らない。
      for _ in 0..<EditorView.dropAutoscrollDelayTicks {
        timer.fire()
        #expect(view.visibleRect.minY == top)
      }
      for _ in 0..<5 {
        timer.fire()
        #expect(view.visibleRect.minY > top)
        top = view.visibleRect.minY
      }
      // ドロップ先も、送った表示に合わせて後ろへ動く。
      #expect(try #require(view.dragAndDrop.dropOffset) > drop)
      #expect(view.dragAndDrop.dropOffset == view.dropOffset(at: info.draggingLocation))
      view.draggingExited(info)
      #expect(!timer.isValid)
      #expect(view.dragAndDrop.dropOffset == nil)
    }

    @Test func 端まで送ったら選択を変えない() throws {
      let text = (1...100).map { "line \($0)" }.joined(separator: "\n")
      let (window, view) = makeEditor(text: text)
      var timers: [ManualAutoscrollTimer] = []
      view.dragAndDrop.makeAutoscrollTimer = { _, tick in
        let timer = ManualAutoscrollTimer(tick: tick)
        timers.append(timer)
        return timer
      }
      view.mouseDown(with: try mouseEvent(.leftMouseDown, at: try point(at: 6, in: view), in: window))
      // ウィンドウの上の外。表示は最初から先頭にある。
      view.mouseDragged(
        with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 50, y: 400), in: window))
      let selected = ranges(view)
      let timer = try #require(timers.last)
      timer.fire()
      #expect(view.visibleRect.minY == 0)
      #expect(ranges(view) == selected)
    }
  }
}
