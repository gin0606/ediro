import AppKit
import EdiroCore

enum ParagraphStyle {
  /// タブ幅を設定した段落スタイル。等幅の空白いくつ分かで指定する。
  static func make(for preferences: Preferences) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    let font = FontResolver(preferences: preferences).bodyFont
    let space = (" " as NSString).size(withAttributes: [.font: font]).width
    style.defaultTabInterval = space * Double(preferences.tabSize)
    style.tabStops = []
    return style
  }
}
