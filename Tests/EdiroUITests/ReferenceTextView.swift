import AppKit

/// 置き換え前のエディタと同じ設定の NSTextView。既定のテストは、引用符の形や取り消し名の
/// ように結果がシステムの言語や設定で変わるものの期待値に、同じ操作をしたこれの結果を使う。
/// NSTextView に合わせる義務は無く、振る舞いを変えるときは、これと比べているテストを直す。
///
/// 編集に関わる設定は commit 8dea10d の `EditorTextController` の初期化と同じにする。
/// 旧版が持っていた Markdown の装飾、外観 (段落スタイル・書体・色)、委譲は載せない。
/// 委譲が入力の結果を変えていたのは改行時の字下げで、それは新しいエディタ側のテストで
/// 確かめている。
///
/// 取り消しの記録と自動置換はウィンドウを必要とするので、ウィンドウに載せて返す。
/// テストのプロセスはアプリとして起動していないので、このウィンドウはキーにならない。
/// キーのウィンドウや起動済みのアプリを前提にする処理は、ここでは観測できないことがある。
/// 使い終わったら `close()` で閉じる。
final class ReferenceTextView {
  private let window: NSWindow
  let textView: NSTextView

  init(text: String = "") {
    let scrollView = NSTextView.scrollableTextView()
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

  /// 打鍵が最後に呼ぶ `insertText(_:replacementRange:)` で、文字を一つずつ入れる。キー入力の
  /// 解釈と入力メソッドは通らないので、インライン予測のような入力メソッド側の提示は現れない。
  ///
  /// 自動置換やスペルチェックは、打鍵の後でメインキューに回された処理が行う。同期のまま
  /// 続けて入れたり実行ループを回したりしても、テストを実行中のメインキューの処理は
  /// 進まない。そのため、一打ごとにメインアクターを明け渡す。
  func type(_ text: String) async {
    for character in text {
      textView.insertText(
        String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
      try? await Task.sleep(for: .milliseconds(20))
    }
    try? await Task.sleep(for: .milliseconds(500))
  }
}
