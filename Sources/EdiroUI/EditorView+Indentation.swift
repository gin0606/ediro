import AppKit
import EdiroCore
import EditorEngine
import EditorMarkdown

/// Tab と Shift+Tab での字下げ・字上げ。
///
/// 次のどれかに当たる選択は、行単位の操作になる。
///
/// - 選択が改行を含む。対象は選択が掛かっている全行。ただし選択の終わりが行頭にある行は含めない
/// - リスト行 (コードブロックの外) にキャレットか 1 行の中の選択がある。対象はその行
/// - Shift+Tab。上のどちらでもなければ、キャレットのある行が対象
///
/// 同じ行が複数の選択の対象になっても、行への操作は 1 回だけ当てる。行単位の操作は、それだけで
/// 1 回の取り消しになる。
///
/// 行は `EditorLayout.hardLineRange(containing:)` の範囲。エンジンの行は LF でしか区切らないが、
/// 表示と同じく U+2029 や改ページなどでも区切る。
extension EditorView {
  /// `line` (`layout.hardLineRange(containing:)` の範囲) がコードブロックの外のリスト行なら、
  /// その項目。
  func listLine(in line: NSRange) -> ListLine? {
    let text = layout.storage.mutableString.substring(with: line)
    guard let item = ListLine(text), !isInCodeBlock(lineStartingAt: line.location) else {
      return nil
    }
    return item
  }

  /// `start` から始まる行がコードブロックの中にあるか。フェンスの内側の行は、行頭からエンジンの
  /// `codeBlock` トークンになる。フェンスの行も行頭から `codeBlock` になるので中として扱うが、
  /// バッククォートで始まる行はリスト行にならないので、リスト行の判定には響かない。
  func isInCodeBlock(lineStartingAt start: Int) -> Bool {
    let position = position(of: start)
    guard let tokens = try? document.lineTokens(in: position.line..<(position.line + 1)) else {
      return false
    }
    return tokens.contains { MarkdownTokenKind($0) == .codeBlock && $0.range.start == position }
  }

  /// Tab。行単位の操作になる選択があれば、対象の行の行頭に 1 段足す (空行には足さない)。
  /// 行単位の操作にならない選択は、選択を 1 段で置き換える。ただし、その行がほかの選択の
  /// 行単位の操作の対象なら、行の字下げだけにする。
  ///
  /// 行単位の操作がなければ、打鍵として入れて自動置換と検査に回す。
  func indent() {
    guard !hasMarkedText() else { return }
    let unit = indentUnit.text
    let ranges = session.selections.map { nsRange(of: $0.range) }
    let targets = ranges.map(targetLines(of:))
    let lineLevel = targets.map { $0.crossesLines || listLine(in: $0.lines[0]) != nil }
    guard lineLevel.contains(true) else {
      typing { try session.type(unit, historyGroup: "typing") }
      return
    }
    let lines = Self.uniqueLines(zip(lineLevel, targets).filter(\.0).flatMap(\.1.lines))
    let starts = Set(lines.map(\.location))
    var replacements = lines.filter { $0.length > 0 }.map {
      Replacement(NSRange(location: $0.location, length: 0), unit)
    }
    var inserted: [Int: NSRange] = [:]
    for (index, range) in ranges.enumerated()
    where !lineLevel[index] && !starts.contains(targets[index].lines[0].location) {
      inserted[index] = range
      replacements.append(Replacement(range, unit))
    }
    replacements.sort { $0.range.location < $1.range.location }
    guard !replacements.isEmpty else { return }
    var selections = keepingCharacters(after: replacements)
    for (index, range) in inserted {
      let caret = offset(NSMaxRange(range), after: replacements)
      selections[index] = (caret, caret)
    }
    replace(replacements, selecting: selections)
  }

  /// Shift+Tab。どの選択も行単位の操作にして、対象の行の行頭から 1 段消す。字下げのない行は
  /// そのまま。
  func outdent() {
    guard !hasMarkedText() else { return }
    let string = layout.storage.mutableString
    let lines = Self.uniqueLines(
      session.selections.flatMap { targetLines(of: nsRange(of: $0.range)).lines })
    let replacements = lines.compactMap { line -> Replacement? in
      let length = indentUnit.outdentLength(of: string.substring(with: line))
      guard length > 0 else { return nil }
      return Replacement(NSRange(location: line.location, length: length), "")
    }
    guard !replacements.isEmpty else { return }
    replace(replacements, selecting: keepingCharacters(after: replacements))
  }

  /// 選択が行単位の操作になるときの対象の行と、選択が行を跨ぐか。選択の終わりが行頭にある行は
  /// 対象に含めない。
  private func targetLines(of range: NSRange) -> (lines: [NSRange], crossesLines: Bool) {
    let first = layout.hardLineRange(containing: range.location)
    let last = layout.hardLineRange(containing: NSMaxRange(range))
    var lines = [first]
    while let current = lines.last, current.location < last.location,
      let next = line(after: current), next.location != NSMaxRange(range)
    {
      lines.append(next)
    }
    return (lines, last.location != first.location)
  }

  /// `line` の次の行。最後の行なら nil。
  private func line(after line: NSRange) -> NSRange? {
    let start = NSMaxRange(line) + 1
    return start <= layout.storage.length ? layout.hardLineRange(containing: start) : nil
  }

  /// 同じ行を 1 つにまとめ、先頭の順に並べた行。
  private static func uniqueLines(_ lines: [NSRange]) -> [NSRange] {
    Dictionary(lines.map { ($0.location, $0) }, uniquingKeysWith: { first, _ in first }).values
      .sorted { $0.location < $1.location }
  }
}
