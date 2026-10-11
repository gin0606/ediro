import EditorEngine
import Foundation

/// The Markdown constructs `MarkdownTokenizer` recognizes.
public enum MarkdownTokenKind: Hashable, Sendable {
    case heading(level: Int)
    case strong
    case emphasis
    case inlineCode
    case codeBlock
    case link
    case listMarker
    case blockquote

    /// Every kind, headings of each level included.
    public static let allCases: [MarkdownTokenKind] =
        (1...6).map { .heading(level: $0) } + [.strong, .emphasis, .inlineCode, .codeBlock, .link, .listMarker, .blockquote]

    /// The kind string of a `HighlightToken` or `LineToken`.
    public var kind: String {
        switch self {
        case .heading: "heading"
        case .strong: "strong"
        case .emphasis: "emphasis"
        case .inlineCode: "inlineCode"
        case .codeBlock: "codeBlock"
        case .link: "link"
        case .listMarker: "listMarker"
        case .blockquote: "blockquote"
        }
    }
    /// A heading carries its level as the modifier `level1` to `level6`.
    public var modifiers: [String] {
        if case .heading(let level) = self { return ["level\(level)"] }
        return []
    }
    public init?(kind: String, modifiers: [String]) {
        switch kind {
        case "heading":
            guard modifiers.count == 1, modifiers[0].hasPrefix("level"),
                  let level = Int(modifiers[0].dropFirst(5)), (1...6).contains(level) else { return nil }
            self = .heading(level: level); return
        case "strong": self = .strong
        case "emphasis": self = .emphasis
        case "inlineCode": self = .inlineCode
        case "codeBlock": self = .codeBlock
        case "link": self = .link
        case "listMarker": self = .listMarker
        case "blockquote": self = .blockquote
        default: return nil
        }
        guard modifiers.isEmpty else { return nil }
    }
    public init?(_ token: HighlightToken) { self.init(kind: token.kind, modifiers: token.modifiers) }
}

/// Tokenizes the Markdown constructs that help reading a draft, line by line. It does not
/// follow CommonMark beyond them.
///
/// Besides LF, the characters a regular expression treats as ending a line (VT, FF, NEL,
/// U+2028 and U+2029) start a new line here too, as they do in the editor's display.
///
/// A line starting with three backticks opens a fenced code block, and the next such line
/// closes it. An unclosed block runs to the end of the document, as in CommonMark. Inside a
/// block each line is one `codeBlock` token including its line break, so the whole block,
/// empty lines included, shares one style; the closing line's token covers its three
/// backticks only, and the rest of that line is tokenized as usual.
///
/// Other constructs lie within one line, detected in this order, where a construct
/// overlapping an earlier one is dropped: heading, blockquote, list marker, link, strong,
/// emphasis, inline code. Strong and emphasis do not look at the characters around their
/// markers, so markers between Japanese characters count.
public struct MarkdownTokenizer: LineTokenizer {
    public enum State: Hashable, Sendable {
        case text
        case codeBlock
    }

    public init() {}

    public var initialState: State { .text }

    public func tokenize(_ line: String, startingIn state: State) -> LineTokenization<State> {
        let units = Array(line.utf16)
        var length = units.count
        if length > 0, units[length - 1] == newline {
            length -= 1
            if length > 0, units[length - 1] == carriageReturn { length -= 1 }
        }
        var scanner = Scanner(units: units, length: length)
        var state = state
        // The starts of the lines within `line` whose text is tokenized as Markdown.
        var textLines: [Int] = []
        var start = 0
        while true {
            let end = scanner.lineEnd(from: start)
            let breakEnd = end < length ? end + 1 : units.count
            let fence = end - start >= 3 && units[start] == backtick && units[start + 1] == backtick && units[start + 2] == backtick
            switch (state, fence) {
            case (.text, false):
                textLines.append(start)
            case (.text, true), (.codeBlock, false):
                if breakEnd > start { scanner.accept(start..<breakEnd, .codeBlock) }
                state = .codeBlock
            case (.codeBlock, true):
                scanner.accept(start..<(start + 3), .codeBlock)
                textLines.append(start)
                state = .text
            }
            guard end < length else { break }
            start = end + 1
        }
        return LineTokenization(tokens: scanner.tokens(lineStarts: textLines), endState: state)
    }
}

private let newline: UInt16 = 0x0A
private let carriageReturn: UInt16 = 0x0D
private let backtick: UInt16 = 0x60
private let asterisk: UInt16 = 0x2A
private let space: UInt16 = 0x20
private let tab: UInt16 = 0x09

/// Finds the constructs within one line, as non-overlapping leftmost matches per construct.
private struct Scanner {
    let units: [UInt16]
    /// The end of the line's content, before its line break.
    let length: Int
    /// Whether each unit belongs to an accepted construct. Candidates of one construct do
    /// not overlap one another, so checking them stays linear in the line's length.
    private var claimed: [Bool]
    private var found: [LineToken] = []

    init(units: [UInt16], length: Int) {
        self.units = units; self.length = length
        claimed = Array(repeating: false, count: units.count)
    }

    mutating func accept(_ range: Range<Int>, _ kind: MarkdownTokenKind) {
        guard !claimed[range].contains(true) else { return }
        for index in range { claimed[index] = true }
        found.append(LineToken(range: range, kind: kind.kind, modifiers: kind.modifiers))
    }

    /// Line-start constructs are looked for at `lineStarts`, the others over the whole line.
    mutating func tokens(lineStarts: [Int]) -> [LineToken] {
        for start in lineStarts { heading(at: start) }
        for start in lineStarts { blockquote(at: start) }
        for start in lineStarts { listMarker(at: start) }
        link(); strong(); emphasis(); inlineCode()
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private func isBlank(_ index: Int) -> Bool { index < length && (units[index] == space || units[index] == tab) }
    private func skipBlanks(from index: Int) -> Int {
        var index = index
        while isBlank(index) { index += 1 }
        return index
    }
    private func isWhitespace(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit)?.properties.isWhitespace ?? false
    }
    /// The end of the line starting at `start`: the first character other than LF that ends
    /// a line, or the end of the content.
    func lineEnd(from start: Int) -> Int {
        units[start..<length].firstIndex { unit in
            switch unit {
            case 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: true
            default: false
            }
        } ?? length
    }
    /// The first index at or after `start` holding `unit`. Calls for one unit must not move
    /// backwards; the cached answer makes a scan over the line linear.
    private struct Search {
        let unit: UInt16
        var found = -1
        mutating func next(in units: ArraySlice<UInt16>, from start: Int) -> Int? {
            if found == units.endIndex { return nil }
            if found >= start { return found }
            found = units[max(start, units.startIndex)...].firstIndex(of: unit) ?? units.endIndex
            return found == units.endIndex ? nil : found
        }
    }

    // Blanks, `#`, `>`, digits and markers never end a line, so these scans stay on it.

    private mutating func heading(at start: Int) {
        var end = start
        while end < length, units[end] == 0x23 { end += 1 }
        guard (1...6).contains(end - start), isBlank(end) else { return }
        accept(start..<lineEnd(from: start), .heading(level: end - start))
    }

    private mutating func blockquote(at start: Int) {
        let marker = skipBlanks(from: start)
        guard marker < length, units[marker] == 0x3E else { return }
        accept(start..<lineEnd(from: start), .blockquote)
    }

    private mutating func listMarker(at lineStart: Int) {
        let start = skipBlanks(from: lineStart)
        guard start < length else { return }
        var end: Int
        if [0x2D, 0x2A, 0x2B].contains(units[start]) { end = start + 1 } else {
            end = start
            while let (scalar, size) = scalar(at: end), scalar.properties.generalCategory == .decimalNumber { end += size }
            guard end > start, end < length, units[end] == 0x2E else { return }
            end += 1
        }
        let blanks = skipBlanks(from: end)
        guard blanks > end else { return }
        accept(lineStart..<blanks, .listMarker)
    }

    private func scalar(at index: Int) -> (Unicode.Scalar, Int)? {
        guard index < length else { return nil }
        let unit = units[index]
        if UTF16.isLeadSurrogate(unit), index + 1 < length, UTF16.isTrailSurrogate(units[index + 1]) {
            return (UTF16.decode(UTF16.EncodedScalar([unit, units[index + 1]])), 2)
        }
        return Unicode.Scalar(unit).map { ($0, 1) }
    }

    /// `[label](destination)`, where neither part spans a `]` or `)` respectively.
    private mutating func link() {
        let content = units[..<length]
        var close = Search(unit: 0x5D), paren = Search(unit: 0x29)
        var index = 0
        while index < length {
            if units[index] == 0x5B, let end = close.next(in: content, from: index + 1),
               end + 1 < length, units[end + 1] == 0x28, let last = paren.next(in: content, from: end + 2) {
                accept(index..<(last + 1), .link)
                index = last + 1
            } else { index += 1 }
        }
    }

    /// `**text**`: not part of a longer run of asterisks, and the text neither starts nor
    /// ends with whitespace.
    private mutating func strong() {
        let content = units[..<length]
        var star = Search(unit: asterisk)
        var index = 0
        while index + 1 < length {
            if units[index] == asterisk, units[index + 1] == asterisk, index == 0 || units[index - 1] != asterisk,
               index + 2 < length, units[index + 2] != asterisk, !isWhitespace(units[index + 2]),
               let end = star.next(in: content, from: index + 2),
               end + 1 < length, units[end + 1] == asterisk, !isWhitespace(units[end - 1]),
               end + 2 >= length || units[end + 2] != asterisk {
                accept(index..<(end + 2), .strong)
                index = end + 2
            } else { index += 1 }
        }
    }

    /// `*text*`, under the same rules as strong.
    private mutating func emphasis() {
        let content = units[..<length]
        var star = Search(unit: asterisk)
        var index = 0
        while index < length {
            if units[index] == asterisk, index == 0 || units[index - 1] != asterisk,
               index + 1 < length, units[index + 1] != asterisk, !isWhitespace(units[index + 1]),
               let end = star.next(in: content, from: index + 1),
               !isWhitespace(units[end - 1]), end + 1 >= length || units[end + 1] != asterisk {
                accept(index..<(end + 1), .emphasis)
                index = end + 1
            } else { index += 1 }
        }
    }

    private mutating func inlineCode() {
        let content = units[..<length]
        var tick = Search(unit: backtick)
        var index = 0
        while index + 1 < length {
            if units[index] == backtick, units[index + 1] != backtick,
               let end = tick.next(in: content, from: index + 1) {
                accept(index..<(end + 1), .inlineCode)
                index = end + 1
            } else { index += 1 }
        }
    }
}
