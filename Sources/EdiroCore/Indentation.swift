import Foundation

public enum Indentation {
  /// 行頭の空白 (スペースとタブ文字)。`line` は行頭からの文字。
  public static func leadingWhitespace(of line: some StringProtocol) -> String {
    String(line.prefix { $0 == " " || $0 == "\t" })
  }

  /// スペースとタブ文字だけの文字列か。空なら true。
  public static func isBlank(_ text: some StringProtocol) -> Bool {
    text.utf16.allSatisfy { $0 == space || $0 == tab }
  }
}

/// 字下げの 1 段。設定の Tab Size と Insert Spaces から決まる。
public struct IndentUnit: Equatable, Sendable {
  public var tabSize: Int
  public var insertSpaces: Bool

  public init(tabSize: Int, insertSpaces: Bool) {
    self.tabSize = tabSize
    self.insertSpaces = insertSpaces
  }

  /// 字下げで足す文字。スペースなら Tab Size 個、そうでなければタブ文字 1 つ。
  public var text: String { insertSpaces ? String(repeating: " ", count: tabSize) : "\t" }

  /// 行頭から 1 段字上げするときに消す、行頭からの長さ (UTF-16)。行頭がタブ文字ならそれ 1 つ、
  /// スペースなら続くスペースを最大 Tab Size 個。字下げがなければ 0。
  ///
  /// 設定にかかわらずタブ文字もスペースも消す。設定を切り替える前に書いた行も戻せるように
  /// するため。`line` は行頭からの文字。
  public func outdentLength(of line: some StringProtocol) -> Int {
    let units = line.utf16
    guard let first = units.first else { return 0 }
    if first == tab { return 1 }
    return units.prefix(tabSize).prefix { $0 == space }.count
  }

  /// Backspace でキャレットの前の 1 段ぶんとして消す長さ (UTF-16)。`prefix` は行頭から
  /// キャレットまでの文字で、空か空白以外の文字を含めば 0。
  ///
  /// 直前がタブ文字ならそれ 1 つ。スペースなら直前に続くスペースを最大 Tab Size 個で、`prefix` が
  /// スペースだけなら Tab Size の倍数の桁まで (Tab Size 4 で 6 桁なら 2 個、8 桁なら 4 個)。
  /// タブ文字が混じると桁がタブ文字の表示幅に左右されるので、倍数にはそろえない。
  public func backspaceLength(before prefix: some StringProtocol) -> Int {
    let units = Array(prefix.utf16)
    guard let last = units.last, Indentation.isBlank(prefix) else { return 0 }
    if last == tab { return 1 }
    // Tab Size が 0 の単位を直接作っても、0 で割らないようにする。
    let size = max(tabSize, 1)
    let spaces = units.reversed().prefix { $0 == space }.count
    if spaces == units.count {
      let remainder = spaces % size
      return remainder == 0 ? size : remainder
    }
    return min(spaces, size)
  }

  /// 行頭の字下げの幅 (桁)。スペースは 1 桁、タブ文字は Tab Size 桁と数え、空白以外の文字で
  /// 止まる。桁を Tab Size の倍数にそろえないのは、字下げの段の数え方 (`outdentLength(of:)`)
  /// と同じく、タブ文字 1 つを 1 段と見るため。`line` は行頭からの文字。
  public func width(of line: some StringProtocol) -> Int {
    var width = 0
    for unit in line.utf16 {
      if unit == space {
        width += 1
      } else if unit == tab {
        width += tabSize
      } else {
        break
      }
    }
    return width
  }
}

extension Preferences {
  public var indentUnit: IndentUnit { IndentUnit(tabSize: tabSize, insertSpaces: insertSpaces) }
}

/// Markdown のリストの項目の行。
///
/// 行頭の空白の後に `-` `*` `+` または「ASCII 数字 + `.`」のマーカーがあり、その後に空白が続く行。
/// その後に `[ ]` または `[x]` と空白が続けば、チェックボックス付きの項目とする。`1)` 形式は
/// 対象外。空白はスペースとタブ文字を指す。
///
/// 行の文字だけから判定する。コードブロックの中の行はリスト行として扱わないが、それを
/// 判定するのは呼び出し側 (エディタはエンジンの行トークンで見る)。
///
/// 位置はどれも行頭からの UTF-16 オフセット。
public struct ListLine: Equatable, Sendable {
  public enum Marker: Equatable, Sendable {
    /// `-` `*` `+` のいずれか。
    case bullet(Character)
    /// 番号付き。値は `.` の前の数字の並び。
    case ordered(String)

    /// 行に書く文字。番号付きなら `.` まで含む。
    public var text: String {
      switch self {
      case .bullet(let character): String(character)
      case .ordered(let number): number + "."
      }
    }

    /// 次の項目のマーカー。記号はそのまま、番号付きは番号を 1 つ進める (`9` の次は `10`、
    /// `09` の次は `10`)。桁の多い番号でもあふれないよう、数字の並びのまま繰り上げる。番号が
    /// ASCII 数字の並びでなければそのまま。
    public var next: Marker {
      guard case .ordered(let number) = self, !number.isEmpty,
        number.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
      else { return self }
      var digits = Array(number.utf8)
      var index = digits.count - 1
      while index >= 0, digits[index] == UInt8(ascii: "9") {
        digits[index] = UInt8(ascii: "0")
        index -= 1
      }
      if index >= 0 {
        digits[index] += 1
      } else {
        digits.insert(UInt8(ascii: "1"), at: 0)
      }
      return .ordered(String(decoding: digits, as: UTF8.self))
    }
  }

  public struct Checkbox: Equatable, Sendable {
    /// `[ ]` か `[x]` の範囲。
    public let range: Range<Int>
    public let isChecked: Bool

    public init(range: Range<Int>, isChecked: Bool) {
      self.range = range
      self.isChecked = isChecked
    }
  }

  public let marker: Marker
  /// マーカーの範囲。番号付きなら `.` まで含む。
  public let markerRange: Range<Int>
  /// チェックボックス付きの項目なら、そのチェックボックス。
  public let checkbox: Checkbox?
  /// 本文の開始位置。マーカーと続く空白 (チェックボックス付きならチェックボックスと続く空白まで)
  /// の直後。
  public let contentStart: Int

  /// 本文の開始位置より後ろに、空白以外の文字がない項目 (空の項目)。
  public let isEmpty: Bool

  /// 行頭の字下げの範囲。字下げがなければ空。
  public var indentation: Range<Int> { 0..<markerRange.lowerBound }

  /// `line` (区切りの文字を含まない、行の文字) がリスト行でなければ nil。行の区切りの文字は
  /// 空白ではないので、含めて渡すと空の項目を見分けられない。
  public init?(_ line: some StringProtocol) {
    let units = Array(line.utf16)
    func whitespaceEnd(from start: Int) -> Int {
      var index = start
      while index < units.count, units[index] == space || units[index] == tab { index += 1 }
      return index
    }

    let markerStart = whitespaceEnd(from: 0)
    guard markerStart < units.count else { return nil }
    var markerEnd = markerStart
    let marker: Marker
    switch units[markerStart] {
    case hyphen, asterisk, plus:
      markerEnd += 1
      marker = .bullet(Character(Unicode.Scalar(units[markerStart])!))
    case digitZero...digitNine:
      while markerEnd < units.count, (digitZero...digitNine).contains(units[markerEnd]) {
        markerEnd += 1
      }
      guard markerEnd < units.count, units[markerEnd] == period else { return nil }
      marker = .ordered(String(decoding: units[markerStart..<markerEnd], as: UTF16.self))
      markerEnd += 1
    default:
      return nil
    }
    var contentStart = whitespaceEnd(from: markerEnd)
    guard contentStart > markerEnd else { return nil }

    var checkbox: Checkbox?
    if contentStart + 3 <= units.count, units[contentStart] == openBracket,
      units[contentStart + 1] == space || units[contentStart + 1] == lowercaseX,
      units[contentStart + 2] == closeBracket
    {
      let afterCheckbox = whitespaceEnd(from: contentStart + 3)
      if afterCheckbox > contentStart + 3 {
        checkbox = Checkbox(
          range: contentStart..<(contentStart + 3), isChecked: units[contentStart + 1] == lowercaseX)
        contentStart = afterCheckbox
      }
    }

    self.marker = marker
    markerRange = markerStart..<markerEnd
    self.checkbox = checkbox
    self.contentStart = contentStart
    // 本文の開始位置は後ろに続く空白も含むので、行の末尾に達していれば空の項目。
    isEmpty = contentStart == units.count
  }
}

private let space = UInt16(UInt8(ascii: " "))
private let tab = UInt16(UInt8(ascii: "\t"))
private let hyphen = UInt16(UInt8(ascii: "-"))
private let asterisk = UInt16(UInt8(ascii: "*"))
private let plus = UInt16(UInt8(ascii: "+"))
private let period = UInt16(UInt8(ascii: "."))
private let digitZero = UInt16(UInt8(ascii: "0"))
private let digitNine = UInt16(UInt8(ascii: "9"))
private let openBracket = UInt16(UInt8(ascii: "["))
private let closeBracket = UInt16(UInt8(ascii: "]"))
private let lowercaseX = UInt16(UInt8(ascii: "x"))
