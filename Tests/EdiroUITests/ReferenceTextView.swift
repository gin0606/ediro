import AppKit

/// 置き換え前のエディタと同じ設定の NSTextView。新しいエディタの振る舞いを決めるときに、
/// 同じ操作の結果を比べる相手にする。
///
/// 編集に関わる設定は commit 8dea10d の `EditorTextController` の初期化と同じにする。
/// 旧版が持っていた Markdown の装飾、外観 (段落スタイル・書体・色)、委譲は載せない。
/// 委譲が入力の結果を変えていたのは改行時の字下げで、それは新しいエディタ側のテストで
/// 確かめている。外観を載せないので、行の高さや文字の矩形は旧版と一致しない。
///
/// 旧版は編集のたびに Markdown の装飾で本文の属性を置き直していた。そのため、ここで本文に
/// 付く属性 (スマートリンクの `.link` など) は、旧版では次の編集の後に残らない。
///
/// 右クリックメニューやスペルチェックはウィンドウを必要とするので、ウィンドウに載せて返す。
/// テストのプロセスはアプリとして起動していないので、このウィンドウはキーにならない。
/// キーのウィンドウや起動済みのアプリを前提にする処理は、ここでは観測できないことがある。
/// 使い終わったら `close()` で閉じる。
final class ReferenceTextView {
  let window: NSWindow
  let scrollView: NSScrollView
  let textView: NSTextView

  init(text: String = "") {
    scrollView = NSTextView.scrollableTextView()
    guard let textView = scrollView.documentView as? NSTextView else {
      preconditionFailure("scrollableTextView() が NSTextView を返さなかった")
    }
    self.textView = textView
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
    textView.string = text

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    window.makeFirstResponder(textView)
    window.orderFront(nil)
  }

  func close() { window.close() }

  /// 本文の `location` の文字の上で右クリックしたときの、ウィンドウ座標のイベント。
  func rightMouseDown(at location: Int) -> NSEvent? {
    let screenRect = textView.firstRect(
      forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
    // 配置されていない位置では空の矩形が返り、別の場所をクリックしたことになる。
    guard !screenRect.isEmpty else { return nil }
    let point = window.convertPoint(fromScreen: NSPoint(x: screenRect.midX, y: screenRect.midY))
    return NSEvent.mouseEvent(
      with: .rightMouseDown, location: point, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
  }

  /// 打鍵が最後に呼ぶ `insertText(_:replacementRange:)` で、文字を一つずつ入れる。キー入力の
  /// 解釈と入力メソッドは通らないので、インライン予測のような入力メソッド側の提示は現れない。
  ///
  /// 自動置換やスペルチェックは、打鍵の後でメインキューに回された処理が行う。同期のまま
  /// 続けて入れたり実行ループを回したりしても、テストを実行中のメインキューの処理は
  /// 進まない。そのため、一打ごとにメインアクターを明け渡す。
  func type(_ text: String, settle: Duration = .milliseconds(500)) async {
    for character in text {
      textView.insertText(
        String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
      try? await Task.sleep(for: .milliseconds(20))
    }
    try? await Task.sleep(for: settle)
  }
}
