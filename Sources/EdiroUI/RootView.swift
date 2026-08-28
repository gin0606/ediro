import SwiftUI

struct RootView: View {
  @Bindable var state: AppState

  var body: some View {
    VStack(spacing: 0) {
      TitleBarView(theme: state.theme)
      EditorTextView(state: state)
      NavBarView(state: state)
    }
    .overlay(alignment: .center) {
      if state.isShowingPreferences {
        PreferencesView(state: state)
      }
    }
    // fullSizeContentView でもタイトルバー分の safe area が入るため、
    // 帯を実際のタイトルバー位置に置くには無視させる必要がある。
    .ignoresSafeArea(.container, edges: .top)
    .background(state.theme.editorBackground.color)
    .onExitCommand {
      state.isShowingPreferences = false
    }
  }
}
