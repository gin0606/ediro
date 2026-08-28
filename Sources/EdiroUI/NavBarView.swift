import EdiroCore
import SwiftUI

struct NavBarView: View {
  @Bindable var state: AppState

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

      ForEach(labels.notices, id: \.text) { notice in
        Text(notice.text)
          .lineLimit(1)
          .truncationMode(notice.truncation == .middle ? .middle : .tail)
          .help(notice.detail)
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
      // テーマごとに別の identity を与える。位相を持つ状態が前のテーマから
      // 引き継がれると、終端の値のまま animation が何も動かさなくなる。
      WaveFill(fill: theme.navBar).id(theme.id)
    } else {
      theme.navBar.view
    }
  }
}

/// 塗りを横に引き伸ばして位置をずらし、色が流れて見えるようにする。
/// CSS の background-position アニメーションに相当する往復。
private struct WaveFill: View {
  let fill: Fill
  @State private var phase: CGFloat = 0

  var body: some View {
    GeometryReader { proxy in
      fill.view
        .frame(width: proxy.size.width * 3)
        .offset(x: -proxy.size.width * phase)
        .onAppear {
          withAnimation(.easeInOut(duration: 10).repeatForever(autoreverses: true)) {
            phase = 2
          }
        }
    }
    .clipped()
  }
}
