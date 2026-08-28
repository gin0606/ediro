import EdiroCore
import SwiftUI

struct NavBarView: View {
  @Bindable var state: AppState
  @State private var wavePhase: CGFloat = 0

  private var theme: Theme { state.theme }

  private var labels: NavBarLabels {
    NavBarLabels(
      metrics: state.metrics, quarantined: state.quarantined, storageError: state.storageError)
  }

  var body: some View {
    HStack(spacing: 12) {
      // 文字数は異常の文面に押し出されないよう優先度を上げる
      ForEach(labels.counters, id: \.self) { counter in
        Text(counter).lineLimit(1).layoutPriority(1)
      }

      // 退避先は名前そのものが用件なので、切り詰めるなら中ほどを落とす
      ForEach(labels.notices, id: \.text) { notice in
        Text(notice.text).lineLimit(1).truncationMode(.middle).help(notice.detail)
      }

      Spacer()

      Toggle("Always on top", isOn: $state.isAlwaysOnTop)
        .toggleStyle(.checkbox)
        .fixedSize()
        .layoutPriority(1)
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
