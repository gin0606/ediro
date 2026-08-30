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
