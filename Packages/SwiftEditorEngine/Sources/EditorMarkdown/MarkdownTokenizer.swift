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
/// Besides LF, the characters a regular expression treats as ending a line (VT, FF, CR,
/// NEL, U+2028 and U+2029) start a new line here too, as they do in the editor's display.
///
/// A line starting with three backticks opens a fenced code block, and the next such line
/// closes it. An unclosed block runs to the end of the document, as in CommonMark. Inside a
/// block each line is one `codeBlock` token including its line break, so the whole block,
/// empty lines included, shares one style; the closing line's token covers its three
/// backticks only, and the rest of that line is tokenized as usual.
///
/// Outside code blocks a line has at most one line-start construct: a heading or a
/// blockquote, whose token covers the whole line, or a list marker. The text after its
/// marker, or the whole line without one, holds inline constructs, which never span lines.
/// They are recognized in CommonMark's order of precedence:
///
/// 1. A backslash before ASCII punctuation makes that character literal.
/// 2. Inline code, from a run of backticks to the next run of the same length, makes the
///    characters inside literal. A run without one is literal itself.
/// 3. An autolink `<scheme:…>` makes the characters inside literal. It has no token.
/// 4. A link `[label](destination "title")`: the label may contain balanced brackets but no
///    link; the destination either has no spaces or controls and only balanced parentheses
///    or is enclosed in `<…>`; the title is optional.
/// 5. Strong `**text**` and emphasis `*text*`, whose text neither starts nor ends with
///    whitespace and holds no asterisk other than those the constructs above keep literal
///    or enclose, and whose markers are not part of a longer run of asterisks. They do not
///    look at the characters around their markers, so markers between Japanese characters
///    count. A pair never spans the boundary of inline code, an autolink or a link.
///
/// Tokens nest without crossing one another, and come in order of their start, an
/// enclosing token before the tokens inside it.
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
        var start = 0
        while true {
            let end = scanner.lineEnd(from: start)
            let breakEnd = end < length ? end + 1 : units.count
            let fence = end - start >= 3 && units[start] == backtick && units[start + 1] == backtick && units[start + 2] == backtick
            switch (state, fence) {
            case (.text, false):
                scanner.text(start..<end)
            case (.text, true), (.codeBlock, false):
                if breakEnd > start { scanner.add(start..<breakEnd, .codeBlock) }
                state = .codeBlock
            case (.codeBlock, true):
                scanner.add(start..<(start + 3), .codeBlock)
                scanner.inline(start + 3..<end)
                state = .text
            }
            guard end < length else { break }
            start = end + 1
        }
        return LineTokenization(tokens: scanner.sortedTokens(), endState: state)
    }
}

private let newline: UInt16 = 0x0A
private let carriageReturn: UInt16 = 0x0D
private let backtick: UInt16 = 0x60
private let asterisk: UInt16 = 0x2A
private let backslash: UInt16 = 0x5C
private let space: UInt16 = 0x20
private let tab: UInt16 = 0x09

/// Finds the constructs of the lines within one line of the document.
private struct Scanner {
    let units: [UInt16]
    /// The end of the content, before its line break.
    let length: Int
    private var tokens: [LineToken] = []

    init(units: [UInt16], length: Int) {
        self.units = units; self.length = length
    }

    mutating func add(_ range: Range<Int>, _ kind: MarkdownTokenKind) {
        tokens.append(LineToken(range: range, kind: kind.kind, modifiers: kind.modifiers))
    }

    /// The tokens by their start, a token before the tokens it encloses.
    func sortedTokens() -> [LineToken] {
        tokens.sorted {
            $0.range.lowerBound != $1.range.lowerBound
                ? $0.range.lowerBound < $1.range.lowerBound : $0.range.upperBound > $1.range.upperBound
        }
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

    private func isBlank(_ index: Int, before end: Int) -> Bool {
        index < end && (units[index] == space || units[index] == tab)
    }
    private func skipBlanks(from index: Int, before end: Int) -> Int {
        var index = index
        while isBlank(index, before: end) { index += 1 }
        return index
    }
    private func isWhitespace(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit)?.properties.isWhitespace ?? false
    }
    private func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit) || (0x5B...0x60).contains(unit)
            || (0x7B...0x7E).contains(unit)
    }
    /// Whether a backslash at `index` escapes the next character.
    func isEscape(_ index: Int, before end: Int) -> Bool {
        units[index] == backslash && index + 1 < end && isASCIIPunctuation(units[index + 1])
    }

    /// One line of text, `line` excluding its line break.
    mutating func text(_ line: Range<Int>) {
        let start = line.lowerBound, end = line.upperBound
        var hashes = start
        while hashes < end, units[hashes] == 0x23 { hashes += 1 }
        if (1...6).contains(hashes - start), isBlank(hashes, before: end) {
            add(line, .heading(level: hashes - start))
            inline(hashes..<end)
            return
        }
        let quote = skipBlanks(from: start, before: end)
        if quote < end, units[quote] == 0x3E {
            add(line, .blockquote)
            inline((quote + 1)..<end)
            return
        }
        if let marker = listMarkerEnd(in: line) {
            add(start..<marker, .listMarker)
            inline(marker..<end)
            return
        }
        inline(line)
    }

    /// The end of a list marker with the blanks after it at the start of `line`.
    private func listMarkerEnd(in line: Range<Int>) -> Int? {
        let end = line.upperBound
        let start = skipBlanks(from: line.lowerBound, before: end)
        guard start < end else { return nil }
        var marker: Int
        if [0x2D, 0x2A, 0x2B].contains(units[start]) { marker = start + 1 } else {
            marker = start
            while let (scalar, size) = scalar(at: marker, before: end), scalar.properties.generalCategory == .decimalNumber {
                marker += size
            }
            guard marker > start, marker < end, units[marker] == 0x2E else { return nil }
            marker += 1
        }
        let blanks = skipBlanks(from: marker, before: end)
        return blanks > marker ? blanks : nil
    }

    private func scalar(at index: Int, before end: Int) -> (Unicode.Scalar, Int)? {
        guard index < end else { return nil }
        let unit = units[index]
        if UTF16.isLeadSurrogate(unit), index + 1 < end, UTF16.isTrailSurrogate(units[index + 1]) {
            return (UTF16.decode(UTF16.EncodedScalar([unit, units[index + 1]])), 2)
        }
        return Unicode.Scalar(unit).map { ($0, 1) }
    }

    /// The inline constructs of `span`, which lies within one line. One pass from the left
    /// finds escapes, inline code, autolinks and links, as CommonMark does, and collects the
    /// asterisks outside them; asterisks then pair within the label of each link and
    /// within the rest of the span.
    mutating func inline(_ span: Range<Int>) {
        let end = span.upperBound
        var ticks: BacktickRuns?
        var destinations: Destinations?
        /// Asterisks that can be markers.
        var stars: [Int] = []
        var links: [(range: Range<Int>, label: Range<Int>)] = []
        /// The `[` that may still open a link, innermost last.
        var openers: [Int] = []
        var index = span.lowerBound
        while index < end {
            switch units[index] {
            case backslash where isEscape(index, before: end):
                index += 2
            case backtick:
                var run = index
                while run < end, units[run] == backtick { run += 1 }
                if ticks == nil { ticks = BacktickRuns(units: units, span: span) }
                if let close = ticks!.first(length: run - index, from: run) {
                    add(index..<(close + run - index), .inlineCode)
                    index = close + run - index
                } else { index = run }
            case 0x3C:
                index = autolinkEnd(from: index, before: end) ?? index + 1
            case asterisk:
                stars.append(index)
                index += 1
            case 0x5B:
                openers.append(index)
                index += 1
            case 0x5D:
                if let opener = openers.popLast(),
                   let tail = linkTailEnd(from: index + 1, before: end, destinations: &destinations) {
                    links.append((opener..<tail, (opener + 1)..<index))
                    add(opener..<tail, .link)
                    // A link contains no link, so no earlier bracket opens one any more.
                    openers.removeAll()
                    index = tail
                } else { index += 1 }
            default:
                index += 1
            }
        }

        // Links do not overlap and come in order, as do the asterisks.
        var outside: [Int] = []
        var inside: [Int] = []
        var link = 0
        for star in stars {
            while link < links.count, links[link].range.upperBound <= star {
                pair(inside); inside = []
                link += 1
            }
            if link < links.count, links[link].label.contains(star) { inside.append(star) } else { outside.append(star) }
        }
        pair(inside)
        pair(outside)
    }

    /// Pairs each run of asterisks with the next one, when both are `**` or both `*`, the
    /// text after the opening run does not start with whitespace and the text before the
    /// closing run does not end with it. `stars` are those of one link label, or those
    /// outside every link of a span.
    private mutating func pair(_ stars: [Int]) {
        var runs: [Range<Int>] = []
        for star in stars {
            if let last = runs.last, last.upperBound == star {
                runs[runs.count - 1] = last.lowerBound..<(star + 1)
            } else { runs.append(star..<(star + 1)) }
        }
        var run = 0
        while run + 1 < runs.count {
            let open = runs[run], close = runs[run + 1]
            if open.count == close.count, open.count <= 2,
               !isWhitespace(units[open.upperBound]), !isWhitespace(units[close.lowerBound - 1]) {
                add(open.lowerBound..<close.upperBound, open.count == 2 ? .strong : .emphasis)
                run += 2
            } else { run += 1 }
        }
    }

    /// The end of an autolink `<scheme:…>` starting at `start`: a scheme of 2 to 32 ASCII
    /// letters, digits, `+`, `.` or `-` starting with a letter, then characters other than
    /// spaces, controls, `<` and `>`.
    private func autolinkEnd(from start: Int, before end: Int) -> Int? {
        func isLetter(_ unit: UInt16) -> Bool { (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) }
        var index = start + 1
        guard index < end, isLetter(units[index]) else { return nil }
        index += 1
        while index < end, isLetter(units[index]) || (0x30...0x39).contains(units[index]) || [0x2B, 0x2E, 0x2D].contains(units[index]) {
            index += 1
        }
        guard (2...32).contains(index - start - 1), index < end, units[index] == 0x3A else { return nil }
        index += 1
        while index < end {
            switch units[index] {
            case 0x3E: return index + 1
            case 0...0x20, 0x7F, 0x3C: return nil
            default: index += 1
            }
        }
        return nil
    }

    /// The end of a link's `(destination "title")` starting at `start`. `destinations`
    /// serves every later link before `end`.
    private func linkTailEnd(from start: Int, before end: Int, destinations: inout Destinations?) -> Int? {
        guard start < end, units[start] == 0x28 else { return nil }
        var index = skipBlanks(from: start + 1, before: end)
        guard index < end else { return nil }
        if units[index] == 0x3C {
            // `<destination>`, which may contain spaces.
            index += 1
            while index < end, units[index] != 0x3E {
                if units[index] == 0x3C { return nil }
                index += isEscape(index, before: end) ? 2 : 1
            }
            guard index < end else { return nil }
            index += 1
        } else {
            if destinations == nil { destinations = Destinations(self, span: index..<end) }
            guard let destinationEnd = destinations!.end(from: index) else { return nil }
            index = destinationEnd
        }
        let destinationEnd = index
        index = skipBlanks(from: index, before: end)
        if index > destinationEnd, let title = linkTitleEnd(from: index, before: end) {
            index = skipBlanks(from: title, before: end)
        }
        guard index < end, units[index] == 0x29 else { return nil }
        return index + 1
    }

    /// The end of a link title `"…"`, `'…'` or `(…)` starting at `start`.
    private func linkTitleEnd(from start: Int, before end: Int) -> Int? {
        guard start < end else { return nil }
        let close: UInt16
        switch units[start] {
        case 0x22: close = 0x22
        case 0x27: close = 0x27
        case 0x28: close = 0x29
        default: return nil
        }
        var index = start + 1
        while index < end {
            if isEscape(index, before: end) { index += 2; continue }
            if units[index] == close { return index + 1 }
            if close == 0x29, units[index] == 0x28 { return nil }
            index += 1
        }
        return nil
    }

    /// Where destinations not enclosed in `<…>` end, for every start in a range. A
    /// destination ends at a space, a control or a `)` closing more than it opened; it is
    /// valid when its parentheses balance. Computing this once keeps trying every `](` of a
    /// line linear in its length.
    struct Destinations {
        private let lower: Int
        /// The `(` minus the `)` before each index, escaped ones excluded.
        private var depth: [Int]
        /// The first space or control at or after each index, or the range's end.
        private var stop: [Int]
        /// The first `)` at or after each index that closes more than opened since it.
        private var close: [Int]

        /// Escapes are taken from the range's start. `span` and every destination start
        /// after `(` or a blank, never after a backslash, so their escapes agree.
        init(_ scanner: Scanner, span: Range<Int>) {
            let units = scanner.units, count = span.count
            lower = span.lowerBound
            depth = Array(repeating: 0, count: count + 1)
            var index = span.lowerBound
            while index < span.upperBound {
                let offset = index - lower
                if scanner.isEscape(index, before: span.upperBound) {
                    depth[offset + 1] = depth[offset]; depth[offset + 2] = depth[offset]
                    index += 2
                    continue
                }
                depth[offset + 1] = depth[offset] + (units[index] == 0x28 ? 1 : units[index] == 0x29 ? -1 : 0)
                index += 1
            }
            stop = Array(repeating: span.upperBound, count: count + 1)
            close = Array(repeating: Int.max, count: count + 1)
            // The first index from which the depth after it is each level, offset by `count`.
            var reached = Array(repeating: Int.max, count: 2 * count + 2)
            for offset in stride(from: count - 1, through: 0, by: -1) {
                let unit = units[lower + offset]
                stop[offset] = unit <= 0x20 || unit == 0x7F ? lower + offset : stop[offset + 1]
                reached[depth[offset + 1] + count] = lower + offset
                // Depth changes by one at a time, so the first index after which it is one
                // below is the `)` that first closes more than it opened.
                close[offset] = depth[offset] + count - 1 >= 0 ? reached[depth[offset] + count - 1] : Int.max
            }
        }

        /// The end of the destination starting at `start`, or nil when its parentheses do
        /// not balance.
        func end(from start: Int) -> Int? {
            let offset = start - lower
            if close[offset] < stop[offset] { return close[offset] }
            return depth[stop[offset] - lower] == depth[offset] ? stop[offset] : nil
        }
    }

    /// The runs of backticks in a span by their length, to find where inline code closes in
    /// time linear in the span over all its openers.
    struct BacktickRuns {
        private var starts: [Int: [Int]] = [:]
        private var next: [Int: Int] = [:]

        init(units: [UInt16], span: Range<Int>) {
            var index = span.lowerBound
            while index < span.upperBound {
                guard units[index] == backtick else { index += 1; continue }
                let start = index
                while index < span.upperBound, units[index] == backtick { index += 1 }
                starts[index - start, default: []].append(start)
            }
        }

        /// The start of the first run of exactly `length` backticks at or after `position`.
        /// Calls for one length must not move backwards.
        mutating func first(length: Int, from position: Int) -> Int? {
            guard let list = starts[length] else { return nil }
            var cursor = next[length] ?? 0
            while cursor < list.count, list[cursor] < position { cursor += 1 }
            next[length] = cursor
            return cursor < list.count ? list[cursor] : nil
        }
    }
}
