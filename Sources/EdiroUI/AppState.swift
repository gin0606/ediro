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

  /// 退避した読み込み失敗ファイルの名前。保存の成否とは別に保持し続ける。
  public private(set) var quarantined: String?

  private let documentStore: DocumentStore
  private let defaults: UserDefaults
  /// 打鍵が止まってから書き出すまでの待ち。テストは待たずに済ませるため差し替える。
  private let saveDelay: Duration
  private var saveTask: Task<Void, Never>?
  /// 読み込みに失敗したまま最初の保存を迎えたか。読めなかったファイルを
  /// 空の本文で潰さないよう、保存の前に退避させる。
  private var needsQuarantine = false
  /// 本文が一度でも変わったか。変えずに終了した回に書き戻さないために見る。
  private var isDirty = false

  public init(
    documentStore: DocumentStore, defaults: UserDefaults = .standard,
    saveDelay: Duration = .milliseconds(400)
  ) {
    self.documentStore = documentStore
    self.defaults = defaults
    self.saveDelay = saveDelay
    self.preferences = Preferences.load(from: defaults)

    // 本文が読めなくても起動はさせる。空で立ち上げたうえで理由を画面に出す。
    let loaded: String
    let failure: String?
    do {
      loaded = try documentStore.load()
      failure = nil
    } catch {
      loaded = ""
      // 退避は本文を書いたときにしか走らない。書かずに終える人が自分で退けられる
      // よう、場所を文面に持たせる。
      failure = "本文を読み込めませんでした (\(documentStore.fileURL.path(percentEncoded: false))): "
        + error.localizedDescription
      needsQuarantine = true
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
    isDirty = true
    let snapshot = text
    let delay = saveDelay
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      self.write(snapshot)
    }
  }

  private func write(_ snapshot: String) {
    if needsQuarantine {
      do {
        quarantined = try documentStore.quarantine()?.lastPathComponent
        needsQuarantine = false
      } catch {
        storageError = "読めなかった本文を退避できないため保存を見送りました: "
          + error.localizedDescription
        return
      }
    }

    do {
      try documentStore.save(snapshot)
      isDirty = false
      storageError = nil
    } catch {
      storageError = "保存できませんでした: \(error.localizedDescription)"
    }
  }

  /// 終了時など、待たずに確実に書き出したい場面で使う。
  public func flush() {
    saveTask?.cancel()
    guard isDirty else { return }
    write(text)
  }
}
