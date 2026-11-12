import AppKit
import Testing

@testable import EdiroUI

extension AppKitTests {
  struct AppMenuTests {
    private func menuBar() -> NSMenu {
      AppMenu.build(target: AppDelegate()).bar
    }

    private func menu(_ title: String) -> NSMenu? {
      menuBar().items.compactMap(\.submenu).first { $0.title == title }
    }

    @Test func メニューバーに必要なメニューが並ぶ() {
      let titles = menuBar().items.compactMap { $0.submenu?.title }
      #expect(titles == ["Ediro", "Edit", "Selection", "View", "Text", "Window"])
    }

    @Test func 編集メニューの標準項目は応答連鎖からエディタに届く() throws {
      // これらが無いか宛先が固定されていると、EditorView に Cmd+C / Cmd+V / Cmd+Z が届かない
      let edit = try #require(menu("Edit"))
      let titles = edit.items.map(\.title)
      for expected in ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"] {
        #expect(titles.contains(expected), "\(expected) が無い")
      }
      let editor = EditorView(text: "")
      for item in edit.items {
        guard let action = item.action else { continue }
        #expect(item.target == nil, "\(item.title) が特定の宛先に固定されている")
        #expect(editor.responds(to: action), "\(item.title) の \(action) にエディタが応答しない")
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

    @Test func ウィンドウ操作はウィンドウメニューから応答連鎖に流す() throws {
      // 宛先を固定すると、バージョン情報のような別ウィンドウが前面にいても本体の窓に届いてしまう
      let window = try #require(menu("Window"))
      // Minimize のキー (⌘M) は AppKit が付け直すので、Ediro の設定としては確かめない。
      let expected: [(title: String, key: String?, action: Selector)] = [
        ("Close", "w", #selector(NSWindow.performClose(_:))),
        ("Minimize", nil, #selector(NSWindow.performMiniaturize(_:))),
        ("Zoom", "", #selector(NSWindow.performZoom(_:)))
      ]
      for (title, key, action) in expected {
        let item = try #require(window.items.first { $0.title == title }, "\(title) が無い")
        if let key { #expect(item.keyEquivalent == key, "\(title)") }
        #expect(item.target == nil, "\(title)")
        #expect(item.action == action, "\(title)")
      }
    }

    @Test func メニューバー全体でキーと修飾の組が重複しない() {
      // 同じ組を持つ項目が二つあると、打鍵は先に見つかった片方にしか届かない
      var owners: [String: [String]] = [:]
      func collect(_ menu: NSMenu) {
        for item in menu.items {
          if let submenu = item.submenu { collect(submenu) }
          guard !item.keyEquivalent.isEmpty else { continue }
          // 大文字のキーは Shift を含む組として扱われる
          let key = item.keyEquivalent.lowercased()
          var modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
          if key != item.keyEquivalent { modifiers.insert(.shift) }
          owners["\(modifiers.rawValue) \(key)", default: []].append(item.title)
        }
      }
      collect(menuBar())
      #expect(!owners.isEmpty)
      for (combination, titles) in owners {
        #expect(titles.count == 1, "\(titles) が同じ組 \(combination) を持つ")
      }
    }
  }
}
