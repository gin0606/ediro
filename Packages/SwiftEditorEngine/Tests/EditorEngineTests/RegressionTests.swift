// Reference-derived fixtures: Copyright (c) Microsoft Corporation.
// Licensed under the MIT License; see Documentation/VSCode-LICENSE.txt.
import Testing
import EditorEngine

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct RegressionTests {
    @Test func pinnedInlineMultilineAndTouchingEdits() throws {
        let lines = ["My First Line","\t\tMy Second Line","    Third Line","","1"]
        let cases: [(TextEdit,[String])] = [
            (TextEdit(TextRange(Position(0,0),Position(0,0)),"a"),["aMy First Line"] + Array(lines.dropFirst())),
            (TextEdit(TextRange(Position(0,0),Position(0,13)),"My new First Line."),["My new First Line."] + Array(lines.dropFirst())),
            (TextEdit(TextRange(Position(0,0),Position(2,14)),"My new First Line."),["My new First Line.","","1"]),
            (TextEdit(TextRange(Position(0,1),Position(2,1)),"My new First Line."),["MMy new First Line.   Third Line","","1"]),
            (TextEdit(TextRange(Position(0,0),Position(0,0)),"1\n2\n3\n4\n"),["1","2","3","4"] + lines)
        ]
        for eol in [EndOfLine.lf,.crlf] {
            for (edit,expected) in cases {
                let d = Document(id:"fixture",text:lines.joined(separator:eol.rawValue),endOfLine:eol)
                try d.apply([edit]); #expect(d.snapshot.text == expected.joined(separator:eol.rawValue))
                try d.undo(); #expect(d.snapshot.text == lines.joined(separator:eol.rawValue))
                try d.redo(); #expect(d.snapshot.text == expected.joined(separator:eol.rawValue))
            }
        }
        for (first,second,expected) in [("H","E","HEllo world"),("","","llo world")] {
            let d = Document(id:"touching",text:"hello world")
            try d.apply([TextEdit(TextRange(Position(0,0),Position(0,1)),first),TextEdit(TextRange(Position(0,1),Position(0,2)),second)])
            #expect(d.snapshot.text == expected)
            try d.undo(); #expect(d.snapshot.text == "hello world")
            try d.redo(); #expect(d.snapshot.text == expected)
        }
        let d = Document(id:"surrogate undo",text:"'👁'")
        try d.apply([TextEdit(TextRange(Position(0,0),Position(0,0)),"\""),TextEdit(TextRange(Position(0,1),Position(0,1)),"\"")])
        #expect(d.snapshot.text == "\"'\"👁'")
        try d.undo(); #expect(d.snapshot.text == "'👁'")
        try d.redo(); #expect(d.snapshot.text == "\"'\"👁'")
    }
    @Test func pinnedMarkerEdgeAffinities() throws {
        let modes: [RangeStickiness] = [.growBoth,.growNeither,.growBefore,.growAfter]
        for (offset,expected) in [(3,[(3,10),(5,10),(3,10),(5,10)]),(8,[(3,10),(3,8),(3,8),(3,10)])] {
            for (mode,pair) in zip(modes,expected) {
                let d = Document(id:"marker",text:"01234567890123456789")
                let id = try d.trackRange(TextRange(Position(0,3),Position(0,8)),stickiness:mode)
                let p = Position(0,offset); try d.apply([TextEdit(TextRange(p,p),"xx")])
                #expect(try d.trackedRange(id:id)?.range == TextRange(Position(0,pair.0),Position(0,pair.1)))
                try d.removeTrackedRange(id:id); #expect(try d.trackedRange(id:id) == nil)
            }
        }
    }
    @Test func exactUTF16ReplacementAndNoOpTyping() throws {
        let d = Document(id:"normalization",text:"e\u{301}")
        try d.apply([TextEdit(d.snapshot.fullRange,"é")])
        #expect(d.snapshot.utf16Count == 1)
        try d.undo(); #expect(d.snapshot.utf16Count == 2)
        try d.redo(); #expect(d.snapshot.utf16Count == 1)
        let e = try EditorSession(document:d)
        try e.setSelections([Selection(anchor:Position(0,0),head:Position(0,1))])
        let version = d.version
        try e.type("é"); #expect(d.version == version)
        #expect(e.selections == [Selection(Position(0,1))])
    }
    @Test func seededSimultaneousEditsAndUndo() throws {
        var state: UInt64 = 72
        func random(_ n:Int) -> Int { state = state &* 2862933555777941757 &+ 3037000493; return Int((state >> 32) % UInt64(n)) }
        let d = Document(id:"batches",text:String(repeating:"ab😀c\n",count:200))
        let initial = d.snapshot.text
        var model = Array(initial.utf16), history = [initial]
        for _ in 0..<120 {
            let boundaries = (0...model.count).filter { i in
                i == 0 || i == model.count || !((0xD800...0xDBFF).contains(model[i-1]) && (0xDC00...0xDFFF).contains(model[i]))
            }
            let third = boundaries.count / 3
            var operations: [(Range<Int>,String)] = []
            for region in 0..<3 {
                let index = region * third + random(max(1,third - 4))
                let a = boundaries[index], b = boundaries[index + random(4)]
                operations.append((a..<b,["X","😀","\n",""][random(4)]))
            }
            let old = d.snapshot
            let edits = try operations.map { TextEdit(TextRange(try old.position(at:$0.0.lowerBound),try old.position(at:$0.0.upperBound)),$0.1) }
            let version = d.version
            try d.apply(edits.reversed())
            for (range,text) in operations.reversed() { model.replaceSubrange(range,with:text.utf16) }
            #expect(d.snapshot.text.utf16.elementsEqual(model))
            if version != d.version { history.append(d.snapshot.text) }
        }
        for expected in history.dropLast().reversed() { try d.undo(); #expect(d.snapshot.text.utf16.elementsEqual(expected.utf16)) }
        for expected in history.dropFirst() { try d.redo(); #expect(d.snapshot.text.utf16.elementsEqual(expected.utf16)) }
    }
    @Test func explicitCancellationAndDisposedDocumentOwnership() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id:"cancellation")
        let gate = GateProvider()
        let token = try workspace.register(language:"*",features:[.hover],provider:gate)
        let request = Task { try await workspace.request(documentID:d.id,feature:.hover) }
        try await gate.waitFor(1)
        workspace.cancelRequest(documentID:d.id,feature:.hover)
        gate.finish(0,.hover(nil))
        await #expect(throws:EditorError.cancelled) { try await request.value }
        guard case .cancelled = workspace.status(documentID:d.id,feature:.hover) else { Issue.record("Cancellation not retained"); return }
        try d.dispose(); try workspace.closeDocument(id:d.id)
        let another = try workspace.createDocument(id:"already disposed")
        try another.dispose(); try workspace.dispose(); token.cancel()
        #expect(workspace.isDisposed)
    }
}
