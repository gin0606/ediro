import EdiroCore
import SwiftUI

struct PreferencesView: View {
  @Bindable var state: AppState

  private var theme: Theme { state.theme }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Preferences").font(.system(size: 16, weight: .semibold))
        Spacer()
        Button {
          state.isShowingPreferences = false
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
      }

      LabeledContent("Theme") {
        Picker("", selection: $state.preferences.themeID) {
          ForEach(Theme.all) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
      }

      LabeledContent("Font Size") {
        Picker("", selection: $state.preferences.fontSize) {
          ForEach(fontSizes, id: \.self) { Text("\(Int($0))px").tag($0) }
        }
        .labelsHidden()
      }

      LabeledContent("Font Family") {
        FontFamilyPicker(selection: $state.preferences.fontName)
          .frame(maxWidth: .infinity)
      }

      LabeledContent("Tab Size") {
        Picker("", selection: $state.preferences.tabSize) {
          ForEach(Array(Preferences.tabSizeRange), id: \.self) { Text("\($0)").tag($0) }
        }
        .labelsHidden()
      }

      Text("Ediro \(Self.appVersion)")
        .font(.system(size: 11))
        .opacity(0.6)
    }
    .padding(20)
    .frame(width: 320)
    .background(theme.panelBackground.color)
    .foregroundStyle(theme.panelForeground.color)
    .clipShape(.rect(cornerRadius: 10))
    .shadow(radius: 20)
  }

  private var fontSizes: [Double] {
    stride(from: Preferences.fontSizeRange.lowerBound,
           through: Preferences.fontSizeRange.upperBound, by: 1).map { $0 }
  }

  static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }
}
