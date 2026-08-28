import Foundation

public enum Indentation {
  /// 指定位置が属する行の先頭にある空白を返す。
  /// 改行したときに同じ深さから書き始められるようにするために使う。
  ///
  /// 位置は UTF-16 オフセット。NSTextView の選択範囲をそのまま渡せる。
  public static func leadingWhitespace(in text: String, at location: Int) -> String {
    let ns = text as NSString
    let clamped = min(max(location, 0), ns.length)
    let line = ns.substring(with: ns.lineRange(for: NSRange(location: clamped, length: 0)))
    return String(line.prefix { $0 == " " || $0 == "\t" })
  }
}
