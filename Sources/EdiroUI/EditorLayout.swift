import AppKit
import EditorEngine

/// Foundation にも同名の型があるため、このモジュールではエンジンの範囲を指す。
typealias TextRange = EditorEngine.TextRange

/// TextKit 2 を、エンジンが持つ本文のレイアウトと描画にだけ使う。
///
/// 本文の正本はエンジンの Document にある。ここの NSTextStorage はその写しで、
/// エンジンが通知した差分だけで書き換える。位置はどちらも UTF-16 オフセットで数える。
final class EditorLayout {
  let storage = NSTextStorage()
  let contentStorage = NSTextContentStorage()
  let layoutManager = NSTextLayoutManager()
  let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

  /// 空の行に置くキャレットの高さ。本文が無いと TextKit は既定フォントの高さを返す。
  var emptyLineHeight: CGFloat = 17

  init() {
    contentStorage.textStorage = storage
    contentStorage.addTextLayoutManager(layoutManager)
    layoutManager.textContainer = container
  }

  /// 描画の幅を変える。折り返し位置が変わるので全体を組み直す。
  func setWidth(_ width: CGFloat) {
    guard container.size.width != width else { return }
    container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    ensureLayout()
  }

  /// 本文を差分で書き換える。オフセットはその差分を当てる直前の本文で数える。
  func apply(_ batch: [ContentChange]) {
    contentStorage.performEditingTransaction {
      for change in batch.reversed() {
        storage.replaceCharacters(
          in: NSRange(location: change.offset, length: change.removedLength),
          with: change.insertedText)
      }
    }
  }

  func replaceAll(with text: String) {
    contentStorage.performEditingTransaction {
      storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
    }
  }

  func ensureLayout() {
    layoutManager.ensureLayout(for: layoutManager.documentRange)
  }

  /// 本文全体の高さ。末尾が改行なら、その後ろの空行の分も含む。
  var usedHeight: CGFloat {
    max(layoutManager.usageBoundsForTextContainer.maxY, emptyLineHeight)
  }

  // MARK: - 位置の変換

  func location(_ offset: Int) -> NSTextLocation? {
    contentStorage.location(contentStorage.documentRange.location, offsetBy: offset)
  }

  func offset(_ location: NSTextLocation) -> Int {
    contentStorage.offset(from: contentStorage.documentRange.location, to: location)
  }

  func textRange(_ range: NSRange) -> NSTextRange? {
    guard let start = location(range.location),
      let end = location(range.location + range.length)
    else { return nil }
    return NSTextRange(location: start, end: end)
  }

  // MARK: - 矩形

  /// オフセットの位置に置くキャレットの矩形。幅は 0。座標はテキストコンテナのもの。
  func caretRect(at offset: Int) -> CGRect {
    var result: CGRect?
    if let location = location(offset) {
      layoutManager.enumerateTextSegments(
        in: NSTextRange(location: location), type: .selection, options: [.rangeNotRequired]
      ) { _, rect, _, _ in
        result = rect
        return false
      }
    }
    guard let result, result.height > 0 else {
      return CGRect(x: container.lineFragmentPadding, y: 0, width: 0, height: emptyLineHeight)
    }
    return result
  }

  /// 範囲を覆う選択の矩形。行ごとに分かれる。
  func selectionRects(_ range: NSRange) -> [CGRect] {
    guard range.length > 0, let textRange = textRange(range) else { return [] }
    var rects: [CGRect] = []
    layoutManager.enumerateTextSegments(in: textRange, type: .selection, options: []) {
      _, rect, _, _ in
      rects.append(rect)
      return true
    }
    return rects
  }

  /// 表示上の行。折り返した行は別の行として数える。末尾の空行も含む。
  func lineFrames() -> [CGRect] {
    var frames: [CGRect] = []
    layoutManager.enumerateTextLayoutFragments(
      from: layoutManager.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment]
    ) { fragment in
      let origin = fragment.layoutFragmentFrame.origin
      for line in fragment.textLineFragments {
        frames.append(line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y))
      }
      return true
    }
    return frames
  }

  // MARK: - 当たり判定とナビゲーション

  /// 点に最も近い文字の境界。行の外側なら、その行の端に寄せる。
  func offset(at point: CGPoint) -> Int {
    let selections = layoutManager.textSelectionNavigation.textSelections(
      interactingAt: point, inContainerAt: layoutManager.documentRange.location, anchors: [],
      modifiers: [], selecting: true, bounds: .zero)
    guard let location = selections.first?.textRanges.first?.location else {
      return point.y < 0 ? 0 : storage.length
    }
    return offset(location)
  }

  /// 単語や行の境界までの移動先。見つからなければ nil。
  func destination(
    from offset: Int, direction: NSTextSelectionNavigation.Direction,
    destination: NSTextSelectionNavigation.Destination
  ) -> Int? {
    guard let location = location(offset) else { return nil }
    let selection = NSTextSelection(location, affinity: .downstream)
    guard
      let result = layoutManager.textSelectionNavigation.destinationSelection(
        for: selection, direction: direction, destination: destination, extending: false,
        confined: false),
      let target = result.textRanges.first?.location
    else { return nil }
    return self.offset(target)
  }

  /// オフセットを含む表示上の行の範囲。行末の改行は含めない。折り返し位置のオフセットは
  /// キャレットが描かれる次の行に属する。
  func lineRange(containing offset: Int) -> NSRange {
    let paragraph = paragraphRange(containing: offset)
    guard let location = location(offset),
      let fragment = layoutManager.textLayoutFragment(for: location)
    else { return paragraph }
    let base = self.offset(fragment.rangeInElement.location)
    let lines = fragment.textLineFragments.map {
      NSRange(location: base + $0.characterRange.location, length: $0.characterRange.length)
    }
    guard
      let line = lines.first(where: { $0.location <= offset && offset < NSMaxRange($0) })
        ?? lines.last(where: { $0.location <= offset })
    else { return paragraph }
    return NSIntersectionRange(line, paragraph).location == NSNotFound
      ? paragraph : NSIntersectionRange(line, paragraph)
  }

  /// オフセットを含む段落 (改行で区切った行) の範囲。行末の改行は含めない。
  func paragraphRange(containing offset: Int) -> NSRange {
    let string = storage.string as NSString
    var start = 0, contentsEnd = 0
    string.getLineStart(
      &start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
    return NSRange(location: start, length: contentsEnd - start)
  }

  /// オフセットを囲む単語や段落の範囲。
  func enclosingRange(of offset: Int, granularity: NSTextSelection.Granularity) -> NSRange? {
    guard let location = location(offset) else { return nil }
    let selection = layoutManager.textSelectionNavigation.textSelection(
      for: granularity, enclosing: NSTextSelection(location, affinity: .downstream))
    guard let range = selection.textRanges.first else { return nil }
    let start = self.offset(range.location)
    return NSRange(location: start, length: self.offset(range.endLocation) - start)
  }

  /// 表示上で一つ上か下の行の、横位置 `x` に近い位置。端の行から出ると文書の端へ寄せる。
  func verticalOffset(from offset: Int, up: Bool, x: CGFloat) -> Int {
    let caret = caretRect(at: offset)
    let lines = lineFrames()
    guard
      let current = lines.lastIndex(where: { $0.minY <= caret.midY && caret.midY < $0.maxY })
    else { return offset }
    let target = up ? current - 1 : current + 1
    guard lines.indices.contains(target) else { return up ? 0 : storage.length }
    return self.offset(at: CGPoint(x: x, y: lines[target].midY))
  }
}

/// エンジンの上下移動は、表示上の行と横位置を知るこの層に任せる。
extension EditorLayout: LayoutAdapter {
  func moveVertically(
    from position: Position, direction: VerticalDirection, preferredAdvance: Double?,
    snapshot: TextSnapshot
  ) throws -> LayoutMovement {
    let offset = try snapshot.offset(at: position)
    let x = preferredAdvance.map { CGFloat($0) } ?? caretRect(at: offset).minX
    let target = verticalOffset(from: offset, up: direction == .up, x: x)
    return LayoutMovement(position: try snapshot.position(at: target), preferredAdvance: Double(x))
  }

  func position(at display: DisplayPosition, snapshot: TextSnapshot) throws -> Position {
    let lines = lineFrames()
    guard lines.indices.contains(display.row) else { throw EditorError.invalidPosition }
    let offset = offset(at: CGPoint(x: display.advance, y: lines[display.row].midY))
    return try snapshot.position(at: offset)
  }

  func displayPosition(at position: Position, snapshot: TextSnapshot) throws -> DisplayPosition {
    let caret = caretRect(at: try snapshot.offset(at: position))
    let row = lineFrames().lastIndex(where: { $0.minY <= caret.midY }) ?? 0
    return DisplayPosition(row: row, advance: Double(caret.minX))
  }
}
