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
  #expect(controller.window.firstResponder as? NSTextView != nil)
}

@Test func 階層の奥にあるテキストビューを見つけられる() {
  let leaf = NSTextView(frame: .zero)
  let middle = NSView(frame: .zero)
  let root = NSView(frame: .zero)
  middle.addSubview(leaf)
  root.addSubview(NSView(frame: .zero))
  root.addSubview(middle)

  #expect(firstTextView(in: root) === leaf)
  #expect(firstTextView(in: NSView(frame: .zero)) == nil)
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

@Test func テーマの明暗がウィンドウの外観に反映される() async {
  let state = makeState()
  state.preferences.themeID = "dark"
  let controller = MainWindowController(state: state)
  #expect(controller.window.appearance?.name == .darkAqua)

  state.preferences.themeID = "light"
  #expect(await waitUntil { controller.window.appearance?.name == .aqua })
}
