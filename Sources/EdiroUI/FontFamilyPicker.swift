import AppKit
import SwiftUI

/// Preferences の書体選択。
///
/// SwiftUI の Picker は選択肢をビューの評価と同時に組み立てるため、インストール
/// 済みの全ファミリを並べると Preferences を開くだけで数百 ms かかる。NSMenu なら
/// 組み立てをメニューが開かれる時点まで遅らせられるので、開く操作の外に出す。
struct FontFamilyPicker: NSViewRepresentable {
  @Binding var selection: String

  private static let fallbackWidth = 200.0

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.target = context.coordinator
    button.action = #selector(Coordinator.pick(_:))
    context.coordinator.button = button
    return button
  }

  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.selection = $selection
    context.coordinator.display(selection)
  }

  /// メニューの中身に幅を決めさせない。一覧を組み立てた前後で寸法が変わると、
  /// メニューを初めて開いた時にレイアウトが動く。
  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context
  ) -> CGSize? {
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? Self.fallbackWidth
    return CGSize(width: width, height: button.intrinsicContentSize.height)
  }

  final class Coordinator: NSObject, NSMenuDelegate {
    var selection: Binding<String> = .constant("")
    weak var button: NSPopUpButton?

    /// 選択中の 1 件だけを持つ状態と、一覧を組み立てた状態を区別する。
    private var isPopulated = false

    /// 選択を表示に反映する。一覧がまだ無ければ、その 1 件だけのメニューを立てる。
    func display(_ postScriptName: String) {
      guard let button else { return }
      guard isPopulated else {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(Self.item(named: postScriptName))
        button.menu = menu
        button.selectItem(at: 0)
        return
      }
      button.select(button.menu?.items.first { $0.representedObject as? String == postScriptName })
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
      guard !isPopulated else { return }
      let catalog = FontCatalog.installed
      menu.removeAllItems()
      menu.addItem(Self.item(named: ""))
      menu.addItem(.sectionHeader(title: "等幅"))
      for entry in catalog.monospaced { menu.addItem(Self.item(entry)) }
      menu.addItem(.sectionHeader(title: "標準"))
      for entry in catalog.proportional { menu.addItem(Self.item(entry)) }

      // 保存されている書体が今のマシンに無い場合、一覧には現れない。選択を
      // 失わせないために、その 1 件だけ先頭に足す。
      let current = selection.wrappedValue
      if !menu.items.contains(where: { $0.representedObject as? String == current }) {
        menu.insertItem(Self.item(named: current), at: 0)
      }

      isPopulated = true
      // 項目を入れ替えると選択は先頭に落ちるので、貼り直す。
      display(current)
    }

    @objc func pick(_ sender: NSPopUpButton) {
      selection.wrappedValue = sender.selectedItem?.representedObject as? String ?? ""
    }

    private static func item(_ entry: FontCatalog.Entry) -> NSMenuItem {
      let item = NSMenuItem(title: entry.displayName, action: nil, keyEquivalent: "")
      item.representedObject = entry.postScriptName
      return item
    }

    /// 一覧を持たない状態でも選択中の書体を名前で示せるよう、PostScript 名から
    /// ファミリ名を引く。
    private static func item(named postScriptName: String) -> NSMenuItem {
      guard !postScriptName.isEmpty else {
        let item = NSMenuItem(title: "（既定）", action: nil, keyEquivalent: "")
        item.representedObject = ""
        return item
      }
      let family = NSFont(name: postScriptName, size: 12)?.familyName ?? postScriptName
      let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
      item.representedObject = postScriptName
      return item
    }
  }
}
