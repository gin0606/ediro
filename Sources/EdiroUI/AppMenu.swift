import AppKit

/// アプリケーションメニュー。Edit メニューが無いと NSTextView の
/// Cmd+C / Cmd+V / Cmd+Z が効かないため、標準項目も自前で並べる。
enum AppMenu {
  static func build(target: AppDelegate) -> NSMenu {
    let main = NSMenu()
    main.addItem(submenu(appMenu(target: target)))
    main.addItem(submenu(editMenu()))
    main.addItem(submenu(viewMenu(target: target)))
    main.addItem(submenu(textMenu(target: target)))
    return main
  }

  private static func appMenu(target: AppDelegate) -> NSMenu {
    let menu = NSMenu(title: "Ediro")
    menu.addItem(
      item("Preferences…", #selector(AppDelegate.showPreferences(_:)), key: ",", target: target))
    menu.addItem(.separator())
    menu.addItem(item("Hide Ediro", #selector(NSApplication.hide(_:)), key: "h"))
    menu.addItem(.separator())
    menu.addItem(item("Quit Ediro", #selector(NSApplication.terminate(_:)), key: "q"))
    return menu
  }

  private static func editMenu() -> NSMenu {
    let menu = NSMenu(title: "Edit")
    // 取り消し系は NSTextView が応答するので、セレクタ名で応答連鎖に流す。
    menu.addItem(item("Undo", Selector(("undo:")), key: "z"))
    menu.addItem(item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
    menu.addItem(.separator())
    menu.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
    menu.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
    menu.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
    menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
    return menu
  }

  private static func viewMenu(target: AppDelegate) -> NSMenu {
    let menu = NSMenu(title: "View")
    menu.addItem(item("Close", #selector(NSApplication.hide(_:)), key: "w"))
    menu.addItem(
      item(
        "Toggle Full Screen", #selector(AppDelegate.toggleFullScreen(_:)), key: "f",
        modifiers: [.control, .command], target: target))
    return menu
  }

  private static func textMenu(target: AppDelegate) -> NSMenu {
    let menu = NSMenu(title: "Text")
    menu.addItem(
      item(
        "Increase Font Size", #selector(AppDelegate.increaseFontSize(_:)), key: "+", target: target))
    menu.addItem(
      item(
        "Decrease Font Size", #selector(AppDelegate.decreaseFontSize(_:)), key: "-", target: target))
    return menu
  }

  /// target を省いた項目は応答連鎖に流れ、NSApp や第一応答者が受け取る。
  private static func item(
    _ title: String, _ action: Selector, key: String = "",
    modifiers: NSEvent.ModifierFlags? = nil, target: AnyObject? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    if let modifiers { item.keyEquivalentModifierMask = modifiers }
    item.target = target
    return item
  }

  private static func submenu(_ menu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem()
    item.submenu = menu
    return item
  }
}
