import EdiroCore
import Foundation
import Observation

@Observable
public final class AppState {
  public var preferences: Preferences {
    didSet {
      guard preferences != oldValue else { return }
      preferences.save(to: defaults)
    }
  }

  public var text: String {
    didSet {
      guard text != oldValue else { return }
      metrics = TextMetrics(text: text)
      scheduleSave()
    }
  }

  public private(set) var metrics: TextMetrics
  public var isAlwaysOnTop = false
  public var isShowingPreferences = false

  /// 保存や読み込みに失敗したときの理由。握り潰さずナビゲーションバーに出す。
  public private(set) var storageError: String?

  private let documentStore: DocumentStore
  private let defaults: UserDefaults
  private var saveTask: Task<Void, Never>?

  public init(documentStore: DocumentStore, defaults: UserDefaults = .standard) {
    self.documentStore = documentStore
    self.defaults = defaults
    self.preferences = Preferences.load(from: defaults)

    // 本文が読めなくても起動はさせる。空で立ち上げたうえで理由を画面に出し、
    // ユーザーが既存ファイルを退避できるようにする。
    let loaded: String
    let failure: String?
    do {
      loaded = try documentStore.load()
      failure = nil
    } catch {
      loaded = ""
      failure = "本文を読み込めませんでした: \(error.localizedDescription)"
    }
    self.text = loaded
    self.metrics = TextMetrics(text: loaded)
    self.storageError = failure
  }

  public var theme: Theme { preferences.theme }

  public func adjustFontSize(by delta: Double) {
    preferences.fontSize += delta
    preferences.clamp()
  }

  /// 打鍵のたびにディスクへ書かないよう少し待ってから保存する。
  private func scheduleSave() {
    saveTask?.cancel()
    let snapshot = text
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, let self else { return }
      self.write(snapshot)
    }
  }

  private func write(_ snapshot: String) {
    do {
      try documentStore.save(snapshot)
      storageError = nil
    } catch {
      storageError = "保存できませんでした: \(error.localizedDescription)"
    }
  }

  /// 終了時など、待たずに確実に書き出したい場面で使う。
  public func flush() {
    saveTask?.cancel()
    write(text)
  }
}
