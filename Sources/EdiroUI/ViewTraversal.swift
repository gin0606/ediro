import AppKit

/// ビュー階層から最初の NSTextView を探す。
///
/// エディタは NSHostingView の内側に構築されるため、ウィンドウ側からは
/// 参照を持てない。初期フォーカスを与えるために階層を辿る。
func firstTextView(in view: NSView) -> NSTextView? {
  if let textView = view as? NSTextView { return textView }
  for subview in view.subviews {
    if let found = firstTextView(in: subview) { return found }
  }
  return nil
}
