import Foundation
import Testing

@testable import EdiroCore

private func indent(_ text: String, at location: Int) -> String {
  Indentation.leadingWhitespace(in: text, at: location)
}

@Test func 行頭の空白を引き継ぐ() {
  let text = "    ネストした行"
  #expect(indent(text, at: text.utf16.count) == "    ")
}

@Test func タブも引き継ぐ() {
  let text = "\t\t深い行"
  #expect(indent(text, at: text.utf16.count) == "\t\t")
}

@Test func 空白のない行では空文字になる() {
  #expect(indent("ふつうの行", at: 5) == "")
}

@Test func 複数行のうちカーソルのある行を見る() {
  let text = "先頭の行\n    ふたつめ\nみっつめ"
  let second = ("先頭の行\n    ふ" as NSString).length
  #expect(indent(text, at: second) == "    ")
  #expect(indent(text, at: 2) == "")
}

@Test func 行頭にカーソルがあっても行の空白を返す() {
  let text = "  インデント行"
  #expect(indent(text, at: 0) == "  ")
}

@Test func 範囲外の位置でも落ちない() {
  #expect(indent("", at: 0) == "")
  #expect(indent("abc", at: 999) == "")
  #expect(indent("  abc", at: -5) == "  ")
}
