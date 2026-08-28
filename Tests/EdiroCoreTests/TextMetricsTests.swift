import Testing

@testable import EdiroCore

@Test func 空文字は0文字1行として数える() {
  let metrics = TextMetrics(text: "")
  #expect(metrics.characters == 0)
  #expect(metrics.lines == 1)
}

@Test func 改行の数から行数を出す() {
  #expect(TextMetrics(text: "いち\nに\nさん").lines == 3)
  #expect(TextMetrics(text: "末尾が改行\n").lines == 2)
}

@Test func 絵文字を1文字として数える() {
  // 家族絵文字は複数のスカラーからなるが、見た目どおり 1 文字として扱う
  #expect(TextMetrics(text: "👨‍👩‍👧‍👦").characters == 1)
  #expect(TextMetrics(text: "あ🎉い").characters == 3)
}

@Test func CRLFの本文も行数を数える() {
  #expect(TextMetrics(text: "a\r\nb\r\nc").lines == 3)
  #expect(TextMetrics(text: "末尾がCRLF\r\n").lines == 2)
  #expect(TextMetrics(text: "旧MacのCR\rのみ").lines == 2)
}
