import EdiroCore
import SwiftUI

/// タイトルバーの領域に敷く帯。ウィンドウのタイトルバーは透過させてあるため、
/// テーマごとの色はこのビューが受け持つ。
struct TitleBarView: View {
  let theme: Theme

  var body: some View {
    theme.titleBar.view
      .frame(height: WindowMetrics.titleBarHeight)
  }
}
