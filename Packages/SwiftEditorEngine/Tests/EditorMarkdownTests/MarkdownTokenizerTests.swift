import Testing
import EditorEngine
import EditorMarkdown
import Foundation

/// A token in UTF-16 offsets of the whole text.
struct FlatToken: Equatable, CustomStringConvertible {
    var kind: MarkdownTokenKind
    var range: Range<Int>
    var description: String { "\(kind)@\(range)" }
}

@MainActor func tokens(_ text: String) throws -> [FlatToken] {
    let d = Document(id: "markdown", text: text, lineTokenizer: MarkdownTokenizer())
    let snapshot = d.snapshot
    return try d.lineTokens(in: 0..<snapshot.lineCount).map { token in
        FlatToken(kind: try #require(MarkdownTokenKind(token)), range: try snapshot.offsets(in: token.range))
    }
}
/// Joins tokens of one kind that touch, so a code block split into lines reads as one.
@MainActor func merged(_ text: String) throws -> [FlatToken] { merge(try tokens(text)) }
func merge(_ tokens: [FlatToken]) -> [FlatToken] {
    var result: [FlatToken] = []
    for token in tokens {
        if let last = result.last, last.kind == token.kind, last.range.upperBound == token.range.lowerBound {
            result[result.count - 1].range = last.range.lowerBound..<token.range.upperBound
        } else { result.append(token) }
    }
    return result
}
@MainActor func kinds(_ text: String) throws -> [MarkdownTokenKind] { try merged(text).map(\.kind) }

@Suite @MainActor struct MarkdownTokenizerTests {
    @Test func headingsCarryTheirLevel() throws {
        #expect(try merged("# Title\n### Small") == [FlatToken(kind: .heading(level: 1), range: 0..<7),
                                                      FlatToken(kind: .heading(level: 3), range: 8..<17)])
        #expect(try kinds("####### seven") == [])
        #expect(try kinds("#nospace") == [])
    }

    @Test func aHashOutsideTheLineStartIsNotAHeading() throws {
        #expect(try kinds("a hashtag #tag is not a heading").isEmpty)
    }

    @Test func strongAndEmphasisAreDistinguished() throws {
        #expect(try merged("**bold** and *italic*") == [FlatToken(kind: .strong, range: 0..<8),
                                                         FlatToken(kind: .emphasis, range: 13..<21)])
    }

    @Test func aCodeBlockSwallowsTheSyntaxInside() throws {
        let text = "```swift\n// # not a heading\nlet x = **1**\n```"
        #expect(try merged(text) == [FlatToken(kind: .codeBlock, range: 0..<(text as NSString).length)])
    }

    @Test func listMarkersAndBlockquotes() throws {
        #expect(try merged("- one\n1. two") == [FlatToken(kind: .listMarker, range: 0..<2), FlatToken(kind: .listMarker, range: 6..<9)])
        #expect(try merged("> quote") == [FlatToken(kind: .blockquote, range: 0..<7)])
    }

    @Test func emptyTextHasNoTokens() throws {
        #expect(try tokens("").isEmpty)
    }

    @Test func markersNeedTextNextToThemAndARunOfTheirLength() throws {
        for text in ["x ** a**", "x **a **", "x * a*", "x *a *", "x ***a***", "x **a*", "x *a**", "x ****"] {
            #expect(try tokens(text) == [], "\(text)")
        }
    }

    @Test func inlineCodeRunsFromARunOfBackticksToOneOfTheSameLength() throws {
        #expect(try tokens("``a``") == [FlatToken(kind: .inlineCode, range: 0..<5)])
        #expect(try tokens("`` `**a**` ``") == [FlatToken(kind: .inlineCode, range: 0..<13)])
        #expect(try tokens("x `` y") == [])
        #expect(try tokens("``a`") == [])
        // Inside code a backslash is literal, outside it escapes a backtick.
        #expect(try tokens("`a\\`b") == [FlatToken(kind: .inlineCode, range: 0..<4)])
        #expect(try tokens("\\``a`") == [FlatToken(kind: .inlineCode, range: 2..<5)])
        // A closing run does not open more code that hides what follows.
        #expect(try tokens("``x`` **bold** `y`") == [FlatToken(kind: .inlineCode, range: 0..<5), FlatToken(kind: .strong, range: 6..<14),
                                                     FlatToken(kind: .inlineCode, range: 15..<18)])
    }

    @Test func lineStartMarkersAndWhitespaceNextToMarkers() throws {
        #expect(try tokens("+ x") == [FlatToken(kind: .listMarker, range: 0..<2)])
        #expect(try tokens("１. x") == [FlatToken(kind: .listMarker, range: 0..<3)])
        #expect(try tokens("  > q") == [FlatToken(kind: .blockquote, range: 0..<5)])
        #expect(try tokens("#\tx") == [FlatToken(kind: .heading(level: 1), range: 0..<3)])
        #expect(try tokens("x **\u{3000}a**") == [])
        #expect(try tokens("x *a\u{3000}*") == [])
    }

    // An unclosed code block runs to the end of the document, as in CommonMark.

    @Test func anUnclosedCodeBlockRunsToTheEndOfTheDocument() throws {
        let text = "intro\n```\n# not a heading\n\n**not bold**"
        #expect(try merged(text) == [FlatToken(kind: .codeBlock, range: 6..<(text as NSString).length)])
        // Closing it restores the text after the fence.
        #expect(try kinds(text + "\n```\n# heading") == [.codeBlock, .heading(level: 1)])
    }

    @Test func codeBlockLinesIncludeTheirLineBreakExceptTheClosingLine() throws {
        let text = "```\na\n\nb\n```\nafter"
        #expect(try tokens(text) == [FlatToken(kind: .codeBlock, range: 0..<4), FlatToken(kind: .codeBlock, range: 4..<6),
                                     FlatToken(kind: .codeBlock, range: 6..<7), FlatToken(kind: .codeBlock, range: 7..<9),
                                     FlatToken(kind: .codeBlock, range: 9..<12)])
        // An empty last line inside an unclosed block has nothing to style.
        #expect(try tokens("```\n") == [FlatToken(kind: .codeBlock, range: 0..<4)])
        // The rest of the closing line is tokenized as text.
        #expect(try kinds("```\nx\n``` **bold**") == [.codeBlock, .strong])
    }

    @Test func typingTheFenceRestylesTheLinesAfterIt() throws {
        let d = Document(id: "typing", text: "``\n# heading\ntext", lineTokenizer: MarkdownTokenizer())
        var reported: IndexSet?
        let s = try d.observe { reported = $0.retokenizedLines }
        try d.apply([TextEdit(TextRange(Position(0, 2), Position(0, 2)), "`")])
        #expect(reported == IndexSet(integersIn: 0..<3))
        #expect(try d.lineTokens(in: 0..<3).allSatisfy { MarkdownTokenKind($0) == .codeBlock })
        try d.apply([TextEdit(TextRange(Position(1, 2), Position(1, 2)), "x")])
        #expect(reported == IndexSet(integer: 1))
        s.cancel()
    }

    @Test func lineSeparatorsOtherThanLineFeedStartLines() throws {
        #expect(try merged("a\u{2028}# h\u{2029}> q\u{0C}- x") == [
            FlatToken(kind: .heading(level: 1), range: 2..<5), FlatToken(kind: .blockquote, range: 6..<9),
            FlatToken(kind: .listMarker, range: 10..<12)])
        #expect(try merged("```\u{2028}**x**\u{2028}```\u{85}# h") == [
            FlatToken(kind: .codeBlock, range: 0..<13), FlatToken(kind: .heading(level: 1), range: 14..<17)])
    }

    @Test func kindsRoundTripThroughStrings() {
        for kind in MarkdownTokenKind.allCases { #expect(MarkdownTokenKind(kind: kind.kind, modifiers: kind.modifiers) == kind) }
        #expect(MarkdownTokenKind(kind: "heading", modifiers: ["level7"]) == nil)
        #expect(MarkdownTokenKind(kind: "heading", modifiers: []) == nil)
        #expect(MarkdownTokenKind(kind: "strong", modifiers: ["level1"]) == nil)
        #expect(MarkdownTokenKind(kind: "keyword", modifiers: []) == nil)
    }

    // Inline constructs nest, follow CommonMark's precedence and stay within one line.

    /// The token of `kind` covering the first occurrence of `substring` in `text`.
    private func token(_ kind: MarkdownTokenKind, _ substring: String, in text: String) -> FlatToken {
        let range = (text as NSString).range(of: substring)
        return FlatToken(kind: kind, range: range.location..<(range.location + range.length))
    }

    @Test func headingsAndBlockquotesHoldInlineConstructs() throws {
        let heading = "# 見出しの**太字**と`code`と[リンク](https://example.com)"
        #expect(try tokens(heading) == [
            FlatToken(kind: .heading(level: 1), range: 0..<(heading as NSString).length),
            token(.strong, "**太字**", in: heading), token(.inlineCode, "`code`", in: heading),
            token(.link, "[リンク](https://example.com)", in: heading), token(.url, "https://example.com", in: heading)])
        let quote = "> 引用の*斜体*と**太字**"
        #expect(try tokens(quote) == [
            FlatToken(kind: .blockquote, range: 0..<(quote as NSString).length),
            token(.emphasis, "*斜体*", in: quote), token(.strong, "**太字**", in: quote)])
        #expect(try tokens("- **a**") == [FlatToken(kind: .listMarker, range: 0..<2), FlatToken(kind: .strong, range: 2..<7)])
    }

    @Test func anEnclosingTokenComesBeforeTheTokensInside() throws {
        #expect(try tokens("**[a](b)**") == [FlatToken(kind: .strong, range: 0..<10), FlatToken(kind: .link, range: 2..<8)])
        #expect(try tokens("[**a**](b)") == [FlatToken(kind: .link, range: 0..<10), FlatToken(kind: .strong, range: 1..<6)])
        #expect(try tokens("*a `b` c*") == [FlatToken(kind: .emphasis, range: 0..<9), FlatToken(kind: .inlineCode, range: 3..<6)])
        #expect(try tokens("# *a*") == [FlatToken(kind: .heading(level: 1), range: 0..<5), FlatToken(kind: .emphasis, range: 2..<5)])
    }

    @Test func inlineCodeKeepsTheSyntaxInsideLiteral() throws {
        #expect(try tokens("`[a](https://example.com)`") == [FlatToken(kind: .inlineCode, range: 0..<26)])
        #expect(try tokens("`**a**`") == [FlatToken(kind: .inlineCode, range: 0..<7)])
        // An asterisk inside code neither pairs nor stops a pair around the code.
        #expect(try tokens("**a `*` b**") == [FlatToken(kind: .strong, range: 0..<11), FlatToken(kind: .inlineCode, range: 4..<7)])
        // Code starting inside a link label and ending after it leaves no link.
        #expect(try tokens("[a `b](c)`") == [FlatToken(kind: .inlineCode, range: 3..<10)])
    }

    @Test func linkDestinationsAndTitles() throws {
        // URLs in destinations or in the text are tested with the other URLs.
        func tokens(_ text: String) throws -> [FlatToken] { try EditorMarkdownTests.tokens(text).filter { $0.kind != .url } }
        for text in ["[a](https://example.com/Foo_(bar))", "[a](https://example.com/?ids[]=1)", "[a](<https://example.com/a b>)",
                     "[a](f(x))", "[a](b \"t\")", "[a](b 't')", "[a](b (t))", "[a]( b )", "[a]()", "[a](b\\))",
                     "[a](*b*)", "[a](b \"*t*\")", "[a](\\(b)", "[a](b \"t\\\"u\")", "[a](<b\\>c>)", "[a](b \"t\" )"] {
            #expect(try tokens(text) == [FlatToken(kind: .link, range: 0..<(text as NSString).length)], "\(text)")
        }
        for text in ["[a](https://example.com/a b)", "[a](b c)", "[a](b\tc)", "[a](<b)", "[a](b(c)", "[a](b \"t)", "\\[a](b)",
                     "[a](b(c \"t\")", "[a](<b<c>)", "[a](<b>\"t\")", "[a](b (t(u)))", "[a](b\u{01}c)", "[a](b\u{7F}c)"] {
            #expect(try tokens(text) == [], "\(text)")
        }
    }

    @Test func linkLabels() throws {
        #expect(try tokens("[a [b] c](d)") == [FlatToken(kind: .link, range: 0..<12)])
        #expect(try tokens("[a[b](c)") == [FlatToken(kind: .link, range: 2..<8)])
        #expect(try tokens("[a `]` b](c)") == [FlatToken(kind: .link, range: 0..<12), FlatToken(kind: .inlineCode, range: 3..<6)])
        // A link contains no link, so only the inner one is.
        #expect(try tokens("[a [b](c)](d)") == [FlatToken(kind: .link, range: 3..<9)])
        // Strong and emphasis do not pair across a link's boundary.
        #expect(try tokens("**a [b** c](d)") == [FlatToken(kind: .link, range: 4..<14)])
        #expect(try tokens("*[a*](b)") == [FlatToken(kind: .link, range: 1..<8)])
        #expect(try tokens("[*a](b) [c*](d)") == [FlatToken(kind: .link, range: 0..<7), FlatToken(kind: .link, range: 8..<15)])
        #expect(try tokens("[**a](b) and [c**](d)") == [FlatToken(kind: .link, range: 0..<8), FlatToken(kind: .link, range: 13..<21)])
    }

    @Test func escapesAndAutolinksKeepMarkersLiteral() throws {
        #expect(try tokens("\\*a\\*") == [])
        #expect(try tokens("\\**a*") == [FlatToken(kind: .emphasis, range: 2..<5)])
        #expect(try tokens("\\`a`") == [])
        #expect(try tokens("<https://example.com/*a*>") == [FlatToken(kind: .url, range: 1..<24)])
        #expect(try tokens("<https://example.com/`a> and `b`") == [FlatToken(kind: .url, range: 1..<23),
                                                                   FlatToken(kind: .inlineCode, range: 29..<32)])
        // Not an autolink: a one-letter scheme, or a space inside.
        #expect(try tokens("<a:*b*>") == [FlatToken(kind: .emphasis, range: 3..<6)])
        #expect(try tokens("<https://x *b*>") == [FlatToken(kind: .url, range: 1..<10), FlatToken(kind: .emphasis, range: 11..<14)])
        #expect(try tokens("<a+b.c-d:*x*>") == [])
        let scheme = String(repeating: "a", count: 32)
        #expect(try tokens("<\(scheme):*x*>") == [])
        #expect(try tokens("<a\(scheme):*x*>") == [FlatToken(kind: .emphasis, range: 35..<38)])
        #expect(try tokens("<ab:c\u{01}*x*>") == [FlatToken(kind: .emphasis, range: 6..<9)])
        #expect(try tokens("<ab:c\u{7F}*x*>") == [FlatToken(kind: .emphasis, range: 6..<9)])
    }

    /// Japanese has no spaces between words, so markers count with a letter or punctuation
    /// right outside them, on either side.
    @Test func markersBetweenJapaneseCharacters() throws {
        let cases: [(text: String, expected: [(MarkdownTokenKind, String)])] = [
            ("エディ太郎の**次男**。", [(.strong, "**次男**")]),
            ("**太字**と*斜体*が同じ行", [(.strong, "**太字**"), (.emphasis, "*斜体*")]),
            ("本文と**太字**と*斜体*", [(.strong, "**太字**"), (.emphasis, "*斜体*")])
        ]
        for (text, expected) in cases {
            #expect(try tokens(text) == expected.map { token($0.0, $0.1, in: text) }, "\(text)")
        }
        let quote = "> 引用と**太字**。"
        #expect(try tokens(quote).dropFirst() == [token(.strong, "**太字**", in: quote)])
    }

    @Test func inlineConstructsDoNotSpanLines() throws {
        #expect(try tokens("**a\u{2028}b**") == [])
        #expect(try tokens("`a\u{2029}b`") == [])
        #expect(try tokens("[a\u{0B}b](c)") == [])
        #expect(try tokens("[a](b\u{2028}c)") == [])
        #expect(try tokens("# a\u{2028}**b**") == [FlatToken(kind: .heading(level: 1), range: 0..<3), FlatToken(kind: .strong, range: 4..<9)])
        // After a closing fence, the rest of its line holds inline constructs.
        #expect(try tokens("```\nx\n``` `y`") == [FlatToken(kind: .codeBlock, range: 0..<4), FlatToken(kind: .codeBlock, range: 4..<6),
                                                FlatToken(kind: .codeBlock, range: 6..<9), FlatToken(kind: .inlineCode, range: 10..<13)])
    }

    /// On random texts, every token lies within its line, and tokens nest without crossing,
    /// an enclosing token first.
    @Test func tokensNestWithinLines() {
        let pieces = ["# ", "## ", "#", "> ", " >", "- ", "* ", "1. ", " ", "\t", "*", "**", "***", "`", "``", "```",
                      "[", "]", "(", ")", "](", "<", ">", "<a:", "<https:", "\\", "\"", "'", "a", "あ", "😀", "\n", "\n",
                      "\r\n", "\r", "\u{2028}", "\u{2029}", "\u{0B}", "\u{0C}", "\u{85}", "\u{3000}", "_",
                      "*a*", "**b**", "`c`", "[d](e)", "](f)", "<g:h>", "[*", "*](f)", "``",
                      "https://", "http://a.b/", "https://c.d/(e)", "(https://f.g", "<https://h.i>", "x.y", "@"]
        let breaks: Set<UInt16> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
        let tokenizer = MarkdownTokenizer()
        var generator = SplitMix(seed: 0x5EED)
        var nested = 0
        var urls = 0
        for _ in 0..<20000 {
            let count = Int(generator.next() % 16) + 1
            let text = (0..<count).map { _ in pieces[Int(generator.next() % UInt64(pieces.count))] }.joined()
            var state = tokenizer.initialState
            // The document's lines, each with its LF.
            var lines: [String] = []
            var current = ""
            for character in text.unicodeScalars {
                current.unicodeScalars.append(character)
                if character == "\n" { lines.append(current); current = "" }
            }
            lines.append(current)
            for line in lines {
                let units = Array(line.utf16)
                let result = tokenizer.tokenize(line, startingIn: state)
                state = result.endState
                let ranges = result.tokens.map(\.range)
                for (index, token) in result.tokens.enumerated() {
                    let range = token.range
                    #expect(!range.isEmpty && range.lowerBound >= 0 && range.upperBound <= units.count, "\(text.debugDescription)")
                    guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= units.count else { continue }
                    #expect(!UTF16.isTrailSurrogate(units[range.lowerBound]), "\(text.debugDescription)")
                    #expect(range.upperBound == units.count || !UTF16.isTrailSurrogate(units[range.upperBound]), "\(text.debugDescription)")
                    #expect(range.lowerBound == 0 || !(units[range.lowerBound - 1] == 0x0D && units[range.lowerBound] == 0x0A),
                            "\(text.debugDescription)")
                    // Only a code block line covers a line break: its own, at its end.
                    var upper = range.upperBound
                    if token.kind == "codeBlock", breaks.contains(units[upper - 1]) {
                        upper -= 1
                        if units[upper] == 0x0A, upper > range.lowerBound, units[upper - 1] == 0x0D { upper -= 1 }
                    }
                    #expect(!(range.lowerBound..<upper).contains { breaks.contains(units[$0]) }, "\(text.debugDescription) \(token)")
                    if token.kind == "url" {
                        let url = String(decoding: units[range], as: UTF16.self).lowercased()
                        #expect(url.hasPrefix("http://") || url.hasPrefix("https://"), "\(text.debugDescription) \(token)")
                        urls += 1
                    }
                    for later in ranges[(index + 1)...] {
                        let ordered = later.lowerBound > range.lowerBound
                            || (later.lowerBound == range.lowerBound && later.upperBound < range.upperBound)
                        #expect(ordered, "\(text.debugDescription)")
                        #expect(later.lowerBound >= range.upperBound || later.upperBound <= range.upperBound, "\(text.debugDescription)")
                        if later.lowerBound < range.upperBound { nested += 1 }
                    }
                }
            }
        }
        #expect(nested > 1000, "\(nested)")
        #expect(urls > 1000, "\(urls)")
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
