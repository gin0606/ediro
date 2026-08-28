import AppKit
import EdiroCore

/// エディタの NSTextView を組み立てて保持する。
public final class EditorTextController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
  public let scrollView: NSScrollView
  public let textView: NSTextView

  private let state: AppState
  private var theme: Theme
  private var preferences: Preferences

  public init(state: AppState) {
    self.state = state
    self.theme = state.theme
    self.preferences = state.preferences

    scrollView = NSTextView.scrollableTextView()
    guard let textView = scrollView.documentView as? NSTextView else {
      preconditionFailure("scrollableTextView() が NSTextView を返さなかった")
    }
    self.textView = textView
    super.init()

    // リッチテキストを無効にすると、コピー時にクリップボードへ載るのが
    // プレーンテキストだけになる。チャットへの貼り付けで書式が付いてこない。
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.isVerticallyResizable = true
    textView.textContainer?.widthTracksTextView = true
    scrollView.hasVerticalScroller = true

    textView.delegate = self
    textView.textStorage?.delegate = self

    // textStorage の delegate はこの代入で didProcessEditing を呼ぶため、
    // ハイライトはここで一度掛かる。明示的に掛け直すと全文を二度走査する。
    textView.string = state.text
    applyAppearance()
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

  /// 外側から本文が差し替わったときだけ書き戻す。入力のたびに代入すると
  /// カーソル位置と変換中の文字が飛ぶ。
  public func syncFromState() {
    if textView.string != state.text {
      let selected = textView.selectedRange()
      textView.string = state.text
      textView.setSelectedRange(
        NSRange(location: min(selected.location, (state.text as NSString).length), length: 0))
    }

    // 打鍵のたびにも呼ばれる。見た目に関わる値が動いていなければ、外観の
    // 塗り直しもハイライトも要らない。
    guard theme != state.theme || preferences != state.preferences else { return }
    theme = state.theme
    preferences = state.preferences
    applyAppearance()
    highlight()
  }

  private func applyAppearance() {
    let paragraphStyle = ParagraphStyle.make(for: preferences)
    textView.backgroundColor = theme.editorBackground.nsColor
    textView.insertionPointColor = theme.editorForeground.nsColor
    scrollView.backgroundColor = theme.editorBackground.nsColor
    textView.defaultParagraphStyle = paragraphStyle
    // textView.font へ代入すると本文全体のフォントが一律に塗り替えられ、
    // トークンごとに付けた見出しサイズや太字が消える。
    // 入力中の書体は typingAttributes 側に設定する。
    textView.typingAttributes[.font] = FontResolver(preferences: preferences).bodyFont
    textView.typingAttributes[.paragraphStyle] = paragraphStyle
    textView.typingAttributes[.foregroundColor] = theme.editorForeground.nsColor
  }

  public func highlight() {
    guard let storage = textView.textStorage else { return }
    MarkdownAttributer(theme: theme, preferences: preferences).apply(to: storage)
  }

  public func textDidChange(_ notification: Notification) {
    state.text = textView.string
  }

  /// 改行したときに前の行と同じ深さから書き始められるようにする。
  /// 引き継ぐ空白が無い行では既定の改行に任せ、取り消し操作や入力中の
  /// 変換に手を加えない。
  public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }

    let indent = Indentation.leadingWhitespace(
      in: textView.string, at: textView.selectedRange().location)
    guard !indent.isEmpty else { return false }

    textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
    return true
  }

  /// 属性の付け直しは編集処理が終わったこの時点で行う。
  public func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    MarkdownAttributer(theme: theme, preferences: preferences).apply(to: textStorage)
  }
}
