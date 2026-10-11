import Testing
import EditorEngine
import Foundation

@Suite(.serialized) @MainActor struct SessionTests {
    @Test func sharedSessionsAndMultipleDirectedSelections() throws {
        let d = Document(id:"shared",text:"abc def")
        let a = try EditorSession(document:d), b = try EditorSession(document:d)
        try a.setSelections([Selection(anchor:Position(0,3),head:Position(0,0)),Selection(anchor:Position(0,4),head:Position(0,7))])
        try b.setSelections([Selection(Position(0,7))])
        var observed = false
        let subscription = try d.observe { event in
            if event.kind == .edit {
                observed = true
                #expect(d.snapshot.text == "X X")
                #expect(a.selections.map(\.head) == [Position(0,1),Position(0,3)])
                #expect(b.selections[0].head == Position(0,3))
            }
        }
        try a.type("X"); #expect(observed); subscription.cancel()
        try d.undo(); #expect(a.selections[0].anchor == Position(0,3)); #expect(b.selections[0].head == Position(0,7))
        try d.redo(); #expect(a.selections.count == 2)
        try a.setSelections([Selection(Position(0,1)),Selection(Position(0,1))]); #expect(a.selections.count == 1)
        try a.move(.backward,extendingSelection:true); #expect(a.selections[0].anchor == Position(0,1)); #expect(a.selections[0].head == Position(0,0))
    }
    @Test func graphemeMovementDeletionAndCRLF() throws {
        let d = Document(id:"graphemes",text:"e\u{301}👨‍👩‍👧‍👦\r\nx",endOfLine:.crlf)
        let e = try EditorSession(document:d)
        try e.move(.forward); #expect(e.selections[0].head == Position(0,2))
        try e.move(.forward); #expect(e.selections[0].head == Position(0,13))
        try e.move(.forward); #expect(e.selections[0].head == Position(1,0))
        try e.deleteBackward(); #expect(d.snapshot.lineCount == 1)
        try d.undo(); try e.move(.backward); try e.deleteBackward()
        #expect(d.snapshot.text == "e\u{301}\r\nx")
        try d.undo(); try e.move(.documentStart); try e.deleteForward()
        #expect(d.snapshot.text == "👨‍👩‍👧‍👦\r\nx")
        try e.dispose(); #expect(throws:EditorError.disposed) { try e.move(.forward) }
    }
    @Test func compositionCommitCancelAndExternalExclusion() throws {
        let d = Document(id:"ime",text:"abc")
        let a = try EditorSession(document:d), b = try EditorSession(document:d)
        try a.setSelections([Selection(anchor:Position(0,1),head:Position(0,2))])
        try a.beginComposition(); try a.updateComposition("に",markedSelection:0..<1)
        #expect(d.snapshot.text == "aにc"); #expect(a.markedRange == TextRange(Position(0,1),Position(0,2)))
        #expect(throws:EditorError.compositionActive) { try b.type("external") }
        #expect(throws:EditorError.compositionActive) { try d.undo() }
        #expect(throws:EditorError.invalidBoundary) { try a.updateComposition("😀",markedSelection:1..<1) }
        try b.setSelections([Selection(Position(0,3))])
        try a.updateComposition("日本"); try a.cancelComposition()
        #expect(d.snapshot.text == "abc"); #expect(!d.canUndo)
        #expect(a.selections[0].range == TextRange(Position(0,1),Position(0,2)))
        #expect(b.selections == [Selection(Position(0,3))])
        try a.beginComposition(); try a.updateComposition("に"); try a.commitComposition("日本")
        #expect(d.snapshot.text == "a日本c")
        try d.undo(); #expect(d.snapshot.text == "abc")
        try d.redo(); #expect(d.snapshot.text == "a日本c")
        try d.undo(); #expect(d.canRedo)
        try a.setSelections([Selection(anchor:Position(0,1),head:Position(0,2))])
        try a.beginComposition(); try a.updateComposition("k"); try a.commitComposition("b")
        #expect(d.snapshot.text == "abc"); #expect(!d.canUndo); #expect(d.canRedo)
        try d.redo(); #expect(d.snapshot.text == "a日本c")
        try a.setSelections([Selection(Position(0,3))]); try a.type("e\u{301}")
        try a.setSelections([Selection(anchor:Position(0,3),head:Position(0,5))])
        try a.beginComposition(); try a.commitComposition("\u{E9}")
        try d.undo(); #expect(d.snapshot.text.utf16.elementsEqual("a日本e\u{301}c".utf16))
        try d.undo(); #expect(d.snapshot.text == "a日本c")
        try a.beginComposition(); try a.updateComposition("仮"); try d.dispose()
        #expect(a.isDisposed && b.isDisposed)
        #expect(d.snapshot.text == "a日本c")
    }
    @Test func highlightTokensFollowEditsUntilTheNextResult() throws {
        let d = Document(id:"tokens",text:"one two")
        #expect(try d.semantics().tokensFreshness == .unavailable)
        let one = HighlightToken(range:TextRange(Position(0,0),Position(0,3)),kind:"first")
        let two = HighlightToken(range:TextRange(Position(0,4),Position(0,7)),kind:"second")
        try d.setTokens([one,two],version:d.version)
        let source = d.version
        try d.apply([TextEdit(TextRange(Position(0,1),Position(0,1)),"X"),TextEdit(TextRange(Position(0,4),Position(0,7)),"")])
        var view = try d.semantics()
        #expect(view.tokens.map(\.kind) == ["first"] && view.tokens[0].range == TextRange(Position(0,0),Position(0,4)))
        #expect(view.tokensFreshness == .stale(version:source))
        try d.setTokens([HighlightToken(range:TextRange(Position(0,0),Position(0,4)),kind:"fresh")],version:d.version)
        view = try d.semantics()
        #expect(view.tokens.map(\.kind) == ["fresh"] && view.tokensFreshness == .current)
    }
    @Test func rangeStickinessInvalidationAndFolding() throws {
        let d = Document(id:"ranges",text:"abcd\nsecond\nthird")
        let a = try EditorSession(document:d), b = try EditorSession(document:d)
        let decorations = [RangeStickiness.growBoth,.growNeither,.growBefore,.growAfter].map {
            Decoration(tracked:TrackedRange(range:TextRange(Position(0,1),Position(0,3)),stickiness:$0),style:"test")
        }
        try d.setDecorations(decorations)
        try d.setDiagnostics([Diagnostic(range:TextRange(Position(0,1),Position(0,3)),severity:.warning,message:"warning")],version:d.version)
        try d.setTokens([HighlightToken(range:TextRange(Position(0,0),Position(0,4)),kind:"word")],version:d.version)
        try d.setTokens([HighlightToken(range:TextRange(Position(0,0),Position(0,4)),kind:"variable")],semantic:true,version:d.version)
        try d.setInlayHints([InlayHint(position:Position(0,4),label:": String")],version:d.version)
        let fold = FoldingRange(range:TextRange(Position(0,0),Position(2,5)))
        try d.setFoldingRanges([fold],version:d.version)
        try a.setCollapsed(true,foldID:fold.id)
        #expect(try a.hiddenLineRanges() == [1..<3]); #expect(try b.hiddenLineRanges().isEmpty)
        try d.apply([TextEdit(TextRange(Position(0,1),Position(0,1)),"X"),TextEdit(TextRange(Position(0,3),Position(0,3)),"Y")])
        let view = try d.semantics(in:TextRange(Position(0,0),Position(0,6)))
        #expect(view.decorations.map { $0.tracked.range } == [TextRange(Position(0,1),Position(0,5)),TextRange(Position(0,2),Position(0,4)),TextRange(Position(0,1),Position(0,4)),TextRange(Position(0,2),Position(0,5))])
        let source = SemanticFreshness.stale(version: d.version - 1)
        #expect(view.diagnosticsFreshness == source && view.foldingRangesFreshness == source)
        #expect(view.tokensFreshness == source && view.semanticTokensFreshness == source)
        #expect(view.tokens.map(\.range) == [TextRange(Position(0,0),Position(0,6))])
        #expect(view.semanticTokens.map(\.range) == [TextRange(Position(0,0),Position(0,6))])
        #expect(view.inlayHints.isEmpty && view.inlayHintsFreshness == .unavailable)
        #expect(view.diagnostics[0].range == TextRange(Position(0,2),Position(0,4)))
        #expect(try a.hiddenLineRanges() == [1..<3])
        #expect(throws:EditorError.invalidFoldingRanges) {
            try d.setFoldingRanges([FoldingRange(range:TextRange(Position(0,0),Position(1,3))),FoldingRange(range:TextRange(Position(1,0),Position(2,2)))],version:d.version)
        }
        try d.apply([TextEdit(d.snapshot.fullRange,"")])
        #expect(try d.semantics().foldingRanges.isEmpty)
        #expect(a.collapsedFolds.isEmpty)
    }
    @Test func foldsNestByTheLinesTheyCover() throws {
        let d = Document(id: "lines", text: "# A\na\nb\n# B\nc\nd")
        let session = try EditorSession(document: d)
        // Heading folds that end where the next heading starts do not cover its line.
        let first = FoldingRange(range: TextRange(Position(0, 0), Position(3, 0)))
        let second = FoldingRange(range: TextRange(Position(3, 0), Position(5, 1)))
        try d.setFoldingRanges([first, second], version: d.version)
        try session.setCollapsed(true, foldID: first.id)
        #expect(try session.hiddenLineRanges() == [1..<3])
        // A fold starting on a line another fold ends on, outside it, would hide its own first line.
        #expect(throws: EditorError.invalidFoldingRanges) {
            try d.setFoldingRanges([FoldingRange(range: TextRange(Position(0, 0), Position(2, 1))),
                                    FoldingRange(range: TextRange(Position(2, 1), Position(4, 1)))], version: d.version)
        }
        #expect(throws: EditorError.invalidFoldingRanges) {
            try d.setFoldingRanges([FoldingRange(range: TextRange(Position(0, 0), Position(1, 0)))], version: d.version)
        }
        // Joining lines can make tracked folds share a line; the later one is dropped.
        let kept = FoldingRange(range: TextRange(Position(0, 0), Position(2, 1)))
        let joined = FoldingRange(range: TextRange(Position(3, 0), Position(5, 1)))
        try d.setFoldingRanges([kept, joined], version: d.version)
        try d.apply([TextEdit(TextRange(Position(2, 1), Position(3, 0)), "")])
        #expect(try d.semantics().foldingRanges.map(\.id) == [kept.id])
    }
    @Test func headingFoldsFollowTypingAtTheirEdges() throws {
        let d = Document(id: "headings", text: "# A\na\nb\n# B\nc\nd")
        let session = try EditorSession(document: d)
        let first = FoldingRange(range: TextRange(Position(0, 0), Position(3, 0)))
        let second = FoldingRange(range: TextRange(Position(3, 0), Position(5, 1)))
        try d.setFoldingRanges([first, second], version: d.version)
        try session.setCollapsed(true, foldID: first.id); try session.setCollapsed(true, foldID: second.id)
        // Typing at the start of the second heading leaves the first fold where it was.
        try session.setSelections([Selection(Position(3, 0))])
        try session.type("#")
        #expect(try d.semantics().foldingRanges.map(\.range) == [TextRange(Position(0, 0), Position(3, 0)), TextRange(Position(3, 1), Position(5, 1))])
        #expect(try session.hiddenLineRanges() == [1..<3, 4..<6])
        // Enter at the start of a heading moves its fold down with the heading line.
        try session.setSelections([Selection(Position(0, 0))])
        try session.type("\n")
        #expect(try d.semantics().foldingRanges.map(\.range) == [TextRange(Position(1, 0), Position(4, 0)), TextRange(Position(4, 1), Position(6, 1))])
        #expect(try session.hiddenLineRanges() == [2..<4, 5..<7])
        try session.setSelections([Selection(Position(4, 0))])
        try session.type("\n")
        #expect(try d.semantics().foldingRanges.map(\.range) == [TextRange(Position(1, 0), Position(4, 0)), TextRange(Position(5, 1), Position(7, 1))])
        #expect(session.collapsedFolds == [first.id, second.id])
    }
    @Test func collapseStateMovesToRebuiltFolds() throws {
        let d = Document(id: "rebuilt", text: "# A\na\na\n# B\nb\nb\nb\nc")
        let a = try EditorSession(document: d), b = try EditorSession(document: d)
        let lengths = d.snapshot.text.split(separator: "\n", omittingEmptySubsequences: false).map(\.utf16.count)
        // Each fold covers its last line up to the line's end.
        func fold(_ start: Int, _ end: Int) -> FoldingRange { FoldingRange(range: TextRange(Position(start, 0), Position(end, lengths[end]))) }
        func rebuild(_ folds: [FoldingRange]) throws { try d.setFoldingRanges(folds, version: d.version) }
        let first = fold(0, 2), second = fold(3, 5)
        try rebuild([first, second])
        try a.setCollapsed(true, foldID: first.id); try a.setCollapsed(true, foldID: second.id)
        try b.setCollapsed(true, foldID: second.id)
        // Fresh IDs at the same lines keep each session's state.
        try rebuild([fold(0, 2), fold(3, 5)])
        #expect(try a.hiddenLineRanges() == [1..<3, 4..<6]); #expect(try b.hiddenLineRanges() == [4..<6])
        // A fold whose end moved stays open only for the session whose caret it would hide.
        try a.setSelections([Selection(Position(7, 0))])
        try rebuild([fold(0, 2), fold(3, 7)])
        #expect(try a.hiddenLineRanges() == [1..<3]); #expect(try b.hiddenLineRanges() == [4..<8])
        // Without a fold at the same lines, the outermost one starting on the same line takes the state.
        try rebuild([fold(0, 2), fold(3, 6), fold(3, 5)])
        #expect(try b.hiddenLineRanges() == [4..<7])
        // A collapsed fold without a replacement opens.
        try rebuild([fold(0, 2)])
        #expect(try a.hiddenLineRanges() == [1..<3]); #expect(b.collapsedFolds.isEmpty)
    }
    @Test func layoutDelegatesWrappedMovementAndHitTesting() throws {
        struct Layout: LayoutAdapter {
            func moveVertically(from p:Position,direction:VerticalDirection,preferredAdvance:Double?,snapshot:TextSnapshot) throws -> LayoutMovement {
                // Two visual rows on a single logical line, with variable advances.
                let goal = preferredAdvance ?? Double(p.column) * 1.7
                return LayoutMovement(position:Position(0,direction == .down ? 4 : 1),preferredAdvance:goal)
            }
            func position(at display:DisplayPosition,snapshot:TextSnapshot) throws -> Position { Position(0,display.row == 0 ? 1 : 4) }
            func displayPosition(at p:Position,snapshot:TextSnapshot) throws -> DisplayPosition { DisplayPosition(row:p.column < 3 ? 0 : 1,advance:Double(p.column) * 1.7) }
        }
        let e = try EditorSession(document:Document(id:"layout",text:"abcdef"))
        #expect(throws:EditorError.invalidPosition) { try e.move(.down) }
        try e.setLayout(Layout()); try e.move(.down); #expect(e.selections[0].head == Position(0,4))
        try e.move(.up,extendingSelection:true); #expect(e.selections[0].range == TextRange(Position(0,1),Position(0,4)))
        try e.select(at:DisplayPosition(row:1,advance:200)); #expect(e.selections[0].head == Position(0,4))
    }
    @Test func noOpTypingResetsThePreferredAdvance() throws {
        final class Layout: LayoutAdapter {
            var received: [Double?] = []
            func moveVertically(from p:Position,direction:VerticalDirection,preferredAdvance:Double?,snapshot:TextSnapshot) throws -> LayoutMovement {
                received.append(preferredAdvance)
                return LayoutMovement(position:Position(direction == .down ? 1 : 0,p.column),preferredAdvance:Double(p.column))
            }
            func position(at display:DisplayPosition,snapshot:TextSnapshot) throws -> Position { Position(0,0) }
            func displayPosition(at p:Position,snapshot:TextSnapshot) throws -> DisplayPosition { DisplayPosition(row:p.line,advance:0) }
        }
        let layout = Layout()
        let e = try EditorSession(document:Document(id:"goal",text:"abc\nabc"))
        try e.setLayout(layout); try e.setSelections([Selection(Position(0,2))])
        try e.move(.down,extendingSelection:true)
        try e.type(try e.document.snapshot.text(in:e.selections[0].range))
        try e.move(.up)
        #expect(layout.received == [nil,nil])
    }
    @Test func replacePlacesTheGivenSelectionsAndHistoryRestoresThem() throws {
        let d = Document(id:"replace",text:"abcd\naaaa")
        let e = try EditorSession(document:d)
        try e.setSelections([Selection(Position(0,1)),Selection(Position(0,3)),Selection(Position(1,1))],primary:2)
        // Touching edits merge into one change, and the last one changes nothing.
        try e.replace([TextEdit(TextRange(Position(0,0),Position(0,2)),"ba"),TextEdit(TextRange(Position(0,2),Position(0,4)),"dc"),
            TextEdit(TextRange(Position(1,0),Position(1,2)),"aa")],selecting:[(2,2),(4,4),(7,7)])
        #expect(d.snapshot.text == "badc\naaaa")
        #expect(e.selections.map(\.head) == [Position(0,2),Position(0,4),Position(1,2)]); #expect(e.primaryIndex == 2)
        try d.undo(); #expect(d.snapshot.text == "abcd\naaaa")
        #expect(e.selections.map(\.head) == [Position(0,1),Position(0,3),Position(1,1)])
        try d.redo(); #expect(e.selections.map(\.head) == [Position(0,2),Position(0,4),Position(1,2)]); #expect(e.primaryIndex == 2)
        // Edits that change nothing still place the selections.
        try e.replace([TextEdit(TextRange(Position(1,0),Position(1,2)),"aa")],selecting:[(1,0),(4,4),(9,9)])
        #expect(e.selections == [Selection(anchor:Position(0,1),head:Position(0,0)),Selection(Position(0,4)),Selection(Position(1,4))])
        #expect(throws: EditorError.invalidRange) { try e.replace([],selecting:[(0,0)]) }
        try e.beginComposition(); try e.updateComposition("x")
        let composed = d.snapshot.text, selections = e.selections
        #expect(throws: EditorError.compositionActive) {
            try e.replace([TextEdit(TextRange(Position(0,0),Position(0,1)),"")],selecting:[(0,0),(3,3),(8,8)])
        }
        #expect(d.snapshot.text == composed); #expect(e.selections == selections); try e.cancelComposition()
    }
    @Test func layoutFailureRestoresMutationAccess() throws {
        enum Failure: Error { case layout }
        struct Layout: LayoutAdapter {
            func moveVertically(from position: Position, direction: VerticalDirection,
                                preferredAdvance: Double?, snapshot: TextSnapshot) throws -> LayoutMovement { throw Failure.layout }
            func position(at display: DisplayPosition, snapshot: TextSnapshot) throws -> Position { throw Failure.layout }
            func displayPosition(at position: Position, snapshot: TextSnapshot) throws -> DisplayPosition { throw Failure.layout }
        }
        let document = Document(id: "layout failure", text: "abc")
        let session = try EditorSession(document: document)
        try session.setLayout(Layout())
        #expect(throws: Failure.layout) { try session.move(.down) }
        #expect(throws: Failure.layout) { try session.select(at: DisplayPosition(row: 1, advance: 1)) }
        #expect(session.selections == [Selection(Position(0, 0))])
        try session.type("x")
        #expect(document.snapshot.text == "xabc")
    }
    @Test func mixedHistoryAndSelectionsAgainstFlatReference() throws {
        struct Change {
            let offset: Int
            let removed: [UInt16]
            let inserted: [UInt16]
            let before: [[Int]]
            let after: [[Int]]
        }
        var seed: UInt64 = 0xa61d
        func random(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(count))
        }
        for eol in [EndOfLine.lf, .crlf] {
            var units = Array(("ab😀" + eol.rawValue + "e\u{301}" + eol.rawValue + "xyz").utf16)
            let document = Document(id: "mixed", text: String(decoding: units, as: UTF16.self), endOfLine: eol)
            let sessions = try [EditorSession(document: document), EditorSession(document: document)]
            var selections = [[0, 0], [0, 0]]
            // A reference, because the main-actor observer below reads it after later changes.
            final class Marker { var offsets = [1, 4] }
            let marker = Marker()
            let markerID = try document.trackRange(TextRange(Position(0, 1), Position(0, 4)), stickiness: .growBoth)
            var undo: [Change] = [], redo: [Change] = []
            func position(_ offset: Int) -> Position {
                var line = 0, column = 0
                for unit in units.prefix(offset) {
                    if unit == 10 { line += 1; column = 0 } else { column += 1 }
                }
                return Position(line, column)
            }
            func legalOffsets() -> [Int] {
                (0...units.count).filter { i in
                    i == 0 || i == units.count ||
                    !((0xD800...0xDBFF).contains(units[i - 1]) && (0xDC00...0xDFFF).contains(units[i]) ||
                      units[i - 1] == 13 && units[i] == 10)
                }
            }
            func replace(_ offset: Int, _ count: Int, _ replacement: [UInt16]) {
                func follow(_ point: Int, includeInsertion: Bool) -> Int {
                    if point < offset { return point }
                    if point > offset + count { return point - count + replacement.count }
                    if count > 0 && point == offset + count { return offset + replacement.count }
                    if count > 0 && point == offset { return offset }
                    return offset + (includeInsertion ? 0 : replacement.count)
                }
                selections = selections.map { $0.map { follow($0, includeInsertion: false) } }
                marker.offsets = [follow(marker.offsets[0], includeInsertion: true), follow(marker.offsets[1], includeInsertion: false)]
                units.replaceSubrange(offset..<(offset + count), with: replacement)
            }
            var notifications = 0
            let observation = try document.observe { _ in
                notifications += 1
                do {
                    #expect(Array(document.snapshot.text.utf16) == units)
                    for offset in legalOffsets() {
                        #expect(try document.snapshot.position(at: offset) == position(offset))
                        #expect(try document.snapshot.offset(at: position(offset)) == offset)
                    }
                    for (session, expected) in zip(sessions, selections) {
                        #expect(session.selections == [Selection(anchor: position(expected[0]), head: position(expected[1]))])
                    }
                    let expectedMarker = TextRange(position(marker.offsets[0]), position(marker.offsets[1]))
                    #expect(try document.trackedRange(id: markerID)?.range == expectedMarker)
                    _ = try document.snapshot.offsets(in: try #require(document.trackedRange(id: markerID)?.range))
                } catch { Issue.record("Invalid observed state: \(error)") }
            }
            let inputs = ["x", "😀", eol.rawValue, "e\u{301}", "", "👨‍👩‍👧‍👦"]
            for _ in 0..<240 {
                switch random(5) {
                case 0, 1:
                    let owner = random(2), typing = random(2) == 0
                    let boundaries = legalOffsets()
                    let a = typing ? selections[owner].min()! : boundaries[random(boundaries.count)]
                    let b = typing ? selections[owner].max()! : boundaries[random(boundaries.count)]
                    let start = min(a, b), end = max(a, b)
                    let range = TextRange(position(start), position(end))
                    let text = inputs[random(inputs.count)], inserted = Array(text.utf16)
                    let removed = Array(units[start..<end]), before = selections
                    if removed != inserted {
                        replace(start, end - start, inserted)
                        if typing { selections[owner] = [start + inserted.count, start + inserted.count] }
                        undo.append(Change(offset: start, removed: removed, inserted: inserted, before: before, after: selections))
                        redo = []
                    } else if typing { selections[owner] = [end, end] }
                    if typing { try sessions[owner].type(text) }
                    else { try document.apply([TextEdit(range, text)]) }
                case 2:
                    if let change = undo.popLast() {
                        replace(change.offset, change.inserted.count, change.removed)
                        selections = change.before; redo.append(change)
                    }
                    try document.undo()
                case 3:
                    if let change = redo.popLast() {
                        replace(change.offset, change.removed.count, change.inserted)
                        selections = change.after; undo.append(change)
                    }
                    try document.redo()
                default:
                    let owner = random(2), boundaries = legalOffsets()
                    selections[owner] = [boundaries[random(boundaries.count)], boundaries[random(boundaries.count)]]
                    try sessions[owner].setSelections([Selection(anchor: position(selections[owner][0]), head: position(selections[owner][1]))])
                }
                #expect(document.canUndo == !undo.isEmpty && document.canRedo == !redo.isEmpty)
                #expect(Array(document.snapshot.text.utf16) == units)
            }
            #expect(notifications > 100)
            observation.cancel(); try document.dispose()
        }
    }
    @Test func workDeferredByLayoutRunsAfterTheSelectionIsInstalled() throws {
        struct Layout: LayoutAdapter {
            let callback: () -> Void
            func moveVertically(from position: Position, direction: VerticalDirection,
                                preferredAdvance: Double?, snapshot: TextSnapshot) throws -> LayoutMovement {
                callback(); return LayoutMovement(position: Position(0, 2), preferredAdvance: 2)
            }
            func position(at display: DisplayPosition, snapshot: TextSnapshot) throws -> Position { callback(); return Position(0, 2) }
            func displayPosition(at position: Position, snapshot: TextSnapshot) throws -> DisplayPosition { DisplayPosition(row: 0, advance: 2) }
        }
        for hitTest in [false, true] {
            let workspace = EditorWorkspace()
            let document = try workspace.createDocument(id: "moving", text: "abc", language: "md")
            let other = try workspace.createDocument(id: "other", text: "", language: "swift")
            let session = try EditorSession(document: document)
            let registration = try workspace.register(language: "swift", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
            // The unregistration notifies the other document, whose listener replaces this document's text.
            let observation = try other.observe { event in
                guard event.kind == .language else { return }
                #expect(session.selections == [Selection(Position(0, 2))])
                _ = try? document.apply([TextEdit(document.snapshot.fullRange, "")])
            }
            try session.setLayout(Layout { registration.cancel() })
            if hitTest { try session.select(at: DisplayPosition(row: 0, advance: 2)) } else { try session.move(.down) }
            #expect(document.snapshot.text == "" && session.selections == [Selection(Position(0, 0))])
            observation.cancel(); try workspace.dispose()
        }
    }
    @Test func layoutCallbacksProtectTheSnapshotAndSession() throws {
        struct Layout: LayoutAdapter {
            let callback: () throws -> Void
            func moveVertically(from position: Position, direction: VerticalDirection,
                                preferredAdvance: Double?, snapshot: TextSnapshot) throws -> LayoutMovement {
                try callback()
                return LayoutMovement(position: Position(0, 2), preferredAdvance: 2)
            }
            func position(at display: DisplayPosition, snapshot: TextSnapshot) throws -> Position {
                try callback(); return Position(0, 2)
            }
            func displayPosition(at position: Position, snapshot: TextSnapshot) throws -> DisplayPosition {
                DisplayPosition(row: 0, advance: 2)
            }
        }
        for hitTest in [false, true] {
            let document = Document(id: "layout", text: "abc")
            let session = try EditorSession(document: document)
            try session.setLayout(Layout {
                #expect(throws: EditorError.reentrantMutation) {
                    try document.apply([TextEdit(document.snapshot.fullRange, "")])
                }
                #expect(throws: EditorError.reentrantMutation) { try session.dispose() }
                #expect(throws: EditorError.reentrantMutation) { try session.setSelections([Selection(Position(0, 1))]) }
            })
            if hitTest { try session.select(at: DisplayPosition(row: 0, advance: 2)) }
            else { try session.move(.down) }
            #expect(document.snapshot.text == "abc" && !session.isDisposed)
            #expect(session.selections == [Selection(Position(0, 2))])
            try session.type("x")
            #expect(document.snapshot.text == "abxc")
        }
    }
    @Test func trackedFoldsKeepValidNestingAfterSpanningReplacements() throws {
        let document = Document(id: "folds", text: Array(repeating: "a", count: 10).joined(separator: "\n"))
        let first = FoldingRange(range: TextRange(Position(0, 0), Position(2, 1)))
        let second = FoldingRange(range: TextRange(Position(4, 0), Position(6, 1)))
        let unaffected = FoldingRange(range: TextRange(Position(7, 0), Position(9, 1)))
        try document.setFoldingRanges([first, second, unaffected], version: document.version)
        let session = try EditorSession(document: document)
        try session.setCollapsed(true, foldID: second.id)
        try document.apply([TextEdit(TextRange(Position(1, 0), Position(5, 0)), "x\ny\nz\n")])
        // The first fold's end collapses to the replacement start, leaving it on one line.
        let folds = try document.semantics().foldingRanges
        #expect(folds.map(\.id) == [second.id, unaffected.id])
        #expect(folds.first?.range == TextRange(Position(4, 0), Position(5, 1)))
        #expect(try session.hiddenLineRanges() == [5..<6])
        try document.setFoldingRanges(folds, version: document.version)
        try document.undo()
        try document.setFoldingRanges(try document.semantics().foldingRanges, version: document.version)
        try document.redo()
        try document.setFoldingRanges(try document.semantics().foldingRanges, version: document.version)
        try session.dispose()
    }
    @Test func eventBatchesReplayToTheNewText() throws {
        for eol in [EndOfLine.lf, .crlf] {
            let workspace = EditorWorkspace()
            let d = try workspace.createDocument(id: "replay", text: "ab\ncd\nef", endOfLine: eol)
            let session = try EditorSession(document: d)
            var replayed = Array(d.snapshot.text.utf16), events = 0
            // Each batch uses offsets in the text before it, so its changes apply from the end.
            let observation = try d.observe { event in
                events += 1
                for batch in event.batches {
                    for change in batch.reversed() {
                        replayed.replaceSubrange(change.offset..<(change.offset + change.removedLength), with: Array(change.insertedText.utf16))
                    }
                }
                #expect(replayed == Array(d.snapshot.text.utf16))
            }
            try session.setSelections([Selection(Position(0, 1)), Selection(anchor: Position(1, 0), head: Position(2, 1))])
            try session.type("X\n")
            try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "1")], historyGroup: "g")
            try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 1)), "2"), TextEdit(TextRange(Position(1, 0), Position(1, 0)), "3")], historyGroup: "g")
            try d.undo(); try d.undo(); try d.redo(); try d.redo()
            try session.setSelections([Selection(Position(0, 0))])
            try session.beginComposition(); try session.updateComposition("あ"); try session.updateComposition("あい\n"); try session.cancelComposition()
            try session.beginComposition(); try session.updateComposition("う"); try session.commitComposition("え")
            try workspace.apply(WorkspaceEdit([DocumentEdits(documentID: d.id, expectedVersion: d.version,
                edits: [TextEdit(TextRange(Position(0, 0), Position(1, 0)), ""), TextEdit(TextRange(Position(2, 0), Position(2, 1)), "Z")])]))
            try d.undo()
            #expect(events > 10)
            observation.cancel(); try workspace.dispose()
        }
    }
    @Test func preferredAdvancesCarryAcrossVerticalMovesUntilAnotherChange() throws {
        final class Layout: LayoutAdapter {
            var received: [Double?] = []
            func moveVertically(from position: Position, direction: VerticalDirection,
                                preferredAdvance: Double?, snapshot: TextSnapshot) throws -> LayoutMovement {
                received.append(preferredAdvance)
                let line = min(max(position.line + (direction == .down ? 1 : -1), 0), snapshot.fullRange.end.line)
                return LayoutMovement(position: Position(line, 0), preferredAdvance: Double(10 + received.count))
            }
            func position(at display: DisplayPosition, snapshot: TextSnapshot) throws -> Position { Position(0, 0) }
            func displayPosition(at position: Position, snapshot: TextSnapshot) throws -> DisplayPosition { DisplayPosition(row: 0, advance: 0) }
        }
        let d = Document(id: "advances", text: "abc\nd\nefg\nh\ni")
        let session = try EditorSession(document: d), layout = Layout()
        try session.setLayout(layout)
        try session.move(.down); try session.move(.down)
        try session.move(.forward); try session.move(.down)
        try session.setSelections([Selection(Position(0, 0))]); try session.move(.down)
        try session.type("x"); try session.move(.down)
        try session.move(.up)
        #expect(layout.received == [nil, 11, nil, nil, nil, 15])
    }
    @Test func semanticQueriesKeepItemsTouchingTheRange() throws {
        let d = Document(id: "query", text: "abcdef\nghijkl\nmnopqr")
        func range(_ a: Int, _ b: Int, _ c: Int, _ e: Int) -> TextRange { TextRange(Position(a, b), Position(c, e)) }
        try d.setTokens([HighlightToken(range: range(0, 0, 0, 2), kind: "before"), HighlightToken(range: range(0, 2, 0, 4), kind: "touching"),
                         HighlightToken(range: range(1, 0, 1, 2), kind: "inside"), HighlightToken(range: range(2, 3, 2, 5), kind: "after")], version: d.version)
        try d.setDiagnostics([Diagnostic(range: range(0, 0, 0, 1), severity: .error, message: "before"),
                              Diagnostic(range: range(2, 1, 2, 2), severity: .error, message: "end")], version: d.version)
        try d.setDecorations([Decoration(tracked: TrackedRange(range: range(2, 2, 2, 3)), style: "after")])
        try d.setFoldingRanges([FoldingRange(range: range(1, 0, 2, 6))], version: d.version)
        try d.setInlayHints([InlayHint(position: Position(0, 1), label: "before"), InlayHint(position: Position(0, 4), label: "start")], version: d.version)
        let view = try d.semantics(in: range(0, 4, 2, 1))
        #expect(view.tokens.map(\.kind) == ["touching", "inside"])
        #expect(view.diagnostics.map(\.message) == ["end"])
        #expect(view.decorations.isEmpty)
        #expect(view.foldingRanges.count == 1)
        #expect(view.inlayHints.map(\.label) == ["start"])
    }
    @Test func semanticSettersRejectStaleOrInvalidInputWithoutChangingData() throws {
        let d = Document(id: "setters", text: "abc\ndef")
        let token = HighlightToken(range: TextRange(Position(0, 0), Position(0, 1)), kind: "word")
        let diagnostic = Diagnostic(range: TextRange(Position(0, 0), Position(0, 1)), severity: .error, message: "kept")
        let fold = FoldingRange(range: TextRange(Position(0, 0), Position(1, 3)))
        let hint = InlayHint(position: Position(0, 1), label: "kept")
        try d.setTokens([token], version: d.version); try d.setTokens([token], semantic: true, version: d.version)
        try d.setDiagnostics([diagnostic], version: d.version)
        try d.setFoldingRanges([fold], version: d.version); try d.setInlayHints([hint], version: d.version)
        let stale = d.version
        try d.apply([TextEdit(TextRange(Position(1, 3), Position(1, 3)), "!")])
        try d.setInlayHints([hint], version: d.version)
        let before = try d.semantics()
        let bad = TextRange(Position(0, 0), Position(5, 0))
        let staleError = EditorError.staleVersion(expected: stale, actual: d.version)
        #expect(throws: staleError) { try d.setTokens([], version: stale) }
        #expect(throws: staleError) { try d.setTokens([], semantic: true, version: stale) }
        #expect(throws: staleError) { try d.setDiagnostics([], version: stale) }
        #expect(throws: staleError) { try d.setFoldingRanges([], version: stale) }
        #expect(throws: staleError) { try d.setInlayHints([], version: stale) }
        #expect(throws: EditorError.self) { try d.setTokens([token, HighlightToken(range: bad, kind: "bad")], version: d.version) }
        #expect(throws: EditorError.self) { try d.setDiagnostics([diagnostic, Diagnostic(range: bad, severity: .error, message: "bad")], version: d.version) }
        #expect(throws: EditorError.self) { try d.setDecorations([Decoration(tracked: TrackedRange(range: bad), style: "bad")]) }
        #expect(throws: EditorError.self) { try d.setFoldingRanges([fold, FoldingRange(range: bad)], version: d.version) }
        #expect(throws: EditorError.self) { try d.setInlayHints([InlayHint(position: Position(9, 0), label: "bad")], version: d.version) }
        let after = try d.semantics()
        #expect(after.tokens == before.tokens && after.tokensFreshness == before.tokensFreshness)
        #expect(after.semanticTokens == before.semanticTokens && after.semanticTokensFreshness == before.semanticTokensFreshness)
        #expect(after.diagnostics == before.diagnostics && after.diagnosticsFreshness == before.diagnosticsFreshness)
        #expect(after.foldingRanges == before.foldingRanges && after.foldingRangesFreshness == before.foldingRangesFreshness)
        #expect(after.inlayHints == before.inlayHints && after.inlayHintsFreshness == .current)
        #expect(after.tokensFreshness == .stale(version: stale) && after.decorations.isEmpty)
    }
    @Test func compositionPlacesTheMarkedSelection() throws {
        let d = Document(id: "marked", text: "ab")
        let session = try EditorSession(document: d)
        try session.setSelections([Selection(Position(0, 1))])
        try session.beginComposition()
        try session.updateComposition("にほん", markedSelection: 1..<2)
        #expect(session.markedRange == TextRange(Position(0, 1), Position(0, 4)))
        #expect(session.selections == [Selection(anchor: Position(0, 2), head: Position(0, 3))])
        try session.updateComposition("日本")
        #expect(session.selections == [Selection(Position(0, 3))])
        try session.commitComposition()
        #expect(d.snapshot.text == "a日本b" && session.selections == [Selection(Position(0, 3))] && session.markedRange == nil)
    }
    @Test func canonicalSelectionsKeepDirectionAndMergeOverlappingRanges() throws {
        let d = Document(id: "canonical", text: "abcdefgh")
        let session = try EditorSession(document: d)
        try session.setSelections([Selection(anchor: Position(0, 4), head: Position(0, 0)), Selection(anchor: Position(0, 2), head: Position(0, 6))])
        #expect(session.selections == [Selection(anchor: Position(0, 6), head: Position(0, 0))])
        // Touching non-empty selections stay apart, so adjacent occurrences can be selected.
        let adjacent = [Selection(anchor: Position(0, 0), head: Position(0, 2)), Selection(anchor: Position(0, 2), head: Position(0, 4))]
        try session.setSelections(adjacent)
        #expect(session.selections == adjacent)
        // A caret touching a selection joins it.
        try session.setSelections([Selection(Position(0, 4)), Selection(anchor: Position(0, 2), head: Position(0, 4))])
        #expect(session.selections == [Selection(anchor: Position(0, 2), head: Position(0, 4))])
    }
    @Test func thePrimarySelectionFollowsSortingMergingAndHistory() throws {
        let d = Document(id: "primary", text: "abcdefgh")
        let session = try EditorSession(document: d)
        try session.setSelections([Selection(Position(0, 6)), Selection(Position(0, 1)), Selection(Position(0, 3))], primary: 2)
        #expect(session.selections.map(\.head) == [Position(0, 1), Position(0, 3), Position(0, 6)] && session.primaryIndex == 1)
        // The primary caret merges into the selection that contains it.
        try session.setSelections([Selection(Position(0, 0)), Selection(anchor: Position(0, 4), head: Position(0, 6)), Selection(Position(0, 5))], primary: 2)
        #expect(session.selections.count == 2 && session.primarySelection == Selection(anchor: Position(0, 4), head: Position(0, 6)))
        #expect(throws: EditorError.invalidRange) { try session.setSelections([Selection(Position(0, 0))], primary: 1) }
        try session.setSelections([Selection(Position(0, 1)), Selection(Position(0, 3))], primary: 1)
        try session.type("x")
        #expect(session.primaryIndex == 1)
        try session.setSelections([Selection(Position(0, 0))])
        try d.undo()
        #expect(session.selections == [Selection(Position(0, 1)), Selection(Position(0, 3))] && session.primaryIndex == 1)
    }
    @Test func thePrimaryCaretSurvivesAnEditThatMergesSelections() throws {
        let d = Document(id: "merging edit", text: "aabbccddeeff")
        let session = try EditorSession(document: d)
        try session.setSelections([Selection(anchor: Position(0, 0), head: Position(0, 2)), Selection(anchor: Position(0, 2), head: Position(0, 4)),
                                   Selection(anchor: Position(0, 6), head: Position(0, 8))], primary: 2)
        try session.type("")
        #expect(session.selections == [Selection(Position(0, 0)), Selection(Position(0, 2))] && session.primaryIndex == 1)
    }
    @Test func typingDifferentTextAtEachSelection() throws {
        let d = Document(id: "per selection", text: "a\n  b")
        let session = try EditorSession(document: d)
        try session.setSelections([Selection(Position(0, 1)), Selection(Position(1, 3))])
        #expect(throws: EditorError.invalidRange) { try session.type(["\n"]) }
        try session.type(["\n", "\n  "])
        #expect(d.snapshot.text == "a\n\n  b\n  ")
        #expect(session.selections == [Selection(Position(1, 0)), Selection(Position(3, 2))])
        // Adjacent selections each keep a caret after their own text.
        let adjacent = Document(id: "adjacent", text: "aaaa")
        let editor = try EditorSession(document: adjacent)
        try editor.setSelections([Selection(anchor: Position(0, 0), head: Position(0, 2)), Selection(anchor: Position(0, 2), head: Position(0, 4))])
        try editor.type("X")
        #expect(adjacent.snapshot.text == "XX" && editor.selections == [Selection(Position(0, 1)), Selection(Position(0, 2))])
    }
    @Test func applicationDefinedMovesAndDeletions() throws {
        let d = Document(id: "targets", text: "one two\nthree")
        let session = try EditorSession(document: d)
        try session.setSelections([Selection(Position(0, 7)), Selection(Position(1, 5))], primary: 1)
        // A target such as the previous word start comes from the application.
        func wordStart(_ p: Position) -> Position { Position(p.line, p.line == 0 ? 4 : 0) }
        try session.move(extendingSelection: true) { wordStart($0.head) }
        #expect(session.selections == [Selection(anchor: Position(0, 7), head: Position(0, 4)), Selection(anchor: Position(1, 5), head: Position(1, 0))])
        #expect(session.primaryIndex == 1)
        #expect(throws: EditorError.invalidPosition) { try session.move { _ in Position(9, 0) } }
        #expect(throws: EditorError.reentrantMutation) { try session.move { s in try d.apply([]); return s.head } }
        try session.setSelections([Selection(Position(0, 7)), Selection(anchor: Position(1, 0), head: Position(1, 2))])
        try session.delete(to: wordStart)
        #expect(d.snapshot.text == "one \nree" && session.selections == [Selection(Position(0, 4)), Selection(Position(1, 0))])
        try d.undo()
        #expect(d.snapshot.text == "one two\nthree")
    }
    @Test func movingTheCaretEndsTheHistoryGroup() throws {
        let d = Document(id: "moved group", text: "ab")
        let session = try EditorSession(document: d)
        try session.type("1", historyGroup: "typing"); try session.type("2", historyGroup: "typing")
        try session.move(.documentEnd)
        try session.type("3", historyGroup: "typing")
        try d.undo()
        #expect(d.snapshot.text == "12ab" && session.selections == [Selection(Position(0, 4))])
        try d.undo()
        #expect(d.snapshot.text == "ab")
    }
    @Test func lineAndDocumentMovesAndCollapsingRanges() throws {
        let d = Document(id: "moves", text: "ab\ncd\nef", endOfLine: .crlf)
        let session = try EditorSession(document: d)
        try session.setSelections([Selection(Position(1, 1))])
        try session.move(.lineEnd)
        #expect(session.selections == [Selection(Position(1, 2))])
        try session.move(.lineStart)
        #expect(session.selections == [Selection(Position(1, 0))])
        try session.move(.documentEnd)
        #expect(session.selections == [Selection(d.snapshot.fullRange.end)] && d.snapshot.fullRange.end == Position(2, 2))
        try session.move(.documentStart)
        #expect(session.selections == [Selection(Position(0, 0))])
        for (movement, expected) in [(Movement.backward, Position(0, 1)), (.forward, Position(1, 1))] {
            try session.setSelections([Selection(anchor: Position(1, 1), head: Position(0, 1))])
            try session.move(movement)
            #expect(session.selections == [Selection(expected)])
        }
        try session.setSelections([Selection(anchor: Position(0, 1), head: Position(1, 1))])
        try session.move(.forward, extendingSelection: true)
        #expect(session.selections == [Selection(anchor: Position(0, 1), head: Position(1, 2))])
    }
    @Test func laterSessionsFollowUndoAndRedo() throws {
        let d = Document(id: "later", text: "abc")
        let early = try EditorSession(document: d)
        try early.setSelections([Selection(Position(0, 3))])
        try early.type("XY")
        let late = try EditorSession(document: d)
        try late.setSelections([Selection(Position(0, 5))])
        try d.undo()
        #expect(late.selections == [Selection(Position(0, 3))] && early.selections == [Selection(Position(0, 3))])
        try d.redo()
        #expect(late.selections == [Selection(Position(0, 5))] && early.selections == [Selection(Position(0, 5))])
    }
    @Test func verticalMovesStartFromTheSelectionEdgeInTheirDirection() throws {
        final class Layout: LayoutAdapter {
            var origins: [Position] = []
            func moveVertically(from position: Position, direction: VerticalDirection,
                                preferredAdvance: Double?, snapshot: TextSnapshot) throws -> LayoutMovement {
                origins.append(position)
                return LayoutMovement(position: Position(position.line + (direction == .down ? 1 : -1), 0), preferredAdvance: 0)
            }
            func position(at display: DisplayPosition, snapshot: TextSnapshot) throws -> Position { Position(0, 0) }
            func displayPosition(at position: Position, snapshot: TextSnapshot) throws -> DisplayPosition { DisplayPosition(row: 0, advance: 0) }
        }
        let d = Document(id: "edges", text: "a\nb\nc\nd\ne\nf")
        let session = try EditorSession(document: d), layout = Layout()
        try session.setLayout(layout)
        let backward = Selection(anchor: Position(4, 0), head: Position(2, 1))
        for (movement, extending, origin) in [(Movement.down, false, Position(4, 0)), (.up, false, Position(2, 1)), (.down, true, Position(2, 1))] {
            try session.setSelections([backward]); layout.origins = []
            try session.move(movement, extendingSelection: extending)
            #expect(layout.origins == [origin])
        }
        try session.setSelections([Selection(anchor: Position(1, 0), head: Position(3, 0))]); layout.origins = []
        try session.move(.up)
        #expect(layout.origins == [Position(1, 0)] && session.selections == [Selection(Position(0, 0))])
    }
    @Test func unchangedCompositionUpdatesReportNoCompositionChange() throws {
        let d = Document(id: "unchanged", text: "")
        let session = try EditorSession(document: d)
        var changes: [DocumentChanges] = []
        let observation = try d.observe { changes.append($0.changes) }
        try session.beginComposition(); try session.updateComposition("k"); try session.updateComposition("k")
        #expect(changes == [[.composition], [.text, .selection, .composition], []])
        observation.cancel()
    }
    @Test func compositionSpansEverySelection() throws {
        let d = Document(id: "multi", text: "ab\ncd")
        let session = try EditorSession(document: d)
        let selections = [Selection(Position(0, 1)), Selection(Position(1, 1))]
        try session.setSelections(selections, primary: 1)
        try session.beginComposition()
        try session.updateComposition("にほ", markedSelection: 0..<1)
        #expect(d.snapshot.text == "aにほb\ncにほd")
        #expect(session.markedRanges == [TextRange(Position(0, 1), Position(0, 3)), TextRange(Position(1, 1), Position(1, 3))])
        #expect(session.markedRange == TextRange(Position(1, 1), Position(1, 3)))
        #expect(session.selections == [Selection(anchor: Position(0, 1), head: Position(0, 2)), Selection(anchor: Position(1, 1), head: Position(1, 2))])
        try session.commitComposition("日本")
        #expect(d.snapshot.text == "a日本b\nc日本d" && session.selections == [Selection(Position(0, 3)), Selection(Position(1, 3))])
        #expect(session.markedRanges.isEmpty && session.primaryIndex == 1)
        try d.undo()
        #expect(d.snapshot.text == "ab\ncd" && session.selections == selections && session.primaryIndex == 1)
        try session.beginComposition(); try session.updateComposition("k"); try session.cancelComposition()
        #expect(d.snapshot.text == "ab\ncd" && session.selections == selections && d.canRedo)
    }
    @Test func emptiedAdjacentMarkedRangesBecomeOne() throws {
        let d = Document(id: "adjacent composition", text: "aaaa")
        let session = try EditorSession(document: d)
        let selections = [Selection(anchor: Position(0, 0), head: Position(0, 2)), Selection(anchor: Position(0, 2), head: Position(0, 4))]
        try session.setSelections(selections, primary: 1)
        try session.beginComposition()
        try session.updateComposition("k")
        #expect(d.snapshot.text == "kk" && session.markedRanges.count == 2)
        try session.updateComposition("")
        #expect(d.snapshot.text == "" && session.markedRanges == [TextRange(Position(0, 0), Position(0, 0))] && session.primaryIndex == 0)
        try session.updateComposition("x")
        #expect(d.snapshot.text == "x")
        try session.cancelComposition()
        #expect(d.snapshot.text == "aaaa" && session.selections == selections && session.primaryIndex == 1)
        // Restoring the text of the merged range is still recognised as no change.
        try session.beginComposition(); try session.updateComposition(""); try session.commitComposition("aaaa")
        #expect(d.snapshot.text == "aaaa" && !d.canUndo)
    }
    @Test func compositionCanReplaceTextBesideEachMarkedRange() throws {
        let d = Document(id: "widened", text: "ab ab")
        let session = try EditorSession(document: d)
        try session.setSelections([Selection(Position(0, 2)), Selection(Position(0, 5))])
        try session.beginComposition()
        try session.updateComposition("X", replacingBefore: 1)
        #expect(d.snapshot.text == "aX aX" && session.markedRanges == [TextRange(Position(0, 1), Position(0, 2)), TextRange(Position(0, 4), Position(0, 5))])
        // Putting back what the widened ranges covered is no change.
        try session.commitComposition("b")
        #expect(d.snapshot.text == "ab ab" && !d.canUndo)
        try session.beginComposition()
        try session.updateComposition("Y", replacingBefore: 2)
        try session.commitComposition()
        #expect(d.snapshot.text == "Y Y" && session.selections == [Selection(Position(0, 1)), Selection(Position(0, 3))])
        try d.undo()
        #expect(d.snapshot.text == "ab ab")
        let overlapping = Document(id: "overlapping", text: "abcdef")
        let editor = try EditorSession(document: overlapping)
        try editor.setSelections([Selection(Position(0, 1)), Selection(Position(0, 3))])
        try editor.beginComposition()
        #expect(throws: EditorError.overlappingEdits) { try editor.updateComposition("k", replacingAfter: 3) }
        #expect(throws: EditorError.invalidPosition) { try editor.updateComposition("k", replacingBefore: 2) }
        #expect(throws: EditorError.invalidRange) { try editor.updateComposition("k", replacingBefore: -1) }
        #expect(overlapping.snapshot.text == "abcdef" && editor.markedRanges.count == 2)
    }
    @Test func collapseStateFollowsEditsBeforeFoldsAreRebuilt() throws {
        let d = Document(id: "moved", text: "# A\na\n# B\nb\nc")
        let session = try EditorSession(document: d)
        let fold = FoldingRange(range: TextRange(Position(2, 0), Position(4, 1)))
        try d.setFoldingRanges([fold], version: d.version)
        try session.setCollapsed(true, foldID: fold.id)
        try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "new\nlines\n")])
        // A provider rebuilds the fold at its new lines with a new ID.
        try d.setFoldingRanges([FoldingRange(range: TextRange(Position(0, 0), Position(3, 1))),
                                FoldingRange(range: TextRange(Position(4, 0), Position(6, 1)))], version: d.version)
        #expect(try session.hiddenLineRanges() == [5..<7])
    }
    @Test func invalidPositionsAreRejectedBeforeTheyAreStored() throws {
        let d = Document(id: "positions", text: "😀\nab", endOfLine: .crlf)
        let session = try EditorSession(document: d)
        try session.setSelections([Selection(Position(1, 1))])
        for (position, error) in [(Position(0, 1), EditorError.invalidBoundary), (Position(0, 3), .invalidPosition), (Position(5, 0), .invalidPosition)] {
            #expect(throws: error) { try session.setSelections([Selection(position)]) }
            #expect(throws: error) { try d.trackRange(TextRange(Position(0, 0), position)) }
        }
        #expect(try session.selections == [Selection(Position(1, 1))] && d.semantics().trackedRanges.isEmpty)
        try session.type("x")
        #expect(d.snapshot.text == "😀\r\naxb")
    }
    @Test func unorderedFoldsAreStoredOutermostFirst() async throws {
        let inner = FoldingRange(range: TextRange(Position(1, 0), Position(2, 1)))
        let outer = FoldingRange(range: TextRange(Position(0, 0), Position(3, 1)))
        let d = Document(id: "unordered", text: "a\nb\nc\nd")
        try d.setFoldingRanges([inner, outer], version: d.version)
        #expect(try d.semantics().foldingRanges.map(\.id) == [outer.id, inner.id])
        let workspace = EditorWorkspace()
        let provided = try workspace.createDocument(id: "provided", text: "a\nb\nc\nd")
        let token = try workspace.register(language: "*", features: [.folding], provider: ClosureProvider { _ in .folding([inner, outer]) })
        _ = try await workspace.request(documentID: provided.id, feature: .folding)
        #expect(try provided.semantics().foldingRanges.map(\.id) == [outer.id, inner.id])
        token.cancel(); try workspace.dispose()
    }
    @Test func collapsedFoldsNeverHideACaret() throws {
        func setUp() throws -> (Document, EditorSession, FoldingRange) {
            let d = Document(id: "carets", text: "# A\na\nb\n# B\nc")
            let session = try EditorSession(document: d)
            let fold = FoldingRange(range: TextRange(Position(0, 0), Position(3, 0)))
            try d.setFoldingRanges([fold], version: d.version)
            return (d, session, fold)
        }
        // Collapsing moves a caret inside to the end of the first line.
        var (d, session, fold) = try setUp()
        try session.setSelections([Selection(Position(1, 1)), Selection(Position(4, 0))])
        try session.setCollapsed(true, foldID: fold.id)
        #expect(session.selections == [Selection(Position(0, 3)), Selection(Position(4, 0))] && session.collapsedFolds == [fold.id])
        // Enter at the end of the heading puts the caret on a covered line, so the fold opens.
        try session.type("\n")
        #expect(try session.collapsedFolds.isEmpty && session.hiddenLineRanges().isEmpty)
        // So do moving into it and undo restoring a caret inside it.
        (d, session, fold) = try setUp()
        try session.setSelections([Selection(Position(0, 3))])
        try session.setCollapsed(true, foldID: fold.id)
        try session.move(.forward)
        #expect(session.selections == [Selection(Position(1, 0))] && session.collapsedFolds.isEmpty)
        try session.type("x")
        try session.setSelections([Selection(Position(0, 0))])
        try session.setCollapsed(true, foldID: fold.id)
        try d.undo()
        #expect(session.selections == [Selection(Position(1, 0))] && session.collapsedFolds.isEmpty)
    }
    @Test func deletingASelectionRemovesItWhole() throws {
        for forward in [false, true] {
            let d = Document(id: "range delete", text: "abcdef\nxyz")
            let session = try EditorSession(document: d)
            try session.setSelections([Selection(anchor: Position(0, 4), head: Position(0, 1)), Selection(Position(1, 1))])
            if forward { try session.deleteForward() } else { try session.deleteBackward() }
            #expect(d.snapshot.text == (forward ? "aef\nxz" : "aef\nyz"))
            #expect(session.selections == [Selection(Position(0, 1)), Selection(Position(1, forward ? 1 : 0))])
            try d.undo()
            #expect(d.snapshot.text == "abcdef\nxyz")
        }
    }
    @Test func invertedRangesCollapse() throws {
        let d = Document(id: "inverted", text: "abc")
        let marker = try d.trackRange(TextRange(Position(0, 1), Position(0, 1)))
        try d.setDiagnostics([Diagnostic(range: TextRange(Position(0, 1), Position(0, 1)), severity: .hint, message: "empty")], version: d.version)
        try d.apply([TextEdit(TextRange(Position(0, 1), Position(0, 1)), "XY")])
        // growNeither moves an empty range's start after the insertion and its end before it.
        let range = try #require(try d.trackedRange(id: marker)?.range)
        #expect(range.start == range.end && range.start == Position(0, 3))
        #expect(try d.semantics().diagnostics.map(\.range) == [range])
        _ = try d.snapshot.offsets(in: range)
    }
    @Test func eventsCarryTheVersionTheyReport() throws {
        let d = Document(id: "event versions", text: "a")
        let session = try EditorSession(document: d)
        var mismatches = 0, events = 0
        let observation = try d.observe { event in events += 1; if event.version != d.version { mismatches += 1 } }
        try session.type("b"); try d.undo(); try d.redo()
        try session.beginComposition(); try session.updateComposition("c"); try session.commitComposition()
        #expect(events == 6 && mismatches == 0 && d.version == 5)
        observation.cancel()
    }
    @Test func extendingADisplaySelectionKeepsTheAnchor() throws {
        struct Layout: LayoutAdapter {
            func moveVertically(from position: Position, direction: VerticalDirection,
                                preferredAdvance: Double?, snapshot: TextSnapshot) throws -> LayoutMovement {
                LayoutMovement(position: position, preferredAdvance: 0)
            }
            func position(at display: DisplayPosition, snapshot: TextSnapshot) throws -> Position { Position(display.row, Int(display.advance)) }
            func displayPosition(at position: Position, snapshot: TextSnapshot) throws -> DisplayPosition { DisplayPosition(row: 0, advance: 0) }
        }
        let d = Document(id: "shift click", text: "abc\ndef")
        let session = try EditorSession(document: d)
        try session.setLayout(Layout())
        try session.setSelections([Selection(Position(0, 1))])
        try session.select(at: DisplayPosition(row: 1, advance: 2), extendingSelection: true)
        #expect(session.selections == [Selection(anchor: Position(0, 1), head: Position(1, 2))])
        try session.select(at: DisplayPosition(row: 0, advance: 3))
        #expect(session.selections == [Selection(Position(0, 3))])
    }
    @Test func workspaceEditsRevealCaretsBeforeAnyNotification() throws {
        let workspace = EditorWorkspace()
        let a = try workspace.createDocument(id: "a", text: "a"), b = try workspace.createDocument(id: "b", text: "# B\nx\ny\n# C")
        let session = try EditorSession(document: b)
        let fold = FoldingRange(range: TextRange(Position(0, 0), Position(3, 0)))
        try b.setFoldingRanges([fold], version: b.version)
        try session.setSelections([Selection(Position(0, 3))])
        try session.setCollapsed(true, foldID: fold.id)
        var hiddenDuringFirst: [Range<Int>]?
        let observation = try a.observe { _ in hiddenDuringFirst = try? session.hiddenLineRanges() }
        try workspace.apply(WorkspaceEdit([DocumentEdits(documentID: "a", expectedVersion: a.version, edits: [TextEdit(TextRange(Position(0, 0), Position(0, 0)), "x")]),
                                           DocumentEdits(documentID: "b", expectedVersion: b.version, edits: [TextEdit(TextRange(Position(0, 3), Position(0, 3)), "\n")])]))
        // The new line puts b's caret inside the fold, which is already open during a's notification.
        #expect(session.selections == [Selection(Position(1, 0))] && session.collapsedFolds.isEmpty)
        #expect(hiddenDuringFirst == [])
        observation.cancel(); try workspace.dispose()
    }
    @Test func compositionBlocksHidingItsCaretAndReplacingAll() throws {
        let d = Document(id: "composing", text: "# A\nab\nc")
        let session = try EditorSession(document: d)
        let fold = FoldingRange(range: TextRange(Position(0, 0), Position(2, 1)))
        try d.setFoldingRanges([fold], version: d.version)
        try session.setSelections([Selection(Position(1, 1))])
        try session.beginComposition(); try session.updateComposition("k")
        #expect(throws: EditorError.compositionActive) { try session.setCollapsed(true, foldID: fold.id) }
        #expect(throws: EditorError.compositionActive) { try d.replaceAll("a", with: "b") }
        #expect(session.collapsedFolds.isEmpty && d.snapshot.text == "# A\nakb\nc")
        try session.commitComposition()
    }
    @Test func touchingEditsTrackRangesAsOneReplacement() throws {
        let d = Document(id: "touching", text: "abcd")
        let range = try d.trackRange(TextRange(Position(0, 2), Position(0, 4)), stickiness: .growBoth)
        try d.apply([TextEdit(TextRange(Position(0, 1), Position(0, 2)), "X"), TextEdit(TextRange(Position(0, 2), Position(0, 3)), "Y")])
        // One replacement of [1, 3) by "XY": the start inside it collapses to its start.
        #expect(try d.snapshot.text == "aXYd" && d.trackedRange(id: range)?.range == TextRange(Position(0, 1), Position(0, 4)))
    }
    @Test func disposingASessionCancelsItsComposition() throws {
        let d = Document(id: "dispose composing", text: "ab")
        let composer = try EditorSession(document: d), other = try EditorSession(document: d)
        try composer.setSelections([Selection(Position(0, 1))])
        try composer.beginComposition(); try composer.updateComposition("に")
        try composer.dispose()
        #expect(d.snapshot.text == "ab" && !d.canUndo)
        try other.type("x")
        #expect(d.snapshot.text == "xab")
    }
    @Test func redoingAGroupedStepRestoresItsFinalSelections() throws {
        let d = Document(id: "grouped redo", text: "")
        let session = try EditorSession(document: d)
        try session.type("a", historyGroup: "typing"); try session.type("b", historyGroup: "typing")
        try d.undo()
        #expect(d.snapshot.text == "" && session.selections == [Selection(Position(0, 0))])
        try d.redo()
        #expect(d.snapshot.text == "ab" && session.selections == [Selection(Position(0, 2))])
    }
    @Test func collapseStatePrefersTheSameIDThenTheOutermostFold() throws {
        let d = Document(id: "priority", text: "a\nb\nc\nd\ne\nf\ng\nh")
        let session = try EditorSession(document: d)
        let stable = FoldingRange(range: TextRange(Position(3, 0), Position(5, 1)))
        try d.setFoldingRanges([stable], version: d.version)
        try session.setCollapsed(true, foldID: stable.id)
        // The fold keeps its ID but grows; a new fold now covers its old lines.
        let grown = FoldingRange(id: stable.id, range: TextRange(Position(3, 0), Position(7, 1)))
        let inner = FoldingRange(range: TextRange(Position(3, 0), Position(5, 1)))
        try d.setFoldingRanges([inner, grown], version: d.version)
        #expect(try session.collapsedFolds == [stable.id] && session.hiddenLineRanges() == [4..<8])
        // With fresh IDs and no fold at the same lines, the outermost on the start line wins, in any input order.
        let outer = FoldingRange(range: TextRange(Position(3, 0), Position(6, 1)))
        let nested = FoldingRange(range: TextRange(Position(3, 0), Position(4, 1)))
        try d.setFoldingRanges([nested, outer], version: d.version)
        #expect(session.collapsedFolds == [outer.id])
    }
    @Test func selectedRangesDeleteExactlyTheirScalars() throws {
        for forward in [false, true] {
            let d = Document(id: "scalars", text: "e\u{301}x")
            let session = try EditorSession(document: d)
            try session.setSelections([Selection(anchor: Position(0, 1), head: Position(0, 2))])
            if forward { try session.deleteForward() } else { try session.deleteBackward() }
            #expect(d.snapshot.text == "ex")
            try d.undo()
            #expect(d.snapshot.text == "e\u{301}x")
        }
    }
    @Test func observationsLastUntilCancelledAndDisposalReleases() throws {
        final class Owner {}
        final class Layout: LayoutAdapter {
            func moveVertically(from position: Position, direction: VerticalDirection,
                                preferredAdvance: Double?, snapshot: TextSnapshot) throws -> LayoutMovement { LayoutMovement(position: position, preferredAdvance: 0) }
            func position(at display: DisplayPosition, snapshot: TextSnapshot) throws -> Position { Position(0, 0) }
            func displayPosition(at position: Position, snapshot: TextSnapshot) throws -> DisplayPosition { DisplayPosition(row: 0, advance: 0) }
        }
        let d = Document(id: "release", text: "a")
        var calls = 0
        // Dropping the token does not end the observation.
        _ = try d.observe { _ in calls += 1 }
        weak var owner: Owner?
        weak var layout: Layout?
        // The disposed session stays referenced, so only disposal can release its adapter.
        var kept: EditorSession?
        do {
            let captured = Owner(); owner = captured
            _ = try d.observe { _ in _ = captured }
            let session = try EditorSession(document: d); kept = session
            let adapter = Layout(); layout = adapter
            try session.setLayout(adapter)
            try session.type("b")
            try session.dispose()
        }
        #expect(calls == 2 && layout == nil && owner != nil && kept?.isDisposed == true)
        try d.dispose()
        #expect(owner == nil)
    }
    @Test func undoingACompositionRestoresSelectionsFromJustBeforeIt() throws {
        let d = Document(id: "composition undo", text: "abc")
        let composer = try EditorSession(document: d), other = try EditorSession(document: d)
        try other.setSelections([Selection(Position(0, 3))])
        try composer.beginComposition()
        try other.setSelections([Selection(Position(0, 1))])
        try composer.updateComposition("X"); try composer.commitComposition()
        try d.undo()
        #expect(d.snapshot.text == "abc" && other.selections == [Selection(Position(0, 1))] && composer.selections == [Selection(Position(0, 0))])
    }
    @Test func replayingOperationsReportWhatTheyChanged() throws {
        let d = Document(id: "replays", text: "# A\nb\nc")
        let session = try EditorSession(document: d)
        var events: [(ChangeKind, DocumentChanges)] = []
        let observation = try d.observe { events.append(($0.kind, $0.changes)) }
        try session.setSelections([Selection(Position(1, 1))])
        try session.type("x", historyGroup: "g"); try session.type("y", historyGroup: "g")
        let fold = FoldingRange(range: TextRange(Position(0, 0), Position(2, 1)))
        try d.setFoldingRanges([fold], version: d.version)
        try session.setSelections([Selection(Position(0, 0))])
        try session.setCollapsed(true, foldID: fold.id)
        events = []
        // Undo puts the caret back inside the collapsed fold, which opens.
        try d.undo()
        try d.redo()
        try session.beginComposition(); try session.updateComposition("k"); try session.cancelComposition()
        #expect(events.map(\.0) == [.undo, .redo, .composition, .composition, .composition])
        // Only the undo opens the fold; redo and the composition outside it leave folds alone.
        // Cancelling reports the caret it moved back, though it ends where it started.
        #expect(events.map(\.1) == [[.text, .selection, .semantics], [.text, .selection],
                                    [.composition], [.text, .selection, .composition], [.text, .selection, .composition]])
        #expect(session.collapsedFolds.isEmpty)
        // Moving into a collapsed fold changes no text, so only the opening fold reports semantics.
        try session.setSelections([Selection(Position(0, 3))])
        try session.setCollapsed(true, foldID: fold.id)
        events = []
        try session.move(.forward)
        #expect(events.map(\.1) == [[.selection, .semantics]] && session.collapsedFolds.isEmpty)
        observation.cancel()
    }
}
