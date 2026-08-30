import AppKit
import EdiroCore
import Testing

@testable import EdiroUI

@Test func ウィンドウには最小サイズが設定される() {
  let controller = MainWindowController(state: makeState())
  #expect(controller.window.contentMinSize.width > 0)
  #expect(controller.window.contentMinSize.height > 0)
}

@Test func 起動時にエディタがキー入力を受け取る() {
  let controller = MainWindowController(state: makeState())
  controller.show()
  // ビュー階層を探して当てるのではなく、持っている実体をそのまま指す
  #expect(controller.window.firstResponder === controller.editor.textView)
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

  #expect(controller.windowShouldClose(controller.window) == false)
  #expect(state.isShowingPreferences == false)
}

@Test func キーボードからの閉じる操作も同じ判断を通る() {
  let state = makeState()
  state.isShowingPreferences = true
  let controller = MainWindowController(state: state)

  controller.window.performClose(nil)

  #expect(state.isShowingPreferences == false)
}

@Test func テーマの明暗がウィンドウの外観に反映される() async {
  let state = makeState()
  state.preferences.themeID = "dark"
  let controller = MainWindowController(state: state)
  #expect(controller.window.appearance?.name == .darkAqua)

  state.preferences.themeID = "light"
  #expect(await waitUntil { controller.window.appearance?.name == .aqua })
}
