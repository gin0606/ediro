import Foundation
import Testing

@testable import EdiroCore

private func indent(_ text: String, at location: Int) -> String {
  Indentation.leadingWhitespace(in: text, at: location)
}

@Test func タブも引き継ぐ() {
  let text = "\t\t深い行"
  #expect(indent(text, at: text.utf16.count) == "\t\t")
}

@Test func 範囲外の位置でも落ちない() {
  #expect(indent("", at: 0) == "")
  #expect(indent("abc", at: 999) == "")
  #expect(indent("  abc", at: -5) == "")
}
