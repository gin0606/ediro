import EdiroCore

/// ナビゲーションバーに並べる文言。何を出すかの判断をビューから外に出す。
struct NavBarLabels: Equatable {
  struct Notice: Equatable {
    let text: String
    /// tooltip に出す全文。
    let detail: String
  }

  /// 文字数と行数。保存の異常が出ていても落とさない。下書きの分量は
  /// 異常の有無と関係なく読めている必要がある。
  let counters: [String]
  /// 退避先や保存失敗の知らせ。長くなりうるので、切り詰められる側に置く。
  let notices: [Notice]

  init(metrics: TextMetrics, quarantined: String?, storageError: String?) {
    counters = ["Characters: \(metrics.characters)", "Lines: \(metrics.lines)"]

    var notices: [Notice] = []
    if let quarantined {
      notices.append(
        Notice(
          text: "退避: \(quarantined)",
          detail: "読めなかった本文を \(quarantined) に退避しました"))
    }
    if let storageError {
      notices.append(Notice(text: storageError, detail: storageError))
    }
    self.notices = notices
  }
}
