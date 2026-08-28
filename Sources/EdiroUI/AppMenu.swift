import AppKit

/// アプリケーションメニュー。Edit メニューが無いと NSTextView の
/// Cmd+C / Cmd+V / Cmd+Z が効かないため、標準項目も自前で並べる。
enum AppMenu {
  static func build(target: AppDelegate) -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Preferences…", action: #selector(AppDelegate.showPreferences(_:)),
      keyEquivalent: ",")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide Ediro", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Ediro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    main.addItem(editItem)

    let viewItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(
      withTitle: "Close", action: #selector(NSApplication.hide(_:)), keyEquivalent: "w")
    let fullScreen = viewMenu.addItem(
      withTitle: "Toggle Full Screen", action: #selector(AppDelegate.toggleFullScreen(_:)),
      keyEquivalent: "f")
    fullScreen.keyEquivalentModifierMask = [.control, .command]
    viewItem.submenu = viewMenu
    main.addItem(viewItem)

    let textItem = NSMenuItem()
    let textMenu = NSMenu(title: "Text")
    textMenu.addItem(
      withTitle: "Increase Font Size", action: #selector(AppDelegate.increaseFontSize(_:)),
      keyEquivalent: "+")
    textMenu.addItem(
      withTitle: "Decrease Font Size", action: #selector(AppDelegate.decreaseFontSize(_:)),
      keyEquivalent: "-")
    textItem.submenu = textMenu
    main.addItem(textItem)

    for menu in [appMenu, viewMenu, textMenu] {
      for item in menu.items where item.action != nil && item.target == nil {
        if item.action?.description.hasPrefix("hide") == false
          && item.action != #selector(NSApplication.terminate(_:))
        {
          item.target = target
        }
      }
    }
    return main
  }
}
