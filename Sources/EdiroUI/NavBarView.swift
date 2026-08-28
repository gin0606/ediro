import EdiroCore
import SwiftUI

struct NavBarView: View {
  @Bindable var state: AppState
  @State private var wavePhase: CGFloat = 0

  private var theme: Theme { state.theme }

  var body: some View {
    HStack(spacing: 12) {
      if let error = state.storageError {
        Text(error).lineLimit(1).help(error)
      } else {
        Text("Characters: \(state.metrics.characters)")
        Text("Lines: \(state.metrics.lines)")
      }

      Spacer()

      Toggle("Always on top", isOn: $state.isAlwaysOnTop)
        .toggleStyle(.checkbox)
    }
    .font(.system(size: 11))
    .foregroundStyle(theme.navBarText.color)
    .tint(theme.navBarText.color)
    .padding(.horizontal, 10)
    .frame(height: 26)
    .background(background)
  }

  @ViewBuilder private var background: some View {
    if theme.animatesNavBar {
      // CSS の background-position アニメーションに相当する往復。
      // 塗りを横に引き伸ばして位置をずらすことで色が流れて見える。
      GeometryReader { proxy in
        theme.navBar.view
          .frame(width: proxy.size.width * 3)
          .offset(x: -proxy.size.width * wavePhase)
          .onAppear {
            withAnimation(.easeInOut(duration: 10).repeatForever(autoreverses: true)) {
              wavePhase = 2
            }
          }
      }
      .clipped()
    } else {
      theme.navBar.view
    }
  }
}
