import AppKit
import SwiftUI
import Translation

/// 翻訳のポップオーバーに渡す内容。`isPresented` を true にすると出る。
@Observable
final class TranslationRequest {
  var isPresented = false
  var text = ""
  /// 訳文で置き換えるときに呼ばれる。
  var replace: ((String) -> Void)?
}

/// システムの翻訳のポップオーバーを出す透明なビュー。AppKit から翻訳を出す公開 API は
/// SwiftUI の `translationPresentation` だけなので、このビューを本文の上に重ねて出す。
/// クリックは下の本文に通す。
final class TranslationAnchorView: NSHostingView<TranslationAnchor> {
  init(request: TranslationRequest) {
    super.init(rootView: TranslationAnchor(request: request))
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  @available(*, unavailable)
  required init(rootView: TranslationAnchor) { fatalError("init(rootView:) is not supported") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct TranslationAnchor: View {
  @Bindable var request: TranslationRequest

  var body: some View {
    Color.clear
      .translationPresentation(isPresented: $request.isPresented, text: request.text) {
        request.replace?($0)
      }
  }
}
