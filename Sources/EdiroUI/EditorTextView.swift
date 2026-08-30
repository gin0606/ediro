import AppKit
import SwiftUI

/// NSTextView (TextKit 2) を SwiftUI に載せる薄い層。
///
/// エディタ本体は外で組み立てて渡す。ここで作ると SwiftUI の内側にしか実体が
/// 無くなり、起動直後にキー入力を向ける先をウィンドウ側から指せない。
struct EditorTextView: NSViewRepresentable {
  let controller: EditorTextController

  func makeNSView(context: Context) -> NSScrollView {
    controller.scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    controller.syncFromState()
  }
}
