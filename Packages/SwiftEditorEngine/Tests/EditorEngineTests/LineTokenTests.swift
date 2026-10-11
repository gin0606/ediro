import Testing
import EditorEngine
import Foundation

/// Records which lines a tokenizer was asked for.
final class TokenizerLog { var lines: [String] = [] }

/// `/*` opens a comment that runs across lines until `*/`. A line inside a comment is one
/// `comment` token including its line break; other lines are one `text` token without it.
struct CommentTokenizer: LineTokenizer {
    var log = TokenizerLog()
    var initialState: Bool { false }
    func tokenize(_ line: String, startingIn inComment: Bool) -> LineTokenization<Bool> {
        log.lines.append(line)
        let units = Array(line.utf16)
        var content = units.count
        while content > 0, units[content - 1] == 10 || units[content - 1] == 13 { content -= 1 }
        let text = String(decoding: units[..<content], as: UTF16.self)
        let opens = inComment || text.hasPrefix("/*")
        guard opens else { return LineTokenization(tokens: content == 0 ? [] : [LineToken(range: 0..<content, kind: "text")], endState: false) }
        let closes = text.dropFirst(inComment ? 0 : 2).contains("*/")
        return LineTokenization(tokens: units.isEmpty ? [] : [LineToken(range: 0..<units.count, kind: "comment", modifiers: ["block"])],
                                endState: !closes)
    }
}

@Suite(.serialized) @MainActor struct LineTokenTests {
    /// Tokens of a fresh document holding the same text, tokenized from scratch.
    func scratch(_ d: Document) throws -> [HighlightToken] {
        let fresh = Document(id: "scratch", text: d.snapshot.text, endOfLine: d.endOfLine, lineTokenizer: CommentTokenizer())
        return try fresh.lineTokens(in: 0..<fresh.snapshot.lineCount)
    }
    func all(_ d: Document) throws -> [HighlightToken] { try d.lineTokens(in: 0..<d.snapshot.lineCount) }
    /// Checks in every notification that the line tokens already match the text, and
    /// collects the reported lines.
    func watch(_ d: Document, into events: @escaping (DocumentEvent) -> Void = { _ in }) throws -> Subscription {
        try d.observe { event in
            #expect((try? all(d)) == (try? scratch(d)))
            #expect(event.changes.contains(.lineTokens) == !event.retokenizedLines.isEmpty)
            events(event)
        }
    }
    func tokenizer(_ log: TokenizerLog) -> CommentTokenizer { CommentTokenizer(log: log) }

    @Test func tokensUseDocumentPositionsAndCanCoverLineBreaks() throws {
        for eol in [EndOfLine.lf, .crlf] {
            let d = Document(id: "positions", text: "a\n/*b\nc*/\n\nd", endOfLine: eol, lineTokenizer: CommentTokenizer())
            #expect(try all(d) == [
                HighlightToken(range: TextRange(Position(0, 0), Position(0, 1)), kind: "text"),
                HighlightToken(range: TextRange(Position(1, 0), Position(2, 0)), kind: "comment", modifiers: ["block"]),
                HighlightToken(range: TextRange(Position(2, 0), Position(3, 0)), kind: "comment", modifiers: ["block"]),
                HighlightToken(range: TextRange(Position(4, 0), Position(4, 1)), kind: "text")
            ])
            #expect(try d.lineTokens(in: 2..<4) == [HighlightToken(range: TextRange(Position(2, 0), Position(3, 0)), kind: "comment", modifiers: ["block"])])
            #expect(try d.lineTokens(in: 3..<3).isEmpty)
            #expect(throws: EditorError.invalidRange) { try d.lineTokens(in: 4..<6) }
        }
        let plain = Document(id: "plain", text: "a\nb")
        #expect(try plain.lineTokens(in: 0..<2).isEmpty)
    }

    @Test func tokenizingStopsAtTheFirstLineEndingInItsPreviousState() throws {
        let log = TokenizerLog()
        let d = Document(id: "stop", text: (0..<10).map { "line \($0)" }.joined(separator: "\n"), lineTokenizer: tokenizer(log))
        #expect(log.lines.count == 10)
        var reported: [IndexSet] = []
        let s = try watch(d) { reported.append($0.retokenizedLines) }
        log.lines = []
        try d.apply([TextEdit(TextRange(Position(5, 4), Position(5, 4)), "!")])
        #expect(log.lines == ["line! 5\n"])
        #expect(reported == [IndexSet(integer: 5)])
        s.cancel()
    }

    @Test func statePropagatesAcrossLinesUntilItMatches() throws {
        let log = TokenizerLog()
        let d = Document(id: "propagate", text: (0..<10).map { "line \($0)" }.joined(separator: "\n"), lineTokenizer: tokenizer(log))
        var reported: [IndexSet] = []
        let s = try watch(d) { reported.append($0.retokenizedLines) }
        // Opening a comment restyles every line to the end of the document.
        try d.apply([TextEdit(TextRange(Position(2, 0), Position(2, 0)), "/*")])
        #expect(reported.last == IndexSet(integersIn: 2..<10))
        #expect(try all(d).filter { $0.kind == "comment" }.count == 8)
        // Closing it again stops at the line after the close, which ends as before the open.
        log.lines = []
        try d.apply([TextEdit(TextRange(Position(5, 6), Position(5, 6)), "*/")])
        #expect(reported.last == IndexSet(integersIn: 5..<10))
        try d.apply([TextEdit(TextRange(Position(2, 0), Position(2, 2)), "")])
        #expect(reported.last == IndexSet(integersIn: 2..<6))
        #expect(try all(d) == scratch(d))
        // An edit that keeps every state touches its own line only, even inside a comment.
        try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "/*")])
        try d.apply([TextEdit(TextRange(Position(3, 0), Position(3, 0)), "x")])
        #expect(reported.last == IndexSet(integer: 3))
        s.cancel()
    }

    @Test func linesKeepTheirStateAndTokensWhenLineBreaksAreInsertedOrRemoved() throws {
        for eol in [EndOfLine.lf, .crlf] {
            let log = TokenizerLog()
            let d = Document(id: "lines", text: "x\n/*\nc\n*/\ny\nz", endOfLine: eol, lineTokenizer: tokenizer(log))
            var reported: [IndexSet] = []
            let s = try watch(d) { reported.append($0.retokenizedLines) }
            // Inserted lines before the comment: only the edited lines are tokenized.
            log.lines = []
            try d.apply([TextEdit(TextRange(Position(0, 1), Position(0, 1)), "\n\n")])
            #expect(reported.last == IndexSet(integersIn: 0..<3))
            #expect(log.lines.count == 3)
            #expect(try all(d) == scratch(d))
            #expect(try d.lineTokens(in: 3..<4).first?.kind == "comment")
            // A line break inside the comment.
            try d.apply([TextEdit(TextRange(Position(4, 1), Position(4, 1)), "\n")])
            #expect(reported.last == IndexSet(integersIn: 4..<6))
            #expect(try all(d) == scratch(d))
            // Joining lines across the comment's start removes it from the lines after.
            try d.apply([TextEdit(TextRange(Position(2, 0), Position(4, 0)), "")])
            #expect(reported.last == IndexSet(integersIn: 2..<5))
            #expect(try all(d) == scratch(d))
            #expect(try all(d).allSatisfy { $0.kind == "text" })
            // Several edits in one batch, numbered in the text after the edit.
            try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "a\nb\n"),
                         TextEdit(TextRange(Position(3, 0), Position(4, 0)), "")])
            #expect(reported.last == IndexSet([0, 1, 2, 5]))
            #expect(try all(d) == scratch(d))
            s.cancel()
        }
    }

    @Test func undoAndRedoOfSeveralBatchesReportLinesInTheFinalText() throws {
        let d = Document(id: "history", text: (0..<10).map { "l\($0)" }.joined(separator: "\n"), lineTokenizer: CommentTokenizer())
        try d.apply([TextEdit(TextRange(Position(5, 0), Position(5, 0)), "/*")], historyGroup: "g")
        try d.apply([TextEdit(TextRange(Position(1, 0), Position(1, 0)), "\n\n")], historyGroup: "g")
        #expect(try all(d) == scratch(d))
        var events: [DocumentEvent] = []
        let s = try watch(d) { events.append($0) }
        try d.undo()
        #expect(events.last?.batches.count == 2)
        #expect(d.snapshot.text == (0..<10).map { "l\($0)" }.joined(separator: "\n"))
        // The second batch's inverse removes lines 2 and 3 first; the first batch's inverse
        // then restyles lines 5 to the end, where the comment had run.
        #expect(events.last?.retokenizedLines == IndexSet([1]).union(IndexSet(integersIn: 5..<10)))
        try d.redo()
        // The first batch restyles lines 5 to 9, which the second batch moves to 7 to 11.
        #expect(events.last?.retokenizedLines == IndexSet([1, 2, 3]).union(IndexSet(integersIn: 7..<12)))
        #expect(try d.lineTokens(in: 7..<8).first?.kind == "comment")
        try d.undo(); try d.redo()
        #expect(try all(d) == scratch(d))
        s.cancel()
    }

    @Test func compositionKeepsLineTokensCurrent() throws {
        let d = Document(id: "ime", text: "a\nb\nc", lineTokenizer: CommentTokenizer())
        let original = try all(d)
        let e = try EditorSession(document: d)
        var events: [DocumentEvent] = []
        let s = try watch(d) { events.append($0) }
        try e.beginComposition()
        try e.updateComposition("/*")
        #expect(events.last?.retokenizedLines == IndexSet(integersIn: 0..<3))
        #expect(try all(d).map(\.kind) == ["comment", "comment", "comment"])
        try e.updateComposition("/*\n")
        #expect(try all(d) == scratch(d))
        try e.cancelComposition()
        #expect(d.snapshot.text == "a\nb\nc")
        #expect(try all(d) == original)
        try e.beginComposition(); try e.updateComposition("/*"); try e.commitComposition()
        #expect(try all(d).map(\.kind) == ["comment", "comment", "comment"])
        try d.undo()
        #expect(try all(d) == original)
        try d.redo()
        #expect(try all(d) == scratch(d))
        // Cancelling from the document restores the tokens too.
        try e.beginComposition(); try e.updateComposition("x\n")
        try d.cancelActiveComposition()
        #expect(try all(d) == scratch(d))
        s.cancel()
    }

    @Test func providerTokensAndLineTokensAreIndependent() throws {
        let d = Document(id: "provider", text: "/*\nb", lineTokenizer: CommentTokenizer())
        let lineTokens = try all(d)
        let provided = HighlightToken(range: TextRange(Position(1, 0), Position(1, 1)), kind: "keyword")
        try d.setTokens([provided], version: d.snapshot.version)
        #expect(try all(d) == lineTokens)
        #expect(try d.semantics().tokens == [provided])
        try d.setTokens([], version: d.snapshot.version)
        #expect(try all(d) == lineTokens)
        try d.apply([TextEdit(TextRange(Position(1, 0), Position(1, 0)), "x")])
        #expect(try d.semantics().tokens.isEmpty)
    }

    @Test func settingATokenizerTokenizesTheWholeText() throws {
        let d = Document(id: "set", text: "a\n/*\nc")
        var events: [DocumentEvent] = []
        let s = try d.observe { events.append($0) }
        try d.setLineTokenizer(CommentTokenizer())
        #expect(events.last?.retokenizedLines == IndexSet(integersIn: 0..<3))
        #expect(try all(d).map(\.kind) == ["text", "comment", "comment"])
        try d.setLineTokenizer(nil)
        #expect(events.last?.retokenizedLines == IndexSet(integersIn: 0..<3))
        #expect(try all(d).isEmpty)
        try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "x")])
        #expect(events.last?.retokenizedLines == IndexSet())
        s.cancel()
        let blocked = try d.observe { _ in #expect(throws: EditorError.reentrantMutation) { try d.setLineTokenizer(CommentTokenizer()) } }
        try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "y")])
        blocked.cancel()
    }

    @Test func aTokenizerCannotWriteToItsDocument() throws {
        // Only the main actor touches it; the tokenizer runs there.
        final class Box: @unchecked Sendable { weak var document: Document?; var errors: [EditorError] = [] }
        struct Reentrant: LineTokenizer {
            let box: Box
            var initialState: Int { 0 }
            func tokenize(_ line: String, startingIn state: Int) -> LineTokenization<Int> {
                let box = box
                MainActor.assumeIsolated {
                    guard let d = box.document else { return }
                    do { try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "z")]) } catch let e as EditorError { box.errors.append(e) } catch {}
                    do { try d.setLineTokenizer(nil) } catch let e as EditorError { box.errors.append(e) } catch {}
                }
                return LineTokenization(tokens: [LineToken(range: 0..<line.utf16.count, kind: "line")], endState: 0)
            }
        }
        let box = Box()
        let d = Document(id: "reentrant", text: "a", lineTokenizer: Reentrant(box: box))
        box.document = d
        try d.apply([TextEdit(TextRange(Position(0, 1), Position(0, 1)), "b")])
        #expect(d.snapshot.text == "ab")
        #expect(box.errors == [.reentrantMutation, .reentrantMutation])
        #expect(try d.lineTokens(in: 0..<1) == [HighlightToken(range: TextRange(Position(0, 0), Position(0, 2)), kind: "line")])
    }

    @Test func workspaceTransactionsRetokenizeEachDocument() throws {
        let workspace = EditorWorkspace()
        let a = try workspace.createDocument(id: "a", text: "x\ny\nz")
        let b = try workspace.createDocument(id: "b", text: "p\nq")
        try a.setLineTokenizer(CommentTokenizer()); try b.setLineTokenizer(CommentTokenizer())
        var reportedA: [IndexSet] = [], reportedB: [IndexSet] = []
        let sa = try watch(a) { reportedA.append($0.retokenizedLines) }
        let sb = try watch(b) { reportedB.append($0.retokenizedLines) }
        try workspace.apply(WorkspaceEdit([
            DocumentEdits(snapshot: a.snapshot, edits: [TextEdit(TextRange(Position(0, 0), Position(0, 0)), "/*")]),
            DocumentEdits(snapshot: b.snapshot, edits: [TextEdit(TextRange(Position(1, 0), Position(1, 1)), "r")])
        ]))
        #expect(reportedA.last == IndexSet(integersIn: 0..<3))
        #expect(reportedB.last == IndexSet(integer: 1))
        try a.undo(); try b.undo()
        #expect(try all(a) == scratch(a)); #expect(try all(b) == scratch(b))
        sa.cancel(); sb.cancel()
        try workspace.dispose()
    }

    @Test func disposingReportsThatEveryLineLostItsTokens() throws {
        let d = Document(id: "dispose", text: "a\nb", lineTokenizer: CommentTokenizer())
        var events: [DocumentEvent] = []
        _ = try d.observe { events.append($0) }
        try d.dispose()
        #expect(events.last?.kind == .disposed)
        #expect(events.last?.retokenizedLines == IndexSet(integersIn: 0..<2))
        #expect(events.last?.changes.contains(.lineTokens) == true)
    }
}
