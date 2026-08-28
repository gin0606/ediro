import AppKit
import Testing

@testable import EdiroUI

private func menuBar() -> NSMenu {
  AppMenu.build(target: AppDelegate()).bar
}

private func menu(_ title: String) -> NSMenu? {
  menuBar().items.compactMap(\.submenu).first { $0.title == title }
}

@Test func メニューバーに必要なメニューが並ぶ() {
  let titles = menuBar().items.compactMap { $0.submenu?.title }
  #expect(titles == ["Ediro", "Edit", "View", "Text", "Window"])
}

@Test func 編集メニューに取り消しと複製の標準項目がある() throws {
  // これらが無いと NSTextView の Cmd+C / Cmd+V / Cmd+Z が効かない
  let edit = try #require(menu("Edit"))
  let titles = edit.items.map(\.title)
  for expected in ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"] {
    #expect(titles.contains(expected))
  }
}

@Test func 応答連鎖に流す項目は宛先を固定しない() throws {
  let edit = try #require(menu("Edit"))
  for item in edit.items where item.action != nil {
    #expect(item.target == nil, "\(item.title) が特定の宛先に固定されている")
  }
}

@Test func アプリ固有の項目はデリゲートに届く() throws {
  let delegate = AppDelegate()
  let bar = AppMenu.build(target: delegate).bar
  let text = try #require(bar.items.compactMap(\.submenu).first { $0.title == "Text" })
  for item in text.items {
    #expect(item.target === delegate)
  }
}

@Test func ウィンドウメニューはメニューバーに載っているものと同じ実体を返す() {
  let built = AppMenu.build(target: AppDelegate())
  #expect(built.bar.items.compactMap(\.submenu).contains { $0 === built.window })
}

@Test func フォントサイズの拡大はイコールキーに割り当てる() throws {
  // "+" だと修飾前の文字と一致せず、⇧⌘= でも ⌘= でも発火しない
  let text = try #require(menu("Text"))
  let increase = try #require(text.items.first { $0.title == "Increase Font Size" })
  #expect(increase.keyEquivalent == "=")
}

@Test func 全画面切替はControlとCommandの組み合わせになる() throws {
  let view = try #require(menu("View"))
  let item = try #require(view.items.first { $0.title == "Toggle Full Screen" })
  #expect(item.keyEquivalentModifierMask == [.control, .command])
}

@Test func バージョン情報がアプリメニューの先頭にある() throws {
  let app = try #require(menu("Ediro"))
  #expect(app.items.first?.title == "About Ediro")
}

@Test func ウィンドウメニューに標準項目がある() throws {
  let window = try #require(menu("Window"))
  #expect(window.items.map(\.title).contains("Minimize"))
  #expect(window.items.map(\.title).contains("Zoom"))

  let minimize = try #require(window.items.first { $0.title == "Minimize" })
  #expect(minimize.keyEquivalent == "m")
  // ウィンドウ操作は第一応答者へ流す
  #expect(minimize.target == nil)
}
