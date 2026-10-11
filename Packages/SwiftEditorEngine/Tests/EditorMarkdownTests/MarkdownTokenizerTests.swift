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

    @Test func inlineCode() throws {
        #expect(try merged("`swift test` runs it") == [FlatToken(kind: .inlineCode, range: 0..<12)])
    }

    @Test func aCodeBlockSwallowsTheSyntaxInside() throws {
        let text = "```swift\n// # not a heading\nlet x = **1**\n```"
        #expect(try merged(text) == [FlatToken(kind: .codeBlock, range: 0..<(text as NSString).length)])
    }

    @Test func links() throws {
        #expect(try merged("[Editaro](https://editaro.com) inspired it") == [FlatToken(kind: .link, range: 0..<30)])
    }

    @Test func listMarkersAndBlockquotes() throws {
        #expect(try merged("- one\n1. two") == [FlatToken(kind: .listMarker, range: 0..<2), FlatToken(kind: .listMarker, range: 6..<9)])
        #expect(try merged("> quote") == [FlatToken(kind: .blockquote, range: 0..<7)])
    }

    @Test func tokensAreInTextOrder() throws {
        let offsets = try tokens("# Heading\n\n`code` and **bold**").map(\.range.lowerBound)
        #expect(offsets == offsets.sorted())
        #expect(offsets.count == 3)
    }

    @Test func emptyTextHasNoTokens() throws {
        #expect(try tokens("").isEmpty)
    }

    @Test func strongBetweenJapaneseCharacters() throws {
        #expect(try merged("エディ太郎の**次男**。") == [FlatToken(kind: .strong, range: 6..<12)])
    }

    @Test func emphasisBetweenJapaneseCharacters() throws {
        #expect(try merged("AppKit で書き直した *下書き専用* エディタ。") == [FlatToken(kind: .emphasis, range: 14..<21)])
    }

    @Test func strongAndEmphasisOnOneLine() throws {
        #expect(try kinds("**太字**と*斜体*が同じ行") == [.strong, .emphasis])
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
        #expect(MarkdownTokenKind.allCases.count == 13)
        #expect(Set(MarkdownTokenKind.allCases).count == 13)
        for kind in MarkdownTokenKind.allCases { #expect(MarkdownTokenKind(kind: kind.kind, modifiers: kind.modifiers) == kind) }
        #expect(MarkdownTokenKind(kind: "heading", modifiers: ["level7"]) == nil)
        #expect(MarkdownTokenKind(kind: "heading", modifiers: []) == nil)
        #expect(MarkdownTokenKind(kind: "strong", modifiers: ["level1"]) == nil)
        #expect(MarkdownTokenKind(kind: "keyword", modifiers: []) == nil)
    }

    /// Compares with the regular-expression highlighter this tokenizer replaced, on texts
    /// whose fences all close; only unclosed fences differ by design.
    @Test func matchesTheRegularExpressionHighlighterOnClosedFences() throws {
        let pieces = ["# ", "## ", "####### ", "#", "> ", " >", "- ", "* ", "+ ", "1. ", "１. ", "12.", " ", "\t",
                      "*", "**", "***", "`", "``", "```", "[", "]", "(", ")", "](", "a", "あ", "😀", "\n", "\n",
                      "\u{2028}", "\u{2029}", "\u{0B}", "\u{0C}", "\u{85}", "\u{3000}", "x*", "*x", "_"]
        var generator = SplitMix(seed: 0x5EED)
        var compared = 0
        for _ in 0..<10000 {
            let count = Int(generator.next() % 14) + 1
            let text = (0..<count).map { _ in pieces[Int(generator.next() % UInt64(pieces.count))] }.joined()
            let fenceLines = text.split(omittingEmptySubsequences: false) { "\n\u{0B}\u{0C}\u{85}\u{2028}\u{2029}".contains($0) }
                .filter { $0.hasPrefix("```") }.count
            guard fenceLines % 2 == 0 else { continue }
            compared += 1
            #expect(try merged(text) == merge(LegacyHighlighter.tokens(in: text)), "\(text.debugDescription)")
        }
        #expect(compared > 1000)
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

/// The regular-expression highlighter this tokenizer replaced, kept as an oracle.
enum LegacyHighlighter {
    private enum Matched { case fixed(MarkdownTokenKind), heading }
    private static let patterns: [(Matched, String)] = [
        (.fixed(.codeBlock), "(?m)^```[\\s\\S]*?^```"),
        (.heading, "(?m)^(#{1,6})[ \\t]+.*$"),
        (.fixed(.blockquote), "(?m)^[ \\t]*>[ \\t]?.*$"),
        (.fixed(.listMarker), "(?m)^[ \\t]*(?:[-*+]|\\d+\\.)[ \\t]+"),
        (.fixed(.link), "\\[[^\\]\\n]*\\]\\([^)\\n]*\\)"),
        (.fixed(.strong), "(?<!\\*)\\*\\*(?!\\s)[^*\\n]+(?<!\\s)\\*\\*(?!\\*)"),
        (.fixed(.emphasis), "(?<!\\*)\\*(?!\\s|\\*)[^*\\n]+(?<!\\s)\\*(?!\\*)"),
        (.fixed(.inlineCode), "`[^`\\n]+`")
    ]
    private static let expressions = patterns.map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    static func tokens(in text: String) -> [FlatToken] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        var claimed: [NSRange] = [], result: [FlatToken] = []
        for (matched, regex) in expressions {
            for match in regex.matches(in: text, range: full) {
                let range = match.range
                if claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
                let kind: MarkdownTokenKind
                switch matched {
                case .fixed(let fixed): kind = fixed
                case .heading: kind = .heading(level: match.range(at: 1).length)
                }
                claimed.append(range)
                result.append(FlatToken(kind: kind, range: range.location..<NSMaxRange(range)))
            }
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
