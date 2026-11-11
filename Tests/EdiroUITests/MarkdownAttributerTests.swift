import AppKit
import EdiroCore
import EditorEngine
import EditorMarkdown
import Testing

@testable import EdiroUI

extension AppKitTests {
  struct MarkdownAttributerTests {
    final class EditRecorder: NSObject, NSTextStorageDelegate {
      var ranges: [NSRange] = []

      func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
      ) {
        ranges.append(editedRange)
      }
    }

    @Test func 指定した行だけ装飾を当て直す() {
      let text = "# 見出し\n本文と**太字**\n> 引用"
      let document = Document(id: "lines", text: text, lineTokenizer: MarkdownTokenizer())
      let storage = NSTextStorage(string: text)
      let recorder = EditRecorder()
      storage.delegate = recorder
      let attributer = MarkdownAttributer(theme: .fallback, preferences: .default)
      let untouched = NSAttributedString(attributedString: storage)

      attributer.apply(lines: IndexSet(integer: 1), of: document, to: storage)

      let line = (text as NSString).range(of: "本文と**太字**\n")
      #expect(recorder.ranges == [line])
      for other in [NSRange(location: 0, length: line.location), NSRange(location: NSMaxRange(line), length: storage.length - NSMaxRange(line))] {
        #expect(storage.attributedSubstring(from: other).isEqual(to: untouched.attributedSubstring(from: other)))
      }
      let expected = highlighted(text)
      #expect(
        storage.attributedSubstring(from: line).isEqual(to: expected.attributedSubstring(from: line)))
    }

    /// `substring` の先頭に付いたフォントと前景色。和文の位置のフォントは NSTextStorage が
    /// 代替フォントに置き換えるので、書体を比べるときは欧文の文字 (記法の記号など) の位置を見る。
    private func styled(
      _ text: String, at substring: String, preferences: Preferences = .default
    ) throws -> (font: NSFont, color: NSColor) {
      let storage = highlighted(text, preferences: preferences)
      let range = (text as NSString).range(of: substring)
      try #require(range.location != NSNotFound)
      let attributes = storage.attributes(at: range.location, effectiveRange: nil)
      return (
        try #require(attributes[.font] as? NSFont),
        try #require(attributes[.foregroundColor] as? NSColor)
      )
    }

    @Test func 見出しは本文より大きいフォントになる() throws {
      let text = "# 見出し\n本文"
      let heading = try styled(text, at: "# 見出し").font
      let body = try styled(text, at: "本文").font
      #expect(heading.pointSize > body.pointSize)
    }

    @Test func 引用の文字サイズは本文と同じ() throws {
      let text = "> 引用文\n本文"
      let quote = try styled(text, at: "引用文").font
      let body = try styled(text, at: "本文").font
      #expect(
        quote.pointSize == body.pointSize,
        "quote: \(quote.pointSize), body: \(body.pointSize)")
    }

    @Test func 装飾のない本文は既定の前景色になる() throws {
      let color = try styled("ただの本文です", at: "ただの").color
      let expected = Theme.fallback.editorForeground.nsColor
      #expect(abs(color.redComponent - expected.redComponent) < 0.01)
    }

    @Test func インラインコードには専用の色が付く() throws {
      let code = try styled("実行は `swift test` で", at: "`swift test`").color
      let body = try styled("実行は `swift test` で", at: "実行は").color
      #expect(code != body)
    }

    /// 本文が等幅でない設定。既定の本文は等幅で、コードと書体では見分けられない。
    private var proportional: Preferences {
      var preferences = Preferences.default
      preferences.fontName = "Helvetica"
      return preferences
    }

    @Test func 見出しの中の記法は見出しの大きさと色を引き継ぐ() throws {
      let text = "# 見出しの**太字**と`code`と[リンク](https://example.com)"
      let palette = SyntaxPalette(theme: .fallback)
      let heading = try styled(text, at: "# ", preferences: proportional)

      let strong = try styled(text, at: "**太字**", preferences: proportional)
      #expect(strong.font == heading.font && strong.color == heading.color)

      let code = try styled(text, at: "`code`", preferences: proportional)
      let scale = palette.style(for: .heading(level: 1)).scale
      let expected = FontResolver(preferences: proportional).resolve(
        for: SyntaxStyle(bold: true, monospaced: true, scale: scale)
      ).font
      #expect(code.font == expected)
      #expect(code.font.pointSize == heading.font.pointSize && code.font.isFixedPitch)
      #expect(code.color == palette.style(for: .inlineCode).color?.nsColor)

      let link = try styled(text, at: "[リンク]", preferences: proportional)
      #expect(link.font == heading.font)
      #expect(link.color == palette.style(for: .link).color?.nsColor)
    }

    @Test func 引用の中の斜体と太字は引用の色のまま() throws {
      let text = "> 引用の*斜体*と**太字**"
      let quote = try styled(text, at: "> ")

      let emphasis = try styled(text, at: "*斜体*")
      #expect(emphasis.font == quote.font && emphasis.color == quote.color)

      let strong = try styled(text, at: "**太字**")
      #expect(strong.color == quote.color)
      let boldItalic = FontResolver(preferences: .default).resolve(
        for: SyntaxStyle(bold: true, italic: true)
      ).font
      #expect(strong.font == boldItalic && strong.font != quote.font)
    }

    @Test func 入れ子の記法は直近の外側の見た目を引き継ぐ() throws {
      let palette = SyntaxPalette(theme: .fallback)
      let linkColor = palette.style(for: .link).color?.nsColor

      let quoted = "> **[a](b)**"
      let link = try styled(quoted, at: "[a]")
      #expect(link.color == linkColor)
      let boldItalic = FontResolver(preferences: .default).resolve(
        for: SyntaxStyle(bold: true, italic: true)
      ).font
      #expect(link.font == boldItalic)

      let heading = "# [**a**](b)"
      let strong = try styled(heading, at: "**a**")
      #expect(strong.color == linkColor)
      #expect(strong.font == (try styled(heading, at: "# ")).font)
    }

    @Test func URLは外側の見た目に下線だけを足す() throws {
      let url = "https://example.com/a"
      for (text, outer) in [
        ("x \(url)", "x"), ("# h \(url)", "# "), ("> q \(url)", "> "), ("**\(url)**", "**"),
        ("*\(url)*", "*"), ("[a](\(url))", "[a]"), ("# [a](\(url))", "[a]"),
        ("> **[a](\(url))**", "[a]"), ("<\(url)>", "<"),
      ] {
        let storage = highlighted(text)
        let range = (text as NSString).range(of: url)
        var effective = NSRange()
        let attributes = storage.attributes(
          at: range.location, longestEffectiveRange: &effective, in: range)
        #expect(effective == range, "\(text)")
        var expected = storage.attributes(
          at: (text as NSString).range(of: outer).location, effectiveRange: nil)
        #expect(expected[.underlineStyle] == nil, "\(text)")
        expected[.underlineStyle] = NSUnderlineStyle.single.rawValue
        #expect(NSDictionary(dictionary: attributes).isEqual(to: expected), "\(text)")
        #expect(underlinedRanges(storage) == [range], "\(text)")
      }
    }

    @Test func 下線はURLだけが持ち中の要素にも引き継ぐ() {
      let palette = SyntaxPalette(theme: .fallback)
      let url = palette.style(for: .url)
      #expect(url == SyntaxStyle(underline: true))
      #expect(palette.style(for: .strong).inside(url).underline)
      let link = palette.style(for: .link)
      #expect(url.inside(link) == SyntaxStyle(color: link.color, underline: true))
      for kind in MarkdownTokenKind.allCases where kind != .url {
        #expect(!palette.style(for: kind).underline, "\(kind)")
      }
    }

    @Test func URLでない文字には下線を付けない() {
      for text in [
        "see `https://example.com` now", "```\nhttps://example.com\n```",
        "[https://example.com](b)", "see example.com and www.example.com",
        "mail a@example.com", "<mailto:a@example.com>", "ftp://example.com",
        "# 見出し\n> 引用の**太字**と*斜体*と[リンク](rel)\n- item",
      ] {
        #expect(underlinedRanges(highlighted(text)).isEmpty, "\(text)")
      }
    }

    @Test func 本文の太字と斜体は本文の色で描く() throws {
      let text = "本文と**太字**と*斜体*"
      let body = try styled(text, at: "本文")
      let resolver = FontResolver(preferences: .default)
      let strong = try styled(text, at: "**太字**")
      #expect(strong.color == body.color)
      #expect(strong.font == resolver.resolve(for: SyntaxStyle(bold: true)).font)
      let emphasis = try styled(text, at: "*斜体*")
      #expect(emphasis.color == body.color)
      #expect(emphasis.font == resolver.resolve(for: SyntaxStyle(italic: true)).font)
    }

    @Test func 隣り合う記法は互いの見た目を引き継がない() throws {
      let text = "**a**`c`"
      let code = try styled(text, at: "`c`")
      let expected = FontResolver(preferences: .default).resolve(
        for: SyntaxStyle(monospaced: true)
      ).font
      #expect(code.font == expected)
    }

    @Test func コードの中のリンクの記法はコードの見た目のまま() throws {
      let text = "`[a](https://example.com)`"
      let storage = highlighted(text)
      var range = NSRange()
      let color = storage.attribute(.foregroundColor, at: 0, effectiveRange: &range) as? NSColor
      #expect(range == NSRange(location: 0, length: storage.length))
      #expect(color == SyntaxPalette(theme: .fallback).style(for: .inlineCode).color?.nsColor)
    }

    @Test func コードブロックは空行と改行まで等幅の書体になる() throws {
      // 空行の高さを周りのコードの行と揃えるため、改行にもコードの書体を付ける。
      let text = "```\na\n\nb\n```\nplain"
      let storage = highlighted(text, preferences: proportional)
      let code = try styled(text, at: "a", preferences: proportional).font
      for location in [3, 5, 6, 8] {
        let font = try #require(storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch && font.pointSize == code.pointSize, "\(location)")
      }
      #expect(try !styled(text, at: "plain", preferences: proportional).font.isFixedPitch)
    }

    @Test func 閉じていないコードブロックは文書の末尾まで続く() throws {
      let text = "plain\n```\n# not a heading\n**not bold**"
      #expect(try styled(text, at: "not a heading", preferences: proportional).font.isFixedPitch)
      #expect(try styled(text, at: "not bold", preferences: proportional).font.isFixedPitch)
      #expect(try !styled(text, at: "plain", preferences: proportional).font.isFixedPitch)
    }
  }
}
