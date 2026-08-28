import AppKit
import SwiftUI

/// NSTextView (TextKit 2) を SwiftUI に載せる薄い層。
struct EditorTextView: NSViewRepresentable {
  @Bindable var state: AppState

  func makeCoordinator() -> EditorTextController { EditorTextController(state: state) }

  func makeNSView(context: Context) -> NSScrollView {
    context.coordinator.scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.syncFromState()
  }
}
