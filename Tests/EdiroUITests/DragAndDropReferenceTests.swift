import AppKit
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったウィンドウとコントローラもテストの間は生かしておく。
private var retainedEditors: [(NSWindow, EditorTextController)] = []

extension AppKitTests {
  /// ドロップとペーストで入る文字を、参照 NSTextView と比べる。OS を更新した後に手で回し、
  /// 標準のテキストビューの読み取りが変わっていないかを見る。
  ///
  /// EDIRO_INVENTORY=1 swift test --filter DragAndDropReferenceTests
  /// 書式付きの内容は AppKit の変換器 (RTF と WebKit) が文字にするので、OS の版で結果が変わり
  /// うる。文字コードを示さない HTML はロケールによって文字化けの仕方も変わる。そのため既定の
  /// `swift test` では走らせず、Ediro の規則で決まる部分は DragAndDropTests で確かめる。
  @Suite(.enabled(if: ProcessInfo.processInfo.environment["EDIRO_INVENTORY"] == "1"))
  struct DragAndDropReferenceTests {
    /// 参照 NSTextView と同じ大きさのキーのウィンドウに載せたエディタ。
    private func makeEditor(text: String) -> (NSWindow, EditorView) {
      let controller = EditorTextController(state: makeState(text: text))
      let window = KeyWindow(
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

    /// `location` の文字の、左端から `fraction` の所の点 (ウィンドウの座標)。
    private func point(at location: Int, fraction: CGFloat, in view: EditorView) throws -> NSPoint {
      let rect = try #require(view.layout.selectionRects(NSRange(location: location, length: 1)).first)
      return view.convert(
        NSPoint(
          x: rect.minX + rect.width * fraction + view.textOrigin.x,
          y: rect.midY + view.textOrigin.y), to: nil)
    }

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

    /// ⌘V と、サービスから文字列を受け取る `readSelection(from:)` を、参照 NSTextView の
    /// `readSelection(from:)` と比べる。
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
      pasted.select([NSRange(location: 6, length: 0)], primary: 0)
      pasted.paste(from: pasteboard)
      #expect(pasted.text == reference.textView.string)

      let (_, read) = makeEditor(text: "hello world")
      read.select([NSRange(location: 6, length: 0)], primary: 0)
      #expect(read.readSelection(from: pasteboard) == referenceAccepted)
      #expect(read.text == reference.textView.string)
    }
  }
}
