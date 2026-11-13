import AppKit
import EditorEngine

/// 選択中に記号を打つと、選択を消さずに記号で囲む。
///
/// 空でない選択があるときに、囲む記号 1 文字を変換を経由せずに打つと、空でない選択それぞれの前に
/// 打った記号、後ろに閉じ記号を入れ、選択は元の中身を選んだまま保つ。空のキャレットには、打鍵と
/// 同じく打った記号を入れる。全体をそれだけで 1 回の取り消しにする。
///
/// 囲んだ記号は打った文字のまま入れ、打鍵した文字として扱わない。自動置換 (スマート引用符など) を
/// 掛けず、後から隣に打鍵しても置き換えない。キャレットに入れた記号は、打鍵した文字として自動置換と
/// 検査に回す。
extension EditorView {
  /// 囲む記号と、その閉じ記号。
  static let surroundingPairs: [String: String] = [
    "`": "`", "*": "*", "_": "_", "~": "~", "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'",
  ]

  /// `text` が囲む記号で空でない選択があれば、選択を囲み、キャレットには `text` を入れて true。
  /// どちらかでなければ何もせず false。変換中でないときに呼ぶ。
  func surroundSelections(with text: String) -> Bool {
    guard let close = Self.surroundingPairs[text],
      session.selections.contains(where: { !$0.isEmpty })
    else { return false }
    var replacements: [Replacement] = []
    func insert(_ string: String, at location: Int) {
      // 隣り合う選択の閉じ記号と開き記号は同じ位置に入るので、1 つの置き換えにまとめる。
      if let last = replacements.last, last.range.location == location {
        replacements[replacements.count - 1] = Replacement(last.range, last.text + string)
      } else {
        replacements.append(Replacement(NSRange(location: location, length: 0), string))
      }
    }
    // エンジンの選択は位置の順に並ぶ。
    let ranges = session.selections.map { nsRange(of: $0.range) }
    for range in ranges {
      insert(text, at: range.location)
      if range.length > 0 { insert(close, at: NSMaxRange(range)) }
    }
    let selecting = keepingCharacters(after: replacements)
    // 置き換えた後の本文での、囲んだ記号の範囲。
    let openLength = (text as NSString).length
    let surrounding = zip(ranges, selecting).filter { $0.0.length > 0 }.flatMap { _, selection in
      let start = min(selection.anchor, selection.head)
      let end = max(selection.anchor, selection.head)
      return [
        NSRange(location: start - openLength, length: openLength),
        NSRange(location: end, length: (close as NSString).length),
      ]
    }
    typing(untyped: surrounding) {
      try session.replace(
        replacements.map { TextEdit(textRange(of: $0.range), $0.text) }, selecting: selecting)
    }
    return true
  }
}
