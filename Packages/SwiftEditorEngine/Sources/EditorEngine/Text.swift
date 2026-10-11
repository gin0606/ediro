import Foundation

public enum EditorError: Error, Equatable, Sendable {
    case disposed, invalidPosition, invalidRange, invalidBoundary, overlappingEdits
    case staleVersion(expected: Int, actual: Int)
    case duplicateDocument, missingDocument(String), compositionActive, noComposition
    case noProvider, invalidProviderResult, staleResult, cancelled, invalidFoldingRanges
    case reentrantMutation
    /// The regular expression engine gave up, for example on exhausting its backtracking stack.
    case searchFailed
    /// The search query is not a valid regular expression.
    case invalidPattern
    /// The response holds no edits to apply, such as hover or tokens.
    case notApplicable
}

public struct Position: Hashable, Comparable, Sendable {
    public var line: Int
    public var column: Int
    public init(_ line: Int, _ column: Int) { self.line = line; self.column = column }
    public static func < (a: Self, b: Self) -> Bool {
        a.line == b.line ? a.column < b.column : a.line < b.line
    }
}

public struct TextRange: Hashable, Sendable {
    public var start: Position
    public var end: Position
    public init(_ start: Position, _ end: Position) { self.start = start; self.end = end }
    public var isEmpty: Bool { start == end }
}

public struct Selection: Hashable, Sendable {
    public var anchor: Position
    public var head: Position
    public init(anchor: Position, head: Position) { self.anchor = anchor; self.head = head }
    public init(_ position: Position) { self.init(anchor: position, head: position) }
    public var range: TextRange { TextRange(min(anchor, head), max(anchor, head)) }
    public var isEmpty: Bool { anchor == head }
}

public enum EndOfLine: String, Sendable { case lf = "\n", crlf = "\r\n" }

public struct TextEdit: Hashable, Sendable {
    public var range: TextRange
    public var text: String
    public init(_ range: TextRange, _ text: String) { self.range = range; self.text = text }
}

func normalized(_ text: String, eol: EndOfLine) -> String {
    let units = Array(text.utf16)
    var result: [UInt16] = []; result.reserveCapacity(units.count)
    var index = 0
    while index < units.count {
        let unit = units[index]
        if unit == 13 || unit == 10 {
            if unit == 13, index + 1 < units.count, units[index + 1] == 10 { index += 1 }
            if eol == .crlf { result.append(13) }
            result.append(10)
        } else { result.append(unit) }
        index += 1
    }
    return String(decoding: result, as: UTF16.self)
}

// All fields are immutable; snapshots safely share nodes across concurrency domains.
final class RopeNode: @unchecked Sendable {
    let left: RopeNode?
    let right: RopeNode?
    let units: [UInt16]
    let length: Int
    let newlines: Int
    let height: Int
    init(_ units: [UInt16]) {
        self.units = units; left = nil; right = nil
        length = units.count; newlines = units.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }; height = 1
    }
    init(_ left: RopeNode, _ right: RopeNode) {
        self.left = left; self.right = right; units = []
        length = left.length + right.length; newlines = left.newlines + right.newlines
        height = max(left.height, right.height) + 1
    }
    static func build(_ units: [UInt16]) -> RopeNode? {
        guard !units.isEmpty else { return nil }
        func buildSlice(_ lo: Int, _ hi: Int) -> RopeNode {
            if hi - lo <= 1024 { return RopeNode(Array(units[lo..<hi])) }
            let mid = (lo + hi) / 2
            return RopeNode(buildSlice(lo, mid), buildSlice(mid, hi))
        }
        return buildSlice(0, units.count)
    }
    static func join(_ a: RopeNode?, _ b: RopeNode?) -> RopeNode? {
        guard let a else { return b }; guard let b else { return a }
        if a.height > b.height + 1 { return balance(a.left!, join(a.right, b)!) }
        if b.height > a.height + 1 { return balance(join(a, b.left)!, b.right!) }
        if a.left == nil && b.left == nil && a.length + b.length <= 1024 {
            return RopeNode(a.units + b.units)
        }
        return RopeNode(a, b)
    }
    static func balance(_ a: RopeNode, _ b: RopeNode) -> RopeNode {
        if a.height > b.height + 1 {
            let l = a.left!, r = a.right!
            if l.height >= r.height { return RopeNode(l, RopeNode(r, b)) }
            return RopeNode(RopeNode(l, r.left!), RopeNode(r.right!, b))
        }
        if b.height > a.height + 1 {
            let l = b.left!, r = b.right!
            if r.height >= l.height { return RopeNode(RopeNode(a, l), r) }
            return RopeNode(RopeNode(a, l.left!), RopeNode(l.right!, r))
        }
        return RopeNode(a, b)
    }
    func split(_ offset: Int) -> (RopeNode?, RopeNode?) {
        if offset == 0 { return (nil, self) }
        if offset == length { return (self, nil) }
        guard let left, let right else {
            return (RopeNode(Array(units[..<offset])), RopeNode(Array(units[offset...])))
        }
        if offset < left.length {
            let (a,b) = left.split(offset); return (a, Self.join(b, right))
        }
        let (a,b) = right.split(offset - left.length); return (Self.join(left, a), b)
    }
    func unit(at offset: Int) -> UInt16 {
        guard let left, let right else { return units[offset] }
        return offset < left.length ? left.unit(at: offset) : right.unit(at: offset - left.length)
    }
    func collect(_ range: Range<Int>, into output: inout [UInt16]) {
        guard !range.isEmpty else { return }
        guard let left, let right else { output.append(contentsOf: units[range]); return }
        if range.lowerBound < left.length {
            left.collect(range.lowerBound..<min(range.upperBound, left.length), into: &output)
        }
        if range.upperBound > left.length {
            right.collect(max(0, range.lowerBound - left.length)..<(range.upperBound - left.length), into: &output)
        }
    }
    func newlineOffset(_ index: Int) -> Int {
        guard let left, let right else {
            var remaining = index
            for (i,u) in units.enumerated() where u == 10 {
                if remaining == 0 { return i }; remaining -= 1
            }
            preconditionFailure("Invalid newline index")
        }
        if index < left.newlines { return left.newlineOffset(index) }
        return left.length + right.newlineOffset(index - left.newlines)
    }
    func newlineCount(before offset: Int) -> Int {
        if offset == length { return newlines }
        guard let left, let right else { return units[..<offset].reduce(0) { $0 + ($1 == 10 ? 1 : 0) } }
        if offset <= left.length { return left.newlineCount(before: offset) }
        return left.newlines + right.newlineCount(before: offset - left.length)
    }
}

public struct TextSnapshot: Sendable {
    public let documentID: String
    let instanceID: UUID
    public let language: String
    public let version: Int
    public let endOfLine: EndOfLine
    let root: RopeNode?
    public var utf16Count: Int { root?.length ?? 0 }
    public var lineCount: Int { (root?.newlines ?? 0) + 1 }
    public var text: String { string(in: 0..<utf16Count) }
    func string(in range: Range<Int>) -> String {
        var units: [UInt16] = []; units.reserveCapacity(range.count)
        root?.collect(range, into: &units)
        return String(decoding: units, as: UTF16.self)
    }
    public func validate(offset: Int) throws {
        guard offset >= 0 && offset <= utf16Count else { throw EditorError.invalidPosition }
        if offset > 0 && offset < utf16Count {
            let a = root!.unit(at: offset - 1), b = root!.unit(at: offset)
            if (0xD800...0xDBFF).contains(a) && (0xDC00...0xDFFF).contains(b) || a == 13 && b == 10 {
                throw EditorError.invalidBoundary
            }
        }
    }
    func lineStart(_ line: Int) throws -> Int {
        guard line >= 0 && line < lineCount else { throw EditorError.invalidPosition }
        return line == 0 ? 0 : root!.newlineOffset(line - 1) + 1
    }
    func lineEnd(_ line: Int) throws -> Int {
        _ = try lineStart(line)
        return line == lineCount - 1 ? utf16Count : root!.newlineOffset(line) - (endOfLine == .crlf ? 1 : 0)
    }
    public func line(_ index: Int) throws -> String { string(in: try lineStart(index)..<lineEnd(index)) }
    public func offset(at position: Position) throws -> Int {
        let start = try lineStart(position.line), end = try lineEnd(position.line)
        guard position.column >= 0 && position.column <= end - start else { throw EditorError.invalidPosition }
        let offset = start + position.column; try validate(offset: offset); return offset
    }
    public func position(at offset: Int) throws -> Position {
        try validate(offset: offset)
        let line = root?.newlineCount(before: offset) ?? 0
        return Position(line, offset - (try lineStart(line)))
    }
    public func offsets(in range: TextRange) throws -> Range<Int> {
        guard range.start <= range.end else { throw EditorError.invalidRange }
        return try offset(at: range.start)..<offset(at: range.end)
    }
    public func text(in range: TextRange) throws -> String { string(in: try offsets(in: range)) }
    public var fullRange: TextRange { TextRange(Position(0,0), Position(lineCount - 1, utf16Count - (try! lineStart(lineCount - 1)))) }
}

public struct SearchOptions: Sendable {
    public var regularExpression: Bool
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public init(regularExpression: Bool = false, caseSensitive: Bool = true, wholeWord: Bool = false) {
        self.regularExpression = regularExpression; self.caseSensitive = caseSensitive; self.wholeWord = wholeWord
    }
}
public struct SearchMatch: Sendable, Equatable {
    public let range: TextRange
    public let captures: [String?]
}
func multilineRegex(_ pattern: String) -> Bool {
    let units = Array(pattern.utf16)
    var index = 0
    while index < units.count {
        if units[index] == 10 { return true }
        if units[index] == 92 {
            index += 1
            if index < units.count, [UInt16(110), 114, 87].contains(units[index]) { return true }
        }
        index += 1
    }
    return false
}
extension TextSnapshot {
    public func search(_ query: String, options: SearchOptions = .init(), in scope: TextRange? = nil) throws -> [SearchMatch] {
        try search(query, options: options, in: scope) { match, _, _, _ in match }
    }
    func search<Result>(_ query: String, options: SearchOptions, in scope: TextRange?,
                        mapMatch: (SearchMatch, NSRegularExpression, NSTextCheckingResult, String) -> Result) throws -> [Result] {
        let bounds = try offsets(in: scope ?? fullRange)
        if query.isEmpty { return [] }
        let pattern = options.regularExpression ? query : NSRegularExpression.escapedPattern(for: normalized(query, eol: .lf))
        // Only LF ends a logical line, so ^, $ and . ignore other Unicode line separators. In
        // this mode ICU's ^ also matches after a final line break, as the reference's does.
        var flags: NSRegularExpression.Options = [.anchorsMatchLines, .useUnixLineSeparators]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: pattern, options: flags) } catch { throw EditorError.invalidPattern }
        // As in the reference, whole-word search checks each match rather than rewriting the
        // pattern: an edge is a word boundary when the character beyond it or the match's own
        // character there is not a word character.
        func isWholeWord(_ range: NSRange, in units: [UInt16]) -> Bool {
            func isWord(_ scalar: Unicode.Scalar?) -> Bool {
                guard let scalar else { return false }
                if scalar == "_" { return true }
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber: return true
                default: return false
                }
            }
            func scalar(before i: Int) -> Unicode.Scalar? {
                guard i > 0 else { return nil }
                if i > 1, UTF16.isTrailSurrogate(units[i - 1]), UTF16.isLeadSurrogate(units[i - 2]) {
                    return UTF16.decode(UTF16.EncodedScalar([units[i - 2], units[i - 1]]))
                }
                return Unicode.Scalar(units[i - 1])
            }
            func scalar(at i: Int) -> Unicode.Scalar? {
                guard i < units.count else { return nil }
                if i + 1 < units.count, UTF16.isLeadSurrogate(units[i]), UTF16.isTrailSurrogate(units[i + 1]) {
                    return UTF16.decode(UTF16.EncodedScalar([units[i], units[i + 1]]))
                }
                return Unicode.Scalar(units[i])
            }
            let start = range.location, end = NSMaxRange(range), nonEmpty = range.length > 0
            return (!isWord(scalar(before: start)) || nonEmpty && !isWord(scalar(at: start)))
                && (!isWord(scalar(at: end)) || nonEmpty && !isWord(scalar(before: end)))
        }
        func matches(_ text: String, units: [UInt16], results: [NSTextCheckingResult], offset: (Int) -> Int) throws -> [Result] {
            try results.compactMap { result in
                if options.wholeWord, !isWholeWord(result.range, in: units) { return nil }
                let start = offset(result.range.location), end = offset(NSMaxRange(result.range))
                // Regex engines can match half a surrogate; such matches cannot be edited safely.
                guard (try? validate(offset: start)) != nil, (try? validate(offset: end)) != nil else { return nil }
                let captures = (0..<result.numberOfRanges).map { i -> String? in
                    let r = result.range(at: i)
                    return r.location == NSNotFound ? nil : (text as NSString).substring(with: r)
                }
                let match = SearchMatch(range: TextRange(try position(at: start), try position(at: end)), captures: captures)
                return mapMatch(match, regex, result, text)
            }
        }
        // The scope only limits where matches may lie. Anchors, word boundaries and
        // lookaround see the text around it, so ^ matches only at a real line start.
        let matching: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        // ICU reports giving up only through completion flags, and the matches found so far
        // would otherwise read as a complete result.
        func allMatches(in text: String, options: NSRegularExpression.MatchingOptions, range: NSRange) throws -> [NSTextCheckingResult] {
            var found: [NSTextCheckingResult] = [], failed = false
            regex.enumerateMatches(in: text, options: options.union(.reportCompletion), range: range) { result, flags, _ in
                if let result { found.append(result) }
                if flags.contains(.internalError) { failed = true }
            }
            if failed { throw EditorError.searchFailed }
            return found
        }
        if !options.regularExpression || multilineRegex(query) {
            // Search an LF-joined view, as the reference does, so a pattern's \n matches
            // every line break in CRLF documents too.
            var units: [UInt16] = [], breaks: [Int] = []
            for unit in text.utf16 where !(endOfLine == .crlf && unit == 13) {
                if unit == 10 { breaks.append(units.count) }
                units.append(unit)
            }
            let view = String(decoding: units, as: UTF16.self)
            // Each line break before an offset is one unit shorter in the view.
            func viewOffset(_ offset: Int) throws -> Int { endOfLine == .crlf ? offset - (try position(at: offset).line) : offset }
            let lower = try viewOffset(bounds.lowerBound), upper = try viewOffset(bounds.upperBound)
            let results = try allMatches(in: view, options: matching, range: NSRange(location: lower, length: upper - lower))
            return try matches(view, units: units, results: results) { location in
                guard endOfLine == .crlf else { return location }
                var low = 0, high = breaks.count
                while low < high { let mid = (low + high) / 2; if breaks[mid] < location { low = mid + 1 } else { high = mid } }
                return location + low
            }
        }
        // Match line-local expressions against each whole line without its EOL units,
        // including a trailing empty line.
        let first = try position(at: bounds.lowerBound).line, last = try position(at: bounds.upperBound).line
        var result: [Result] = []
        for line in first...last {
            let lineStart = try lineStart(line), lineEnd = try lineEnd(line)
            let start = max(bounds.lowerBound, lineStart), end = min(bounds.upperBound, lineEnd)
            let content = string(in: lineStart..<lineEnd)
            let found = try allMatches(in: content, options: matching, range: NSRange(location: start - lineStart, length: end - start))
            result += try matches(content, units: options.wholeWord ? Array(content.utf16) : [], results: found) { lineStart + $0 }
        }
        return result
    }
}
