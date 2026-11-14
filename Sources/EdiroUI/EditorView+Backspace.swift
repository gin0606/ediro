import AppKit
import EdiroCore

/// Backspace でリストのマーカーと字下げの 1 段を消す。
///
/// 選択のないキャレットごとに、キャレットのある行と行頭からキャレットまでの文字で決める。上から
/// 最初に当たるものを当てる。
///
/// 1. リスト行 (コードブロックの外) で、キャレットが本文の開始位置: マーカーと続く空白 (チェック
///    ボックス付きならチェックボックスと続く空白まで) を消す。字下げと本文は残す
/// 2. キャレットが行頭より後ろで、行頭からキャレットまでが空白だけ: キャレットの前の 1 段ぶん
///    (`IndentUnit.backspaceLength(before:)`) を消す。コードブロックの中でも当てる
/// 3. それ以外: Backspace のほかの経路と同じく 1 文字消す
///
/// 文字の途中のキャレットは 3 に当てる。同じ行の複数のキャレットも、それぞれのキャレットの前を消す。
///
/// 1 か 2 に当たるキャレットがなければ、Backspace のほかの経路に任せる。スマート挿入削除がオンで
/// 単語の選択があればスマート削除 (`smartDeleteSelection(forward:)`)、そうでなければエンジンの
/// Backspace (`EditorSession.deleteBackward`) になる。当たるキャレットがあれば、ほかの選択と
/// キャレットはその経路と同じ範囲を消すことにして、全体を 1 回の変更で消す。取り消しのまとまりも
/// その経路に合わせ、エンジンの Backspace なら削除のまとまりに入れ、スマート削除ならまとめない。
///
/// 行は Enter・Tab・Shift+Tab と同じく `EditorLayout.hardLineRange(containing:)` の範囲。
extension EditorView {
  /// 1 か 2 に当たるキャレットがあれば消して true。変換中は何もせず false。
  func deleteListMarkerOrIndentationBackward() -> Bool {
    guard !hasMarkedText() else { return false }
    let ranges = session.selections.map { nsRange(of: $0.range) }
    let rules = ranges.map { range -> NSRange? in
      guard range.length == 0, let rule = markerOrIndentationRange(before: range.location),
        let character = engineDeletionRange(ofCaretAt: range.location, forward: false),
        NSMaxRange(character) == range.location
      else { return nil }
      return rule
    }
    guard rules.contains(where: { $0 != nil }) else { return false }
    let reference = usesSmartDeletion ? inputReference() : nil
    deleteRanges(
      zip(ranges, rules).compactMap { range, rule in
        if let rule { return rule }
        if let reference {
          return smartDeletionRange(of: range, forward: false, reference: reference)
        }
        if range.length > 0 { return range }
        return engineDeletionRange(ofCaretAt: range.location, forward: false)
      }, historyGroup: reference == nil ? "deleting" : nil)
    return true
  }

  /// キャレット `caret` で 1 か 2 に当たるときに消す範囲。
  private func markerOrIndentationRange(before caret: Int) -> NSRange? {
    let string = layout.storage.mutableString
    // どちらの規則もキャレットの直前は空白なので、ほとんどの Backspace は行を読まずに外す。
    guard caret > 0, [0x20, 0x09].contains(string.character(at: caret - 1)) else { return nil }
    let line = layout.hardLineRange(containing: caret)
    let column = caret - line.location
    if let item = listLine(in: line), column == item.contentStart {
      let start = item.markerRange.lowerBound
      return NSRange(location: line.location + start, length: column - start)
    }
    let prefix = string.substring(with: NSRange(location: line.location, length: column))
    let length = indentUnit.backspaceLength(before: prefix)
    return length > 0 ? NSRange(location: caret - length, length: length) : nil
  }
}
