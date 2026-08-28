import SwiftUI

struct RootView: View {
  @Bindable var state: AppState

  var body: some View {
    VStack(spacing: 0) {
      EditorTextView(state: state)
      NavBarView(state: state)
    }
    .overlay(alignment: .center) {
      if state.isShowingPreferences {
        PreferencesView(state: state)
      }
    }
    .background(state.theme.editorBackground.color)
    .onExitCommand {
      state.isShowingPreferences = false
    }
  }
}
