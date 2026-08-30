import AppKit
import EdiroCore

public final class AppDelegate: NSObject, NSApplicationDelegate {
  private var state: AppState?
  private var windowController: MainWindowController?

  public func applicationDidFinishLaunching(_ notification: Notification) {
    let store: DocumentStore
    do {
      store = try DocumentStore.applicationSupport()
    } catch {
      // 保存先そのものが用意できないのは想定外なので、黙って続けず落とす。
      fatalError("保存先を作成できませんでした: \(error)")
    }

    let state = AppState(documentStore: store)
    let controller = MainWindowController(state: state)
    self.state = state
    self.windowController = controller

    let menu = AppMenu.build(target: self)
    NSApp.mainMenu = menu.bar
    // ウィンドウ一覧の管理を macOS に任せる
    NSApp.windowsMenu = menu.window
    controller.show()
  }

  public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  public func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    windowController?.show()
    return true
  }

  public func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    guard let state else { return .terminateNow }
    if state.flush() { return .terminateNow }

    let alert = NSAlert()
    alert.messageText = "下書きを保存できませんでした"
    alert.informativeText =
      (state.storageError ?? "理由が分かりません。")
      + "\n\nこのまま終了すると、書いた内容は失われます。"
    alert.addButton(withTitle: "終了しない")
    alert.addButton(withTitle: "終了する")
    return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
  }

  @objc func showAbout(_ sender: Any?) {
    NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.credits])
  }

  /// 標準のバージョン情報に添える一文。
  private static let credits = NSAttributedString(
    string: "ありがとう、エディ太郎。",
    attributes: [
      .font: NSFont.systemFont(ofSize: 11),
      .foregroundColor: NSColor.secondaryLabelColor,
    ])

  @objc func showPreferences(_ sender: Any?) {
    state?.isShowingPreferences = true
  }

  @objc func toggleFullScreen(_ sender: Any?) {
    windowController?.toggleFullScreen()
  }

  @objc func increaseFontSize(_ sender: Any?) {
    state?.adjustFontSize(by: 1)
  }

  @objc func decreaseFontSize(_ sender: Any?) {
    state?.adjustFontSize(by: -1)
  }
}

public enum EdiroApp {
  /// アプリケーションを起動する。executable ターゲットから呼ぶ唯一の入口。
  public static func run() -> Never {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    fatalError("NSApplication.run() から戻ることはない")
  }
}
