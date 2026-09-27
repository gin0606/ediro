import AppKit
import EdiroCore

/// エディタの NSTextView を組み立てて保持する。
public final class EditorTextController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
  public let scrollView: NSScrollView
  public let textView: NSTextView

  private let state: AppState
  private var synchronizedText: String
  private var theme: Theme
  private var preferences: Preferences

  private let enqueueHighlight: (@escaping @MainActor () -> Void) -> Void
  private var scheduledHighlight: UUID?
  private var typingContext:
    (
      text: String, range: NSRange, attributes: [NSAttributedString.Key: Any]
    )?

  public convenience init(state: AppState) {
    self.init(
      state: state,
      enqueueHighlight: { update in
        Task { @MainActor in update() }
      })
  }

  init(state: AppState, enqueueHighlight: @escaping (@escaping @MainActor () -> Void) -> Void) {
    self.state = state
    self.synchronizedText = state.text
    self.theme = state.theme
    self.preferences = state.preferences
    self.enqueueHighlight = enqueueHighlight

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

    textView.string = state.text
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

  /// 外側から本文が差し替わったときだけ書き戻す。入力のたびに代入すると
  /// カーソル位置と変換中の文字が飛ぶ。
  public func syncFromState() {
    // 未確定文字は state にまだ入っていない。画面との差分だけでは外部変更と区別できない。
    if synchronizedText != state.text {
      synchronizedText = state.text
      if textView.string != state.text {
        let selected = textView.selectedRange()
        textView.string = state.text
        textView.setSelectedRange(
          NSRange(location: min(selected.location, (state.text as NSString).length), length: 0))
      }
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
    typingContext = nil
    let paragraphStyle = ParagraphStyle.make(for: preferences)
    textView.backgroundColor = theme.editorBackground.nsColor
    textView.insertionPointColor = theme.editorForeground.nsColor
    scrollView.backgroundColor = theme.editorBackground.nsColor
    textView.defaultParagraphStyle = paragraphStyle
    // textView.font へ代入すると本文全体のフォントが一律に塗り替えられ、
    // トークンごとに付けた見出しサイズや太字が消える。
    // 入力中の書体は typingAttributes 側に設定する。
    updateTypingAttributes()
  }

  private func updateTypingAttributes(replacing range: NSRange? = nil) {
    guard !textView.hasMarkedText() else { return }
    let text = textView.string
    let selection = range ?? textView.selectedRange()
    // AppKit は同じ編集に対して複数の delegate 通知を送る。
    // 本文・選択・外観が変わらなければ、構文解析の結果を再利用する。
    if typingContext?.text != text || typingContext?.range != selection {
      let attributes = MarkdownAttributer(theme: theme, preferences: preferences)
        .typingAttributes(in: text, replacing: selection)
      typingContext = (text, selection, attributes)
    }
    if let typingContext { textView.typingAttributes = typingContext.attributes }
  }

  // 文字編集の通知中には属性を変更しない。実行待ちの要求だけをまとめ、
  // 後続の打鍵で実行を先延ばしにしない。
  private func scheduleHighlight() {
    guard scheduledHighlight == nil else { return }
    let request = UUID()
    scheduledHighlight = request
    enqueueHighlight { [weak self] in
      guard let self, self.scheduledHighlight == request else { return }
      self.highlight()
    }
  }

  /// ハイライトを今すぐ掛け直す。予約済みの掛け直しがあれば取り消す。
  public func highlight() {
    scheduledHighlight = nil
    guard let storage = textView.textStorage else { return }
    // 変換中は敷き直さない。marked text に付いた下線や節の区切りを消してしまう。
    // 確定すると本文が変わり、didProcessEditing から掛け直しが予約される。
    guard !textView.hasMarkedText() else { return }
    MarkdownAttributer(theme: theme, preferences: preferences).apply(to: storage)
    updateTypingAttributes()
  }

  public func textDidChange(_ notification: Notification) {
    synchronizedText = textView.string
    state.text = synchronizedText
    updateTypingAttributes()
    scheduleHighlight()
  }

  public func textViewDidChangeSelection(_ notification: Notification) {
    updateTypingAttributes()
  }

  public func textView(
    _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
    replacementString: String?
  ) -> Bool {
    updateTypingAttributes(replacing: affectedCharRange)
    return true
  }

  /// 改行したときに前の行と同じ深さから書き始められるようにする。
  /// 引き継ぐ空白が無い行では既定の改行に任せ、取り消し操作や入力中の
  /// 変換に手を加えない。
  public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
    guard !textView.hasMarkedText() else { return false }

    let indent = Indentation.leadingWhitespace(
      in: textView.string, at: textView.selectedRange().location)
    guard !indent.isEmpty else { return false }

    textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
    return true
  }

  public func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    scheduleHighlight()
  }
}
