import AppKit
import EdiroCore
import SwiftUI

/// 本体のウィンドウ。閉じるボタンは既定の経路で windowShouldClose(_:) に届くが、
/// performClose(_:) の既定は false を返されると警告音で応じる。
final class MainWindow: NSWindow {
  override func performClose(_ sender: Any?) {
    if delegate?.windowShouldClose?(self) ?? true { close() }
  }
}

/// ウィンドウの生成と、SwiftUI 側では表現できない挙動を受け持つ。
final class MainWindowController: NSObject, NSWindowDelegate {
  private let state: AppState
  let editor: EditorTextController
  let window: MainWindow

  init(state: AppState) {
    self.state = state
    self.editor = EditorTextController(state: state)
    window = MainWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: WindowMetrics.styleMask,
      backing: .buffered, defer: false)

    super.init()

    window.title = "Ediro"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = false
    window.contentView = NSHostingView(rootView: RootView(state: state, editor: editor))
    window.delegate = self
    window.setFrameAutosaveName("MainWindow")
    window.contentMinSize = NSSize(width: 320, height: 200)
    if window.frame.origin == .zero { window.center() }

    observeAlwaysOnTop()
    observeTheme()
  }

  func show() {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    focusEditor()
  }

  /// 起動直後からそのまま打ち始められるようにする。
  func focusEditor() {
    // NSHostingView はレイアウトを通すまで内側のビューを窓に載せない。
    window.contentView?.layoutSubtreeIfNeeded()
    window.makeFirstResponder(editor.textView)
  }

  /// 閉じるはアプリを隠すだけにする。下書きが常駐している前提の使い方に合わせる。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if state.isShowingPreferences {
      state.isShowingPreferences = false
      return false
    }
    NSApp.hide(nil)
    return false
  }

  func toggleFullScreen() { window.toggleFullScreen(nil) }

  private func applyAlwaysOnTop() {
    window.level = state.isAlwaysOnTop ? .floating : .normal
  }

  private func applyTheme() {
    window.backgroundColor = state.theme.editorBackground.nsColor
    window.appearance = NSAppearance(
      named: state.theme.appearance == .dark ? .darkAqua : .aqua)
  }

  // Observation は一度きりの通知なので、変更のたびに登録し直す。
  private func observeAlwaysOnTop() {
    applyAlwaysOnTop()
    withObservationTracking {
      _ = state.isAlwaysOnTop
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeAlwaysOnTop() }
    }
  }

  private func observeTheme() {
    applyTheme()
    withObservationTracking {
      _ = state.preferences.themeID
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeTheme() }
    }
  }
}
