import Foundation

public enum Indentation {
  /// 指定位置より前にある、その行の先頭の空白を返す。
  /// 改行したときに同じ深さから書き始められるようにするために使う。
  ///
  /// 見るのは行頭から指定位置までに限る。行全体を見ると、カーソルより後ろにある
  /// 空白まで引き継いでしまい、インデントの内側で改行したときに深さが増える。
  ///
  /// 位置は UTF-16 オフセット。NSTextView の選択範囲をそのまま渡せる。
  public static func leadingWhitespace(in text: String, at location: Int) -> String {
    let ns = text as NSString
    let clamped = min(max(location, 0), ns.length)
    let lineStart = ns.lineRange(for: NSRange(location: clamped, length: 0)).location
    let beforeCursor = ns.substring(
      with: NSRange(location: lineStart, length: clamped - lineStart))
    return String(beforeCursor.prefix { $0 == " " || $0 == "\t" })
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
