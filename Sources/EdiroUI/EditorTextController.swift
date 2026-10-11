import AppKit
import EdiroCore

/// エディタのビューを組み立て、アプリの状態と結び付ける。
public final class EditorTextController: NSObject {
  public let scrollView: NSScrollView
  let editorView: EditorView

  private let state: AppState
  private var synchronizedText: String
  private var theme: Theme
  private var preferences: Preferences
  private var attributer: MarkdownAttributer

  public init(state: AppState) {
    self.state = state
    self.synchronizedText = state.text
    self.theme = state.theme
    self.preferences = state.preferences
    attributer = MarkdownAttributer(theme: state.theme, preferences: state.preferences)

    scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .noBorder
    editorView = EditorView(text: state.text)
    editorView.autoresizingMask = [.width, .height]
    scrollView.documentView = editorView
    super.init()

    editorView.didChangeText = { [weak self] lines in self?.textDidChange(lines) }
    applyAppearance()
    // 初回だけは待たずに掛ける。最初の描画が素の本文になるのを避ける。
    highlight()
    observeState()
  }

  /// SwiftUI 経由では設定の変更を受け取れないため、状態を自分で購読する。
  /// NSViewRepresentable が updateNSView を呼ばれるのは自身が保持する値が
  /// 変わったときだけで、AppState の参照しか持たないこのビューには届かない。
  private func observeState() {
    withObservationTracking {
      _ = state.text
      _ = state.preferences
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.syncFromState()
        self?.observeState()
      }
    }
  }

  /// 外側から本文が差し替わったときだけ書き戻す。入力のたびに書き戻すと、
  /// 取り消し履歴と変換中の文字が消える。
  public func syncFromState() {
    if synchronizedText != state.text {
      synchronizedText = state.text
      if editorView.text != state.text {
        let caret = editorView.selectedRange().location
        editorView.replaceText(state.text)
        let length = (state.text as NSString).length
        editorView.select([NSRange(location: min(caret, length), length: 0)], primary: 0)
      }
    }

    // 打鍵のたびにも呼ばれる。見た目に関わる値が動いていなければ、外観の
    // 塗り直しもハイライトも要らない。
    guard theme != state.theme || preferences != state.preferences else { return }
    theme = state.theme
    preferences = state.preferences
    attributer = MarkdownAttributer(theme: theme, preferences: preferences)
    applyAppearance()
    highlight()
  }

  private func applyAppearance() {
    editorView.backgroundColor = theme.editorBackground.nsColor
    editorView.insertionPointColor = theme.editorForeground.nsColor
    scrollView.backgroundColor = theme.editorBackground.nsColor
    let font = FontResolver(preferences: preferences).bodyFont
    editorView.layout.emptyLineHeight = ceil(font.ascender - font.descender + font.leading)
  }

  /// 本文全体の装飾を付け直す。外観が変わったときに使う。
  public func highlight() {
    attributer.applyAll(of: editorView.document, to: editorView.layout.storage)
    editorView.refreshLayout()
    editorView.writingToolsLayoutDidChange()
  }

  /// 本文か変換の状態が変わるたびに、描画の前に呼ばれる。エンジンがトークンを作り直した
  /// 行だけ装飾を付け直す。編集した行は必ず含まれるので、挿入した文字が直前の文字から
  /// 引き継いだ属性もここで正される。
  private func textDidChange(_ retokenizedLines: IndexSet) {
    attributer.apply(
      lines: retokenizedLines, of: editorView.document, to: editorView.layout.storage)
    // 未確定の文字は下書きに含めない。確定した時点で反映する。
    guard !editorView.hasMarkedText() else { return }
    synchronizedText = editorView.text
    state.text = synchronizedText
  }
}
