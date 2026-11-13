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

// MARK: - 1 段の字下げ・字上げ

@Test func 字下げの1段はスペースならTabSize個でそうでなければタブ文字() {
  #expect(IndentUnit(tabSize: 4, insertSpaces: true).text == "    ")
  #expect(IndentUnit(tabSize: 2, insertSpaces: true).text == "  ")
  #expect(IndentUnit(tabSize: 4, insertSpaces: false).text == "\t")
  #expect(Preferences.default.indentUnit == IndentUnit(tabSize: 4, insertSpaces: true))
}

@Test(arguments: [
  ("\tab", 1), ("\t\tab", 1), ("\t  ab", 1), ("    ab", 4), ("      ab", 4), ("  ab", 2),
  ("  \tab", 2), (" \t ab", 1), ("ab", 0), ("", 0), ("    ", 4),
])
func 字上げは行頭のタブ文字1つかスペースを最大TabSize個消す(line: String, length: Int) {
  for insertSpaces in [true, false] {
    #expect(IndentUnit(tabSize: 4, insertSpaces: insertSpaces).outdentLength(of: line) == length)
  }
}

@Test func 字上げで消すスペースの数はTabSizeで決まる() {
  #expect(IndentUnit(tabSize: 2, insertSpaces: true).outdentLength(of: "     ab") == 2)
  #expect(IndentUnit(tabSize: 8, insertSpaces: true).outdentLength(of: "     ab") == 5)
}

// MARK: - リスト行

@Test(arguments: [
  ("- a", ListLine.Marker.bullet("-")), ("* a", .bullet("*")), ("+ a", .bullet("+")),
  ("1. a", .ordered("1")), ("10. a", .ordered("10")), ("007. a", .ordered("007")),
])
func マーカーの種類を読む(line: String, marker: ListLine.Marker) throws {
  let item = try #require(ListLine(line))
  #expect(item.marker == marker)
  #expect(item.indentation == 0..<0)
  #expect(item.markerRange == 0..<((line as NSString).length - 2))
  #expect(item.contentStart == (line as NSString).length - 1)
  #expect(item.checkbox == nil)
  #expect(!item.isEmpty)
}

@Test func 字下げとマーカーの後の空白を読む() throws {
  let item = try #require(ListLine(" \t-  \tb"))
  #expect(item.indentation == 0..<2)
  #expect(item.markerRange == 2..<3)
  #expect(item.contentStart == 6)
}

@Test(arguments: [
  "", "   ", "a", "-", "-a", "1.", "1.a", "1) a", ". a", "a. b", "-\u{3000}a", "－ a", "１. a",
  "**太字**", "*斜体*", "#- a",
])
func リスト行でない行(line: String) {
  #expect(ListLine(line) == nil)
}

@Test func チェックボックスを読む() throws {
  let unchecked = try #require(ListLine("  - [ ] task"))
  #expect(unchecked.checkbox == ListLine.Checkbox(range: 4..<7, isChecked: false))
  #expect(unchecked.contentStart == 8)

  let checked = try #require(ListLine("1. [x]\tdone"))
  #expect(checked.checkbox == ListLine.Checkbox(range: 3..<6, isChecked: true))
  #expect(checked.contentStart == 7)

  // 空白が続かなければ、チェックボックスではなく本文。
  for line in ["- [ ]", "- [x]task", "- [X] task", "- [y] task", "- [] task"] {
    let item = try #require(ListLine(line))
    #expect(item.checkbox == nil, "\(line)")
    #expect(item.contentStart == 2, "\(line)")
    #expect(!item.isEmpty, "\(line)")
  }
}

@Test(arguments: [
  ("- ", true), ("-   ", true), ("  1. \t", true), ("- [ ] ", true), ("- [x]  ", true),
  ("- a", false), ("- [ ] a", false), ("- [ ]", false), ("-  a ", false),
])
func 空の項目を見分ける(line: String, isEmpty: Bool) throws {
  #expect(try #require(ListLine(line)).isEmpty == isEmpty)
}

@Test func 位置はUTF16で数える() throws {
  let item = try #require(ListLine("- [ ] 😀"))
  #expect(item.contentStart == 6)
  #expect(!item.isEmpty)
}
