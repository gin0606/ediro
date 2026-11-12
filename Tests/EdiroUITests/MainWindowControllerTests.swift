import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

extension AppKitTests {
  struct MainWindowControllerTests {
    @Test func 起動時にエディタがキー入力を受け取る() {
      let controller = MainWindowController(state: makeState())
      controller.show()
      // ビュー階層を探して当てるのではなく、持っている実体をそのまま指す
      #expect(controller.window.firstResponder === controller.editor.editorView)
    }

    @Test func 最前面固定がウィンドウのレベルに反映される() async {
      let state = makeState()
      let controller = MainWindowController(state: state)
      #expect(controller.window.level == .normal)

      state.isAlwaysOnTop = true
      #expect(await waitUntil { controller.window.level == .floating })

      state.isAlwaysOnTop = false
      #expect(await waitUntil { controller.window.level == .normal })
    }

    @Test func 閉じる操作ではウィンドウを閉じない() {
      let controller = MainWindowController(state: makeState())
      // 下書きが常駐している前提なので、閉じる代わりにアプリを隠す
      #expect(controller.windowShouldClose(controller.window) == false)
    }

    @Test func 設定が開いているうちの閉じる操作は設定だけを閉じる() {
      let state = makeState()
      state.isShowingPreferences = true
      let controller = MainWindowController(state: state)
      controller.show()

      // Cmd+W はメニューから performClose(_:) に届く。閉じるボタンと同じ判断を通ること
      controller.window.performClose(nil)

      #expect(state.isShowingPreferences == false)
      #expect(controller.window.isVisible, "設定だけでなくウィンドウまで閉じている")
    }

    @Test func テーマの明暗がウィンドウの外観に反映される() async {
      let state = makeState()
      state.preferences.themeID = "dark"
      let controller = MainWindowController(state: state)
      #expect(controller.window.appearance?.name == .darkAqua)

      state.preferences.themeID = "light"
      #expect(await waitUntil { controller.window.appearance?.name == .aqua })
    }
  }
}
