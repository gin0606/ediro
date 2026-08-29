import AppKit
import SwiftUI
import Testing

@testable import EdiroUI

/// ポップアップと、その選択先を束ねた組。
private struct Harness {
  final class Selection {
    var value: String
    init(_ value: String) { self.value = value }
  }

  let button = NSPopUpButton(frame: .zero, pullsDown: false)
  let coordinator = FontFamilyPicker.Coordinator()
  let selection: Selection

  init(selection name: String = "") {
    let box = Selection(name)
    selection = box
    coordinator.button = button
    coordinator.selection = Binding(get: { box.value }, set: { box.value = $0 })
    coordinator.display(name)
  }

  /// メニューが開かれた時に AppKit が辿る経路。
  func openMenu() {
    coordinator.menuNeedsUpdate(button.menu!)
  }
}

@Test func 一覧はメニューが開かれるまで組み立てられない() {
  let harness = Harness()
  #expect(harness.button.menu?.numberOfItems == 1)
  #expect(harness.button.titleOfSelectedItem == "（既定）")

  harness.openMenu()
  // 既定の 1 件と見出し 2 件を除いても、インストール済みの書体はこれより多い
  #expect(harness.button.menu!.numberOfItems > 3)
  #expect(harness.button.titleOfSelectedItem == "（既定）")
}

@Test func 選んだ書体が設定へ伝わる() throws {
  let harness = Harness()
  harness.openMenu()

  let entry = try #require(FontCatalog.installed.monospaced.first)
  let item = try #require(
    harness.button.menu?.items.first { $0.representedObject as? String == entry.postScriptName })
  harness.button.select(item)
  harness.coordinator.pick(harness.button)

  #expect(harness.selection.value == entry.postScriptName)
}

@Test func 手元に無い書体でも選択は失われない() {
  let harness = Harness(selection: "NoSuchFont-Regular")
  #expect(harness.button.titleOfSelectedItem == "NoSuchFont-Regular")

  harness.openMenu()
  #expect(harness.button.titleOfSelectedItem == "NoSuchFont-Regular")
}
