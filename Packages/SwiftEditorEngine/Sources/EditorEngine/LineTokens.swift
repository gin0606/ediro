import Foundation

/// A token within one line. `range` counts UTF-16 units of the line text passed to the
/// tokenizer, which includes the line's break, so a token can cover the break too.
public struct LineToken: Sendable, Equatable {
    public var range: Range<Int>
    public var kind: String
    public var modifiers: [String]
    public init(range: Range<Int>, kind: String, modifiers: [String] = []) {
        self.range = range; self.kind = kind; self.modifiers = modifiers
    }
}
/// The tokens of one line and the state the next line starts in.
public struct LineTokenization<State> {
    public var tokens: [LineToken]
    public var endState: State
    public init(tokens: [LineToken], endState: State) { self.tokens = tokens; self.endState = endState }
}
/// Tokenizes a document line by line, carrying a state from each line to the next, as
/// Monaco's tokenization support does. The document runs it synchronously on every edit,
/// starting at the first changed line and stopping once a line ends in the state it
/// ended in before, so it must be fast; language rules live in the conforming type.
public protocol LineTokenizer {
    associatedtype State: Equatable
    /// The state the first line starts in.
    var initialState: State { get }
    /// `line` is one line's text including its line break; the last line has none.
    /// Token ranges must lie within `line`, on boundaries the document accepts: not inside
    /// a surrogate pair or a CRLF break.
    func tokenize(_ line: String, startingIn state: State) -> LineTokenization<State>
}

struct AnyLineTokenizer {
    let initialState: Any
    let tokenize: (String, Any) -> (tokens: [LineToken], endState: Any)
    let equal: (Any, Any) -> Bool
    init<T: LineTokenizer>(_ tokenizer: T) {
        initialState = tokenizer.initialState
        tokenize = { line, state in
            let result = tokenizer.tokenize(line, startingIn: state as! T.State)
            return (result.tokens, result.endState)
        }
        equal = { $0 as! T.State == $1 as! T.State }
    }
}
struct LineEntry {
    /// The state the line ended in when last tokenized; nil for lines inserted since,
    /// which always need tokenizing.
    var endState: Any?
    var tokens: [LineToken]
    static var unknown: LineEntry { LineEntry(endState: nil, tokens: []) }
}

extension Document {
    /// Installs a line tokenizer, or removes it with nil, and tokenizes the whole text.
    public func setLineTokenizer(_ tokenizer: (any LineTokenizer)?) throws {
        try ensureMutable()
        let lines = IndexSet(integersIn: 0..<lineEntries.count)
        if let tokenizer { tokenizeAllLines(with: AnyLineTokenizer(tokenizer)) } else {
            lineTokenizer = nil; lineEntries = []
            retokenizedLines.formUnion(lines); if !lines.isEmpty { pendingChanges.insert(.lineTokens) }
        }
        emit(.semantics)
    }
    /// The line tokens of `lines`, with ranges in document positions. A token that covers a
    /// line break ends at the start of the next line. Empty without a line tokenizer.
    public func lineTokens(in lines: Range<Int>) throws -> [HighlightToken] {
        try ensureAlive()
        let snapshot = snapshot
        guard lines.lowerBound >= 0 && lines.upperBound <= snapshot.lineCount else { throw EditorError.invalidRange }
        guard lineTokenizer != nil else { return [] }
        var result: [HighlightToken] = []
        for line in lines {
            let length = try snapshot.lineEnd(line) - snapshot.lineStart(line)
            func position(_ column: Int) -> Position { column > length ? Position(line + 1, 0) : Position(line, column) }
            for token in lineEntries[line].tokens {
                result.append(HighlightToken(range: TextRange(position(token.range.lowerBound), position(token.range.upperBound)),
                                             kind: token.kind, modifiers: token.modifiers))
            }
        }
        return result
    }
    func tokenizeAllLines(with tokenizer: AnyLineTokenizer) {
        lineTokenizer = tokenizer
        lineEntries = Array(repeating: .unknown, count: snapshot.lineCount)
        tokenizeLines([(0, lineEntries.count - 1)])
        // No edit is under way, so work the tokenizer deferred can run now.
        Callbacks.finishIfIdle()
    }
    /// Keeps each line's entry with its line through `changes`, made to `old`, then
    /// tokenizes again from each changed line.
    func retokenizeLines(after changes: [ContentChange], in old: TextSnapshot) {
        guard lineTokenizer != nil else { return }
        // Splice from the last change so earlier line numbers stay valid. The replaced lines
        // become fresh entries, one per new line; the last keeps the end state of the last
        // replaced line, whose end the new last line inherits, so tokenizing can stop there.
        var spans: [(first: Int, added: Int, delta: Int)] = []
        for change in changes.reversed() {
            let first = try! old.position(at: change.offset).line
            let last = try! old.position(at: change.offset + change.removedLength).line
            let added = change.insertedText.utf16.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            var fresh = Array(repeating: LineEntry.unknown, count: added + 1)
            fresh[added].endState = lineEntries[last].endState
            lineEntries.replaceSubrange(first...last, with: fresh)
            // Earlier batches of the same operation reported lines numbered before this one.
            retokenizedLines.remove(integersIn: first...last)
            retokenizedLines.shift(startingAt: last + 1, by: added - (last - first))
            spans.append((first, added, added - (last - first)))
        }
        assert(lineEntries.count == snapshot.lineCount)
        var delta = 0
        let regions = spans.reversed().map { span -> (first: Int, last: Int) in
            defer { delta += span.delta }
            return (span.first + delta, span.first + delta + span.added)
        }
        tokenizeLines(regions)
    }
    /// Tokenizes every line of each region, given as new line numbers in ascending order,
    /// then continues until a line ends in the state stored for it.
    private func tokenizeLines(_ regions: [(first: Int, last: Int)]) {
        guard let tokenizer = lineTokenizer else { return }
        let snapshot = snapshot
        // The tokenizer is application code: writes to the document from it throw
        // `reentrantMutation`, as from other callbacks. Work deferred until callbacks finish
        // waits for the notification that follows, rather than running mid-edit here.
        lockDepth += 1; Callbacks.depth += 1
        defer { lockDepth -= 1; Callbacks.depth -= 1 }
        var next = 0
        while next < regions.count {
            let start = regions[next].first
            var line = start, reach = regions[next].last
            var state = line == 0 ? tokenizer.initialState : lineEntries[line - 1].endState!
            while line < lineEntries.count {
                while next < regions.count, regions[next].first <= line { reach = max(reach, regions[next].last); next += 1 }
                let lineStart = try! snapshot.lineStart(line)
                let lineEnd = line == lineEntries.count - 1 ? snapshot.utf16Count : try! snapshot.lineStart(line + 1)
                let contentEnd = try! snapshot.lineEnd(line)
                let result = tokenizer.tokenize(snapshot.string(in: lineStart..<lineEnd), state)
                let length = lineEnd - lineStart, content = contentEnd - lineStart
                func isBoundary(_ column: Int) -> Bool { column >= 0 && (column <= content || column == length) }
                for token in result.tokens {
                    precondition(isBoundary(token.range.lowerBound) && isBoundary(token.range.upperBound),
                                 "A line token lies outside its line or inside its line break")
                    // Checking surrogate pairs needs the text, so only debug builds do it.
                    assert((try? snapshot.validate(offset: lineStart + token.range.lowerBound)) != nil
                           && (try? snapshot.validate(offset: lineStart + token.range.upperBound)) != nil,
                           "A line token splits a surrogate pair")
                }
                let previous = lineEntries[line].endState
                lineEntries[line] = LineEntry(endState: result.endState, tokens: result.tokens)
                state = result.endState
                line += 1
                if line > reach, let previous, tokenizer.equal(previous, state) { break }
            }
            retokenizedLines.insert(integersIn: start..<line)
            pendingChanges.insert(.lineTokens)
        }
    }
}
