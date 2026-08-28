import AppKit

enum WindowMetrics {
  static let styleMask: NSWindow.StyleMask = [
    .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
  ]

  /// タイトルバーが占める高さ。fullSizeContentView ではコンテンツがこの下にも
  /// 回り込むため、同じ高さの帯を最上部に敷いて元の見た目を再現する。
  ///
  /// 高さを求めるときだけ fullSizeContentView を外す。含めたままだと
  /// コンテンツ矩形がフレーム全体に一致して差が 0 になる。
  static var titleBarHeight: Double {
    let content = NSRect(x: 0, y: 0, width: 100, height: 100)
    let mask = styleMask.subtracting(.fullSizeContentView)
    return NSWindow.frameRect(forContentRect: content, styleMask: mask).height - content.height
  }
}
