import AppKit
import ObjectiveC
import Testing

@testable import EdiroUI

/// 呼び出し側が受け取らなかったコントローラもテストの間は生かしておく。
private var retainedControllers: [EditorTextController] = []

extension CommandScenario {
  @MainActor func run(on textView: NSTextView) {
    textView.setSelectedRange(selection)
    for step in steps {
      switch step {
      case .command(let name): textView.doCommand(by: NSSelectorFromString(name))
      case .type(let text):
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
      case .select(let range): textView.setSelectedRange(range)
      }
    }
  }
}

extension AppKitTests {
  /// キーバインドのコマンドの結果を、同じ操作をした参照 NSTextView と比べる。
  /// 既定のテストは結果を表に書いて確かめ、ここでは標準の振る舞いが OS の更新で
  /// 変わっていないかを見る。食い違ったら、標準に合わせるかを決めてから表を直す。
  ///
  /// EDIRO_INVENTORY=1 swift test --filter KeyBindingReferenceTests
  /// 単語の区切りなど、結果がシステムの辞書や OS で変わるものを含むので、既定の
  /// `swift test` では走らせない。
  @Suite(.enabled(if: ProcessInfo.processInfo.environment["EDIRO_INVENTORY"] == "1"))
  struct KeyBindingReferenceTests {
    private func makeEditor(text: String, width: CGFloat = 400) -> EditorView {
      let controller = EditorTextController(state: makeState(text: text))
      controller.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 300)
      controller.editorView.setFrameSize(controller.scrollView.contentSize)
      retainedControllers.append(controller)
      return controller.editorView
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    private func ranges(_ view: EditorView) -> [NSRange] {
      view.session.selections.map { view.nsRange(of: $0.range) }
    }

    // MARK: - 単一の選択

    /// 既定のテストの表に載せない筋書き。
    nonisolated static let referenceOnlyScenarios: [CommandScenario] = [
      // 日本語の単語の区切りはシステムの辞書で決まり、OS で変わりうる。
      .init("日本語の文章です", 1, 0, "selectWord:"),
      // 半角カナの途中で終わる選択をどこまで広げるかも、単語の区切りで決まる。
      .init("abc 123 ｱｲｳ ﾃﾞｽ", 0, 14, "convertToFullWidth:"),
    ]

    nonisolated static let scenarios =
      KeyBindingCommandTests.transposeScenarios + KeyBindingCommandTests.killScenarios
      + KeyBindingCommandTests.lineBreakScenarios + KeyBindingCommandTests.markScenarios
      + KeyBindingCommandTests.selectionScenarios + KeyBindingCommandTests.editingScenarios
      + KeyBindingCommandTests.wordTransformScenarios + referenceOnlyScenarios

    @Test(arguments: scenarios)
    func 単一の選択では参照と同じ本文と選択になる(scenario: CommandScenario) {
      let reference = ReferenceTextView(text: scenario.text)
      defer { reference.close() }
      scenario.run(on: reference.textView)
      let view = makeEditor(text: scenario.text)
      scenario.run(on: view)
      #expect(view.text == reference.textView.string)
      #expect(ranges(view) == reference.textView.selectedRanges.map(\.rangeValue))
    }

    // MARK: - 応答するセレクタ

    /// 参照 NSTextView が応答し、このエディタが応答しないもの。
    ///
    /// 実装しないもの:
    /// - 書字方向: 段落スタイルの属性で、Markdown の装飾が本文全体の段落スタイルを置き直す
    ///   ため、旧版でも次の編集で元に戻っていた。
    /// - Quick Look: 添付ファイルを見せる操作で、書式なしの本文には添付が無い。
    static let notImplemented: Set<String> = [
      "makeBaseWritingDirectionLeftToRight:", "makeBaseWritingDirectionNatural:",
      "makeBaseWritingDirectionRightToLeft:", "makeTextWritingDirectionLeftToRight:",
      "makeTextWritingDirectionNatural:", "makeTextWritingDirectionRightToLeft:",
      "toggleBaseWritingDirection:", "quickLookPreviewItems:", "toggleQuickLookPreviewPanel:",
    ]

    @Test func 応答するセレクタの差は実装しないものだけ() throws {
      let proto = try #require(objc_getProtocol("NSStandardKeyBindingResponding"))
      var selectors: [Selector] = []
      for required in [true, false] {
        var count: UInt32 = 0
        guard let list = protocol_copyMethodDescriptionList(proto, required, true, &count) else {
          continue
        }
        selectors += (0..<Int(count)).compactMap { list[$0].name }
        free(list)
      }
      try #require(!selectors.isEmpty)
      // NSStandardKeyBindingResponding に無い、NSTextView の編集の action のうち、キーバインドの
      // 一覧と合わせて扱うもの。
      selectors += ["delete:", "toggleBaseWritingDirection:", "toggleQuickLookPreviewPanel:"]
        .map(NSSelectorFromString)

      let implements = KeyBindingCommandTests.implements
      let missing = Set(
        selectors.filter { implements(NSTextView.self, $0) && !implements(EditorView.self, $0) }
          .map(NSStringFromSelector))
      #expect(missing == Self.notImplemented)
      let extra = Set(
        selectors.filter { !implements(NSTextView.self, $0) && implements(EditorView.self, $0) }
          .map(NSStringFromSelector))
      // Esc で複数のキャレットを一つに戻す。NSTextView には無い。
      #expect(extra == ["cancelOperation:"])
    }

    // MARK: - 折り返し行末

    private func wrappedReference(for view: EditorView) -> ReferenceTextView {
      let reference = ReferenceTextView(text: view.text)
      reference.textView.textContainer?.widthTracksTextView = false
      reference.textView.textContainer?.size = view.layout.container.size
      reference.textView.textContainer?.lineFragmentPadding = view.layout.container.lineFragmentPadding
      reference.textView.textStorage?.setAttributedString(view.layout.storage)
      reference.textView.setSelectedRange(caret(0))
      return reference
    }

    @Test(arguments: [false, true])
    func 折り返し行末から選んで編集し参照と同じく一度で取り消せる(replacing: Bool) throws {
      let text = String(repeating: "word ", count: 40) + "\nnext"
      let view = makeEditor(text: text, width: 200)
      let reference = wrappedReference(for: view)
      defer { reference.close() }
      view.moveToEndOfLine(nil)
      reference.textView.moveToEndOfLine(nil)
      #expect(view.selectedRange() == reference.textView.selectedRange())
      view.selectLine(nil)
      reference.textView.selectLine(nil)
      #expect(view.selectedRange() == reference.textView.selectedRange())
      if replacing {
        view.insertText("X", replacementRange: caret(NSNotFound))
        reference.textView.insertText("X", replacementRange: caret(NSNotFound))
      } else {
        view.deleteBackward(nil)
        reference.textView.deleteBackward(nil)
      }
      #expect(view.text == reference.textView.string)
      #expect(view.selectedRange() == reference.textView.selectedRange())
      reference.textView.breakUndoCoalescing()
      view.undo(nil)
      reference.textView.undoManager?.undo()
      #expect(view.text == text)
      #expect(reference.textView.string == text)
    }

    @Test(arguments: ["select", "moveRight:", "moveToBeginningOfDocument:", "moveToEndOfLine:"])
    func 行末側の選択は参照と同じく次の選択や移動に従う(operation: String) {
      let view = makeEditor(text: String(repeating: "word ", count: 40), width: 200)
      let reference = wrappedReference(for: view)
      defer { reference.close() }
      view.moveToEndOfLine(nil)
      reference.textView.moveToEndOfLine(nil)
      if operation == "select" {
        view.select([view.selectedRange()], primary: 0)
        reference.textView.setSelectedRange(
          reference.textView.selectedRange(), affinity: .downstream, stillSelecting: false)
      } else {
        view.doCommand(by: NSSelectorFromString(operation))
        reference.textView.doCommand(by: NSSelectorFromString(operation))
      }
      view.selectLine(nil)
      reference.textView.selectLine(nil)
      #expect(view.text == reference.textView.string)
      #expect(view.selectedRange() == reference.textView.selectedRange())
    }
  }
}
