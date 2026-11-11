import AppKit
import EditorEngine
import EditorMarkdown

struct LinkState {
  /// URL を開き、開けたかを返す。既定のブラウザで開き、テストでは差し替える。
  var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
  /// URL を作れなかったときや開けなかったときに鳴らす。テストでは差し替える。
  var beep: () -> Void = { NSSound.beep() }
  /// URL の上で Cmd を押したまま、まだ離していない押下。ドラッグせずに離したら URL を開く。
  /// URL を作れなかった `url` トークンでは `url` が nil で、離したときに警告音を鳴らす。
  var pressed: (event: NSEvent, url: URL?, wasKey: Bool)?
  /// 続けて押している一連のクリックで、もう URL を開いたか。ダブルクリックの二回目以降は
  /// 開かずに、これまでどおり単語や段落を選ぶ。
  var openedInClickSequence = false
  /// ツールチップを出している URL の範囲と、その文字の矩形 (ビューの座標) に付けたツールチップ。
  /// 矩形は、付けたときに見えていた範囲に掛かる表示行のものだけ。見えていない表示行を外した
  /// ときは、その範囲を `clippedTo` (ビューの座標) に持つ。
  var toolTip: (range: NSRange, clippedTo: CGRect?, rects: [CGRect], tags: [NSView.ToolTipTag])?
}

/// 本文の URL を Cmd+クリックで開き、URL の上ではツールチップで操作を知らせる。
///
/// 開ける範囲は、その行の `url` トークン (`Document.lineTokens(in:)`) だけで決め、Markdown や
/// URL をここで解釈し直さない。そのため、コードの中の URL、リンクのラベル、スキームの無い
/// `example.com` やメールアドレスは開かない。Smart Links の設定とは関係なく動く。
extension EditorView: NSViewToolTipOwner {
  static let linkToolTip = "⌘-click to open link"

  /// 点 (本文の配置の座標) が掛かる文字を含む `url` トークンの範囲と、そこから作った URL。
  /// 文字に掛からない点 (行の右の余白など) や、`url` トークンでない文字の上なら nil。
  func link(at point: CGPoint) -> (range: NSRange, url: URL?)? {
    guard let index = layout.characterIndex(containing: point) else { return nil }
    return link(containing: index)
  }

  /// オフセット `index` の文字を含む `url` トークンの範囲と、そこから作った URL。
  /// 和文など URL に使えない文字は `URL(string:)` がパーセントエンコードする。
  func link(containing index: Int) -> (range: NSRange, url: URL?)? {
    let snapshot = document.snapshot
    guard let line = try? snapshot.position(at: index).line,
      let tokens = try? document.lineTokens(in: line..<(line + 1))
    else { return nil }
    for token in tokens where MarkdownTokenKind(token) == .url {
      guard let offsets = try? snapshot.offsets(in: token.range), offsets.contains(index),
        let text = try? snapshot.line(line)
      else { continue }
      let inLink = tokens.contains {
        MarkdownTokenKind($0) == .link && $0.range.start <= token.range.start
          && token.range.end <= $0.range.end
      }
      let address = MarkdownTokenizer.address(
        ofURLTokenAt: token.range.start.column..<token.range.end.column, in: text,
        inLinkDestination: inLink)
      return (NSRange(offsets), URL(string: address))
    }
    return nil
  }

  /// Cmd だけを押したクリックか。ほかの修飾キーも押していれば、これまでどおりのクリックにする。
  static func isLinkClick(_ event: NSEvent) -> Bool {
    event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command
  }

  // MARK: - ツールチップ

  /// マウスの位置 (本文の配置の座標) の URL にツールチップを付ける。前の URL のツールチップは外す。
  ///
  /// ツールチップは URL の文字の矩形にだけ付け、URL を出入りするたびに付け替える。ビュー全体に
  /// 一つ付けて点ごとに文言を変える方法は、同じ矩形の中で URL とそれ以外の間を動いたときに
  /// 表示が切り替わる保証が無いので採らない。
  func updateLinkToolTip(at point: CGPoint?) {
    let range = point.flatMap { link(at: $0)?.range }
    // 長いリンクの行き先は長さに上限が無いので、見えている表示行の分だけ付け、はみ出した URL は
    // スクロールした後にマウスが動いたら付け直す。
    let visible = visibleRect
    if range == links.toolTip?.range {
      guard let clipped = links.toolTip?.clippedTo, clipped != visible else { return }
    }
    removeLinkToolTip()
    guard let range else { return }
    let found = layout.characterRects(
      range, in: visible.offsetBy(dx: -textOrigin.x, dy: -textOrigin.y))
    let rects = found.rects.map { $0.offsetBy(dx: textOrigin.x, dy: textOrigin.y) }
    let tags = rects.map { addToolTip($0, owner: self, userData: nil) }
    links.toolTip = (range, found.isComplete ? nil : visible, rects, tags)
  }

  /// URL のツールチップを外す。本文や配置が変わると矩形がずれるので、そのときにも外し、
  /// 次にマウスが動いたときに付け直す。
  func removeLinkToolTip() {
    guard let toolTip = links.toolTip else { return }
    toolTip.tags.forEach(removeToolTip)
    links.toolTip = nil
  }

  func view(
    _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
    userData data: UnsafeMutableRawPointer?
  ) -> String {
    Self.linkToolTip
  }

  override func mouseEntered(with event: NSEvent) {
    updateLinkToolTip(at: containerPoint(event))
  }

  override func mouseMoved(with event: NSEvent) {
    updateLinkToolTip(at: containerPoint(event))
  }

  override func mouseExited(with event: NSEvent) {
    updateLinkToolTip(at: nil)
  }
}
