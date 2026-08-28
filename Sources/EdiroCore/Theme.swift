import Foundation

public struct Theme: Equatable, Sendable, Identifiable {
  public enum Appearance: Sendable { case light, dark }

  public let id: String
  public let name: String
  public let appearance: Appearance
  public let navBar: Fill
  public let navBarText: RGBA
  public let titleBar: Fill
  /// グラデーションを往復アニメーションさせるか（*-wave テーマ）。
  public let animatesNavBar: Bool

  public var editorBackground: RGBA {
    appearance == .dark ? RGBA(hex: 0x1E1E1E) : RGBA(hex: 0xFFFFFF)
  }

  public var editorForeground: RGBA {
    appearance == .dark ? RGBA(hex: 0xD4D4D4) : RGBA(hex: 0x333333)
  }

  public var panelBackground: RGBA {
    appearance == .dark ? RGBA(hex: 0x222222) : RGBA(hex: 0xFFFFFF)
  }

  public var panelForeground: RGBA {
    appearance == .dark ? RGBA(hex: 0xFFFFFF) : RGBA(hex: 0x333333)
  }
}

extension Theme {
  static let darkTitleBar = Fill.solid(RGBA(hex: 0x333333))
  static let lightTitleBar = Fill.linearGradient(
    colors: [RGBA(hex: 0xCCCCCC), RGBA(hex: 0xEBEBEB)], angle: 90)

  static let blueGradient = Fill.linearGradient(
    colors: [RGBA(hex: 0x5433FF), RGBA(hex: 0x00ABFF), RGBA(hex: 0x30D9EF)], angle: 0)
  static let editaroGradient = Fill.linearGradient(
    colors: [RGBA(hex: 0xEA27FF), RGBA(hex: 0x0069FF)], angle: 0)
  static let aestheticGradient = Fill.linearGradient(
    colors: [RGBA(hex: 0xEE7752), RGBA(hex: 0xE73C7E),
             RGBA(hex: 0x23A6D5), RGBA(hex: 0x23D5AB)], angle: 135)

  /// エディ太郎 (https://editaro.com) と同じ 9 テーマ。順序も Preferences の表示順に合わせる。
  public static let all: [Theme] = [
    Theme(id: "vscode", name: "VSCode", appearance: .dark,
          navBar: .solid(RGBA(hex: 0x0077D5)), navBarText: RGBA(hex: 0xFFFFFF),
          titleBar: darkTitleBar, animatesNavBar: false),
    Theme(id: "dark-grad", name: "Dark Gradient", appearance: .dark,
          navBar: blueGradient, navBarText: RGBA(hex: 0xFFFFFF),
          titleBar: darkTitleBar, animatesNavBar: false),
    Theme(id: "light-grad", name: "Light Gradient", appearance: .light,
          navBar: blueGradient, navBarText: RGBA(hex: 0x333333),
          titleBar: lightTitleBar, animatesNavBar: false),
    Theme(id: "dark", name: "Dark", appearance: .dark,
          navBar: .solid(RGBA(hex: 0x333333)), navBarText: RGBA(hex: 0xC1C1C1),
          titleBar: darkTitleBar, animatesNavBar: false),
    Theme(id: "light", name: "Light", appearance: .light,
          navBar: lightTitleBar, navBarText: RGBA(hex: 0x333333),
          titleBar: lightTitleBar, animatesNavBar: false),
    Theme(id: "editaro", name: "Editaro", appearance: .dark,
          navBar: editaroGradient, navBarText: RGBA(hex: 0xFFFFFF),
          titleBar: darkTitleBar, animatesNavBar: false),
    Theme(id: "editaro-wave", name: "Editaro Wave", appearance: .dark,
          navBar: editaroGradient, navBarText: RGBA(hex: 0xFFFFFF),
          titleBar: darkTitleBar, animatesNavBar: true),
    Theme(id: "aesthetic", name: "Aesthetic", appearance: .dark,
          navBar: aestheticGradient, navBarText: RGBA(hex: 0xFFFFFF),
          titleBar: darkTitleBar, animatesNavBar: false),
    Theme(id: "aesthetic-wave", name: "Aesthetic Wave", appearance: .dark,
          navBar: aestheticGradient, navBarText: RGBA(hex: 0xFFFFFF),
          titleBar: darkTitleBar, animatesNavBar: true)
  ]

  public static let fallback = all[1]  // dark-grad

  public static func theme(id: String) -> Theme {
    all.first { $0.id == id } ?? fallback
  }
}
