import AppKit
import EdiroCore

/// Enter での改行。リストの項目を続け、空の項目と空白だけの行では改行せずに 1 段ずつ戻る。
///
/// 選択ごとに、選択を消した後の行 (選択の始まりの行の前半と、選択の終わりの行の後半) と、その中の
/// 選択の始まりの位置 (キャレット) で決める。上から最初に当たるものを当てる。
///
/// 1. コードブロックの中: 改行して、キャレットより前の行頭の空白を引き継ぐ (以下「ふつうの改行」)
/// 2. 空の項目で、キャレットが本文の開始位置以降: 改行しない。字下げがあれば 1 段消して、マーカーを
///    戻った先のマーカー (`returnedMarker(width:above:original:)`) にする。字下げがなければ
///    マーカーごと消して空行にする
/// 3. 本文のあるリスト行で、キャレットが本文の開始位置以降: 改行して、同じ字下げと次のマーカーを
///    入れる。チェックボックスは未チェックで入れる
/// 4. 空白だけの行 (空行とリスト行を除く) で、キャレットが行末: 改行しない。行頭から 1 段消す
/// 5. それ以外: ふつうの改行
///
/// 改行する選択だけなら打鍵として入れる。改行しない選択 (行への操作) があれば、全体をそれだけで
/// 1 回の取り消しにする。行への操作の対象の行に収まるほかの選択は、Tab の行単位の操作と同じく
/// 文字を入れず、行への操作の後のキャレットに移す。それ以外の選択が行への操作の対象の行を見て
/// 変更を決めていれば (選択の始まりか終わりの行が同じ)、どの選択もふつうの改行にする。
///
/// どの選択も Enter を押す前の本文で決める。
///
/// 行は Tab と Shift+Tab と同じく `EditorLayout.hardLineRange(containing:)` の範囲。
extension EditorView {
  /// 1 つの選択への Enter の変更。`range` を `text` で置き換え、入れた文字の後ろにキャレットを置く。
  private struct NewlineEdit {
    let range: NSRange
    let text: String
    /// 改行せずに行を書き換える (行への操作)。`range` は `lines` と同じ。
    let rewritesLine: Bool
    /// 変更を決めるのに見た行の範囲。選択の始まりの行の先頭から、選択の終わりの行の末尾まで。
    let lines: NSRange
    /// この選択でのふつうの改行の文字。
    let newline: String
  }

  func insertNewlineInContext() {
    // 変換中は本文を変えない。打鍵の経路でも変換中の入力は断られる。
    guard !hasMarkedText() else { return }
    let edits = session.selections.map { newlineEdit(for: nsRange(of: $0.range)) }
    guard edits.contains(where: \.rewritesLine) else {
      typing { try session.type(edits.map(\.text), historyGroup: "typing") }
      return
    }
    guard let (kept, owners) = Self.merging(edits) else {
      // ほかの選択が行への操作の行を見て変更を決めていると、両方を当てても意味が通らない。
      typing { try session.type(edits.map(\.newline), historyGroup: "typing") }
      return
    }

    let replacements = kept.map { Replacement($0.range, $0.text) }
    let selections = owners.map { owner -> (anchor: Int, head: Int) in
      let caret = offset(NSMaxRange(kept[owner].range), after: replacements)
      return (caret, caret)
    }
    replace(replacements, selecting: selections)
  }

  /// 行への操作の範囲 (両端を含む) に収まる変更を、その操作にまとめる。返すのは、残した変更を
  /// 位置の順に並べたものと、各変更をまとめた先 (残した変更の番号)。まとめなかった変更が
  /// 行への操作の行を見て決めたものなら nil。
  private static func merging(_ edits: [NewlineEdit]) -> (kept: [NewlineEdit], owners: [Int])? {
    // 同じ位置からなら長い範囲を先に見て、それに収まる変更をまとめられるようにする。
    let order = edits.indices.sorted {
      (edits[$0].range.location, -edits[$0].range.length)
        < (edits[$1].range.location, -edits[$1].range.length)
    }
    var kept: [NewlineEdit] = []
    var owners = Array(repeating: 0, count: edits.count)
    for index in order {
      let edit = edits[index]
      if let last = kept.last, last.rewritesLine, NSMaxRange(edit.range) <= NSMaxRange(last.range) {
        owners[index] = kept.count - 1
        continue
      }
      owners[index] = kept.count
      kept.append(edit)
    }
    // 見た行は選択の始まりの行と終わりの行の分だけ選択より広いだけなので、行への操作の行と
    // 重なる変更があれば、位置の順で隣り合う組のどれかが同じ行で重なる。
    let overlaps = zip(kept, kept.dropFirst()).contains { previous, next in
      (previous.rewritesLine || next.rewritesLine)
        && next.lines.location <= NSMaxRange(previous.lines)
    }
    return overlaps ? nil : (kept, owners)
  }

  private func newlineEdit(for range: NSRange) -> NewlineEdit {
    let string = layout.storage.mutableString
    let first = layout.hardLineRange(containing: range.location)
    let last = layout.hardLineRange(containing: NSMaxRange(range))
    let before = string.substring(
      with: NSRange(location: first.location, length: range.location - first.location))
    let after = string.substring(
      with: NSRange(location: NSMaxRange(range), length: NSMaxRange(last) - NSMaxRange(range)))
    let line = before + after
    let lines = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    let caret = before.utf16.count
    let plain = "\n" + Indentation.leadingWhitespace(of: before)
    func inserting(_ text: String) -> NewlineEdit {
      NewlineEdit(range: range, text: text, rewritesLine: false, lines: lines, newline: plain)
    }
    // 書き換えるのは空の項目か空白だけの行で、キャレットは行末にあるので、書き換えた行の末尾に
    // キャレットを置けばよい。
    func rewriting(to text: String) -> NewlineEdit {
      NewlineEdit(range: lines, text: text, rewritesLine: true, lines: lines, newline: plain)
    }

    let ns = line as NSString
    if let item = ListLine(line), caret >= item.contentStart,
      !isInCodeBlock(lineStartingAt: first.location)
    {
      guard item.isEmpty else {
        let prefix =
          ns.substring(to: item.markerRange.lowerBound) + item.marker.next.text
          + afterMarker(of: item, in: ns, through: item.contentStart)
        return inserting("\n" + prefix)
      }
      guard !item.indentation.isEmpty else { return rewriting(to: "") }
      let outdent = indentUnit.outdentLength(of: line)
      let indentation = ns.substring(
        with: NSRange(location: outdent, length: item.markerRange.lowerBound - outdent))
      let marker = returnedMarker(
        width: indentUnit.width(of: indentation), above: first, original: item.marker)
      return rewriting(
        to: indentation + marker.text + afterMarker(of: item, in: ns, through: ns.length))
    }
    if ns.length > 0, caret == ns.length, Indentation.isBlank(line),
      !isInCodeBlock(lineStartingAt: first.location)
    {
      return rewriting(to: ns.substring(from: indentUnit.outdentLength(of: line)))
    }
    return inserting(plain)
  }

  /// 項目 `item` (行 `line`) のマーカーの直後から `end` までの文字。チェックボックスは未チェックにする。
  private func afterMarker(of item: ListLine, in line: NSString, through end: Int) -> String {
    let markerEnd = item.markerRange.upperBound
    guard let checkbox = item.checkbox?.range else {
      return line.substring(with: NSRange(location: markerEnd, length: end - markerEnd))
    }
    return line.substring(
      with: NSRange(location: markerEnd, length: checkbox.lowerBound - markerEnd)) + "[ ]"
      + line.substring(
        with: NSRange(location: checkbox.upperBound, length: end - checkbox.upperBound))
  }

  /// 空の項目を字上げして字下げの幅が `width` になったときのマーカー。行 `line` より上の行を
  /// 近い順に見て、空行 (空白だけの行を含む) と `width` より深い行を飛ばし、最初に幅が `width`
  /// の行がリスト行ならその次のマーカーにする。その行がリスト行でない (コードブロックの中の行を
  /// 含む)、`width` より浅い行に先に当たる、または文書の先頭に達したら `original` のまま。
  private func returnedMarker(width: Int, above line: NSRange, original: ListLine.Marker)
    -> ListLine.Marker
  {
    let string = layout.storage.mutableString
    var current = line
    while current.location > 0 {
      current = layout.hardLineRange(containing: current.location - 1)
      let text = string.substring(with: current)
      guard !Indentation.isBlank(text) else { continue }
      let lineWidth = indentUnit.width(of: text)
      if lineWidth > width { continue }
      guard lineWidth == width, let item = ListLine(text),
        !isInCodeBlock(lineStartingAt: current.location)
      else { break }
      return item.marker.next
    }
    return original
  }
}
