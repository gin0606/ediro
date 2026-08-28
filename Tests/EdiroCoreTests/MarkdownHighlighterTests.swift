import Foundation
import Testing

@testable import EdiroCore

private func kinds(_ text: String) -> [Token.Kind] {
  MarkdownHighlighter().tokens(in: text).map(\.kind)
}

@Test func 見出しをレベル付きで検出する() {
  #expect(kinds("# 大見出し\n### 小見出し") == [.heading(level: 1), .heading(level: 3)])
}

@Test func 行頭以外のシャープは見出しにしない() {
  #expect(kinds("ハッシュタグ #tag は見出しではない").isEmpty)
}

@Test func 強調と斜体を区別する() {
  #expect(kinds("**太字** と *斜体*") == [.strong, .emphasis])
}

@Test func インラインコードを検出する() {
  #expect(kinds("`swift test` を実行する") == [.inlineCode])
}

@Test func コードブロックは中の記法を飲み込む() {
  let text = """
    ```swift
    // # これは見出しではない
    let x = **1**
    ```
    """
  #expect(kinds(text) == [.codeBlock])
}

@Test func リンクを検出する() {
  #expect(kinds("[エディ太郎](https://editaro.com) を参考にした") == [.link])
}

@Test func リストと引用を検出する() {
  #expect(kinds("- ひとつ\n1. ふたつ") == [.listMarker, .listMarker])
  #expect(kinds("> 引用文") == [.blockquote])
}

@Test func トークンは出現順に並ぶ() {
  let tokens = MarkdownHighlighter().tokens(in: "# 見出し\n\n`code` と **太字**")
  let locations = tokens.map(\.range.location)
  #expect(locations == locations.sorted())
}

@Test func 空文字では何も検出しない() {
  #expect(kinds("").isEmpty)
}

@Test func 日本語に挟まれた強調を検出する() {
  #expect(kinds("エディ太郎の**次男**。") == [.strong])
}

@Test func 日本語に挟まれた斜体を検出する() {
  #expect(kinds("AppKit で書き直した *下書き専用* エディタ。") == [.emphasis])
}

@Test func 行内に強調と斜体が混在しても両方検出する() {
  #expect(kinds("**太字**と*斜体*が同じ行") == [.strong, .emphasis])
}
