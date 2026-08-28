import EdiroCore
import Testing

@testable import EdiroUI

private func labels(quarantined: String? = nil, error: String? = nil) -> NavBarLabels {
  NavBarLabels(
    metrics: TextMetrics(text: "本文\n2 行目"), quarantined: quarantined, storageError: error)
}

@Test func 文字数と行数は常に並ぶ() {
  let expected = ["Characters: 7", "Lines: 2"]
  #expect(labels().counters == expected)
  #expect(labels(quarantined: "draft.md.unreadable-x").counters == expected)
  #expect(labels(error: "保存できませんでした: 理由").counters == expected)
  #expect(
    labels(quarantined: "draft.md.unreadable-x", error: "保存できませんでした: 理由").counters
      == expected,
    "異常が重なると文字数が落ちている")
}

@Test func 異常が無ければ知らせは出ない() {
  #expect(labels().notices.isEmpty)
}

@Test func 退避先は名前が読める形で並ぶ() throws {
  let notice = try #require(labels(quarantined: "draft.md.unreadable-2026").notices.first)
  #expect(notice.text.contains("draft.md.unreadable-2026"))
  #expect(notice.detail.contains("draft.md.unreadable-2026"))
}

@Test func 退避先と保存失敗は両方並ぶ() {
  let notices = labels(quarantined: "draft.md.unreadable-x", error: "保存できませんでした: 理由")
    .notices
  #expect(notices.count == 2)
  #expect(notices.contains { $0.text.contains("draft.md.unreadable-x") })
  #expect(notices.contains { $0.text.contains("保存できませんでした") })
}

@Test func 切り詰めは残すべき側で決める() throws {
  // 退避先はファイル名の末尾の時刻でどれを指すかが決まる
  let quarantine = try #require(labels(quarantined: "draft.md.unreadable-2026").notices.first)
  #expect(quarantine.truncation == .middle)

  // 失敗の理由は先頭に出る。末尾は保存先の名前
  let failure = try #require(labels(error: "保存できませんでした: 理由").notices.first)
  #expect(failure.truncation == .tail)
}
