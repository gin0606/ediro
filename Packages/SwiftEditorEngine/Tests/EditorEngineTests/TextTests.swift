// Reference-derived fixtures: Copyright (c) Microsoft Corporation.
// Licensed under the MIT License; see Documentation/VSCode-LICENSE.txt.
import Testing
import Foundation
import EditorEngine

@Suite(.serialized) @MainActor struct TextTests {
    func r(_ a: Int, _ b: Int) -> TextRange { TextRange(Position(0,a), Position(0,b)) }
    @Test func pinnedPieceTreeFixtures() throws {
        let d = Document(id: "fixture", text: "1\n2\n3\n4")
        let expected = [Position(0,0), Position(0,1), Position(1,0), Position(1,1), Position(2,0), Position(2,1), Position(3,0)]
        for (offset,p) in expected.enumerated() {
            #expect(try d.snapshot.position(at: offset) == p)
            #expect(try d.snapshot.offset(at: p) == offset)
        }
        let inserted = Document(id: "insert", text: "a\nb\nc\nde")
        let p = try inserted.snapshot.position(at: 7)
        try inserted.apply([TextEdit(TextRange(p,p), "fh\ni\njk")])
        #expect(inserted.snapshot.lineCount == 6)
        for (offset,p) in [(6,Position(3,0)),(7,Position(3,1)),(8,Position(3,2)),(9,Position(3,3)),(12,Position(5,0)),(14,Position(5,2))] {
            #expect(try inserted.snapshot.position(at: offset) == p)
            #expect(try inserted.snapshot.offset(at: p) == offset)
        }
    }
    @Test func unicodeEOLAndStrictBoundaries() throws {
        let d = Document(id: "unicode", text: "a📚b\r\ne\u{301}👨‍👩‍👧‍👦\r", endOfLine: .crlf)
        #expect(d.snapshot.lineCount == 3)
        #expect(try d.snapshot.line(0) == "a📚b")
        #expect(try d.snapshot.line(2) == "")
        #expect(throws: EditorError.invalidBoundary) { try d.snapshot.offset(at: Position(0,2)) }
        #expect(throws: EditorError.invalidBoundary) { try d.snapshot.position(at: 5) }
        #expect(throws: EditorError.invalidPosition) { try d.snapshot.offset(at: Position(-1,0)) }
        #expect(throws: EditorError.invalidRange) { try d.apply([TextEdit(TextRange(Position(1,0),Position(0,0)), "")]) }
        let old = d.snapshot
        try d.apply([TextEdit(TextRange(Position(1,1),Position(1,2)), "")])
        #expect(try d.snapshot.line(1) == "e👨‍👩‍👧‍👦")
        #expect(try old.line(1) == "e\u{301}👨‍👩‍👧‍👦")
        let empty = Document(id: "empty")
        #expect(empty.snapshot.lineCount == 1)
        #expect(try empty.snapshot.position(at: 0) == Position(0,0))
        try empty.apply([TextEdit(r(0,0), "\r\n")])
        #expect(empty.snapshot.text == "\n")
        try empty.undo(); #expect(empty.snapshot.text == "")
        try empty.redo(); #expect(empty.snapshot.text == "\n")
    }
    @Test func atomicBatchesAndGrouping() throws {
        let d = Document(id: "edits", text: "abcdef")
        let version = d.version
        #expect(throws: EditorError.overlappingEdits) { try d.apply([TextEdit(r(0,3),"x"),TextEdit(r(2,4),"y")]) }
        #expect(throws: EditorError.overlappingEdits) { try d.apply([TextEdit(r(2,2),"x"),TextEdit(r(2,2),"y")]) }
        #expect(d.version == version)
        try d.apply([TextEdit(r(4,6),"!"), TextEdit(r(0,2),"AB")], historyGroup: "typing")
        try d.apply([TextEdit(r(2,2),"++")], historyGroup: "typing")
        #expect(d.snapshot.text == "AB++cd!")
        #expect(throws: EditorError.staleVersion(expected: version, actual: d.version)) { try d.apply([TextEdit(r(0,0),"x")],expectedVersion: version) }
        try d.undo(); #expect(d.snapshot.text == "abcdef")
        try d.redo(); #expect(d.snapshot.text == "AB++cd!")
        let v = d.version; try d.apply([TextEdit(r(0,2),"AB")]); #expect(d.version == v)
        try d.endHistoryGroup(); try d.apply([TextEdit(r(0,0),"new")],historyGroup: "typing")
        try d.undo(); #expect(d.snapshot.text == "AB++cd!")
        try d.apply([TextEdit(r(0,0),"branch")]); #expect(!d.canRedo)
    }
    @Test func historyTravelEndsTheOpenGroup() throws {
        let d = Document(id: "travel", text: "")
        try d.apply([TextEdit(r(0,0),"a")], historyGroup: "typing")
        try d.apply([TextEdit(r(1,1),"b")])
        try d.undo(); try d.apply([TextEdit(r(1,1),"c")], historyGroup: "typing")
        try d.undo(); #expect(d.snapshot.text == "a")
        try d.redo(); try d.apply([TextEdit(r(2,2),"d")], historyGroup: "typing")
        try d.undo(); #expect(d.snapshot.text == "ac")
    }
    @Test func heldGroupSpansSelectionChangesUntilEnded() throws {
        let d = Document(id: "held", text: "abc")
        let e = try EditorSession(document: d)
        try e.type("0", historyGroup: "held")
        try d.beginHistoryGroup("held")
        try e.type("1", historyGroup: "held")
        try e.setSelections([Selection(Position(0, 5))])
        try e.type("2", historyGroup: "held")
        try e.setSelections([Selection(Position(0, 0))])
        try e.replace([TextEdit(r(0,0), "3")], selecting: [(anchor: 1, head: 1)], historyGroup: "held")
        try d.apply([TextEdit(r(0,0), "4")], historyGroup: "held")
        #expect(d.snapshot.text == "4301abc2")
        // Beginning the group set a boundary, and one undo removes the whole held step.
        try d.undo(); #expect(d.snapshot.text == "0abc")
        #expect(e.selections == [Selection(Position(0, 1))])
        try d.redo(); #expect(d.snapshot.text == "4301abc2")
        try d.undo()
        try d.beginHistoryGroup("held")
        try e.type("x", historyGroup: "held")
        try d.endHistoryGroup()
        try e.setSelections([Selection(Position(0, 0))])
        try e.type("y", historyGroup: "held")
        try d.undo(); #expect(d.snapshot.text == "0xabc")
        // Another group is not held.
        try d.beginHistoryGroup("held")
        try e.type("p", historyGroup: "other")
        try e.setSelections([Selection(Position(0, 6))])
        try e.type("q", historyGroup: "other")
        try d.undo(); #expect(d.snapshot.text == "p0xabc")
        try d.endHistoryGroup()
        // Ending a held group leaves a step of another group open.
        try d.beginHistoryGroup("held")
        try e.type("h", historyGroup: "held")
        try e.type("t", historyGroup: "typing")
        try d.endHistoryGroup()
        try e.type("u", historyGroup: "typing")
        try d.undo(); #expect(d.snapshot.text == "p0xabch")
        try d.undo(); #expect(d.snapshot.text == "p0xabc")
        // A composition records its own step but keeps the group held, even when it records
        // nothing.
        try d.beginHistoryGroup("held")
        try e.setSelections([Selection(Position(0, 0))])
        try e.beginComposition(); try e.updateComposition("k"); try e.commitComposition()
        try e.type("r", historyGroup: "held")
        try e.beginComposition(); try e.updateComposition(""); try e.commitComposition()
        try e.setSelections([Selection(Position(0, 8))])
        try e.type("s", historyGroup: "held")
        #expect(d.snapshot.text == "krp0xabcs")
        try d.undo(); #expect(d.snapshot.text == "kp0xabc")
        // Undo or redo while held ends the step; later held edits form a new one.
        try e.setSelections([Selection(Position(0, 0))])
        try e.type("1", historyGroup: "held")
        try d.undo(); #expect(d.snapshot.text == "kp0xabc")
        try e.type("2", historyGroup: "held")
        try e.setSelections([Selection(Position(0, 3))])
        try e.type("3", historyGroup: "held")
        try d.undo(); #expect(d.snapshot.text == "kp0xabc")
        try d.redo(); #expect(d.snapshot.text == "2kp30xabc")
        try e.type("4", historyGroup: "held")
        try d.undo(); #expect(d.snapshot.text == "2kp30xabc")
        // While held, a composition that records nothing still separates other groups' steps.
        try e.type("Q", historyGroup: "typing")
        try e.beginComposition(); try e.updateComposition(""); try e.commitComposition()
        try e.type("R", historyGroup: "typing")
        try d.undo(); #expect(d.snapshot.text.contains("Q") && !d.snapshot.text.contains("R"))
        try d.undo(); #expect(d.snapshot.text == "2kp30xabc")
        try d.endHistoryGroup()
    }
    @Test func multilinePatternsMatchEveryLineBreak() throws {
        let regex = SearchOptions(regularExpression: true)
        for eol in [EndOfLine.lf, .crlf] {
            let d = Document(id: "multiline", text: "x foo\nbar\nfoo\nbaz", endOfLine: eol)
            let first = TextRange(Position(0,2),Position(1,1)), second = TextRange(Position(2,0),Position(3,1))
            #expect(try d.snapshot.search("foo\\n(b)", options: regex).map(\.range) == [first, second])
            #expect(try d.snapshot.search("foo\\n(b)", options: regex).map { $0.captures[1] } == ["b","b"])
            #expect(try d.snapshot.search("o\\Wb", options: regex).count == 2)
            #expect(try d.snapshot.search("foo\nb").map(\.range) == [first, second])
            #expect(try d.snapshot.search("foo\\nb", options: regex, in: TextRange(Position(1,0),Position(3,3))).map(\.range) == [second])
            let trailing = Document(id: "trailing", text: "ab\n", endOfLine: eol)
            #expect(try trailing.snapshot.search("^$|\\n", options: regex).map(\.range)
                == [TextRange(Position(0,2),Position(1,0)), TextRange(Position(1,0),Position(1,0))])
            #expect(try trailing.snapshot.search("b\\n|$", options: regex).map(\.range) == [TextRange(Position(0,1),Position(1,0)), TextRange(Position(1,0),Position(1,0))])
            #expect(try trailing.snapshot.search("(?<!\\n)$|\\n", options: regex).count == 1)
            try d.replaceAll("foo\\n(b)", with: "$1", options: regex)
            #expect(d.snapshot.text == "x bar\nbaz".replacingOccurrences(of: "\n", with: eol.rawValue))
        }
    }
    @Test func searchesAndReplacements() throws {
        let d = Document(id: "search", text: "One one stone\nfoo12 foo34 😀")
        #expect(try d.snapshot.search("one", options: .init(caseSensitive: false,wholeWord: true)).count == 2)
        let regex = SearchOptions(regularExpression: true)
        #expect(try d.snapshot.search("foo([0-9]+)",options: regex).map { $0.captures[1] } == ["12","34"])
        try d.replaceAll("foo([0-9]+)",with: "$1-$$",options: regex)
        #expect(d.snapshot.text == "One one stone\n12-$ 34-$ 😀")
        try d.undo(); #expect(d.snapshot.text == "One one stone\nfoo12 foo34 😀")
        #expect(throws: (any Error).self) { try d.snapshot.search("[",options: regex) }
        let scoped = TextRange(Position(0,4),Position(0,7))
        #expect(try d.snapshot.search("one",in: scoped).count == 1)
    }
    @Test func scopesLimitMatchesWithoutHidingSurroundingText() throws {
        let regex = SearchOptions(regularExpression: true)
        for eol in [EndOfLine.lf, .crlf] {
            let d = Document(id: "scope", text: "a stone\nfoo bar", endOfLine: eol)
            let inWord = TextRange(Position(0,4),Position(0,7))
            #expect(try d.snapshot.search("one", options: .init(wholeWord: true), in: inWord).isEmpty)
            #expect(try d.snapshot.search("one", options: .init(regularExpression: true, wholeWord: true), in: inWord).isEmpty)
            #expect(try d.snapshot.search("\\bone", options: regex, in: inWord).isEmpty)
            #expect(try d.snapshot.search("(?<=st)one", options: regex, in: inWord).map(\.range) == [inWord])
            #expect(try d.snapshot.search("^", options: regex, in: inWord).isEmpty)
            #expect(try d.snapshot.search("on$", options: regex, in: TextRange(Position(0,4),Position(0,6))).isEmpty)
            try d.replaceAll("one", with: "X", options: .init(wholeWord: true), in: inWord)
            #expect(d.snapshot.text == "a stone\nfoo bar".replacingOccurrences(of: "\n", with: eol.rawValue))
            let acrossLines = TextRange(Position(0,4),Position(1,3))
            #expect(try d.snapshot.search("^\\w+\\n", options: regex, in: acrossLines).isEmpty)
            #expect(try d.snapshot.search("\\w+$\\n^foo", options: regex, in: acrossLines).map(\.range) == [acrossLines])
            #expect(try d.snapshot.search("one\\nfoo\\b", options: regex, in: acrossLines).map(\.range) == [acrossLines])
            #expect(try d.snapshot.search("one\\nfo", options: regex, in: TextRange(Position(0,4),Position(1,2))).map(\.range)
                == [TextRange(Position(0,4),Position(1,2))])
            #expect(try d.snapshot.search("one\\nfo\\b", options: regex, in: TextRange(Position(0,4),Position(1,2))).isEmpty)
        }
    }
    @Test func seededEditsAgainstFlatReference() throws {
        var state: UInt64 = 0x1234abcd
        func random(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1; return Int((state >> 32) % UInt64(n)) }
        for eol in [EndOfLine.lf, .crlf] {
            var model = Array(String(repeating: "abc😀e\u{301}\n",count: 1800).replacingOccurrences(of:"\n",with:eol.rawValue).utf16)
            let d = Document(id: "random", text: String(decoding:model,as:UTF16.self),endOfLine:eol)
            var versions = [String(decoding:model,as:UTF16.self)]
            func legal(_ i: Int) -> Bool {
                if i == 0 || i == model.count { return true }
                return !((0xD800...0xDBFF).contains(model[i-1]) && (0xDC00...0xDFFF).contains(model[i]) || model[i-1] == 13 && model[i] == 10)
            }
            func position(_ offset: Int) -> Position {
                var line = 0, start = 0
                for i in 0..<offset where model[i] == 10 { line += 1; start = i + 1 }
                return Position(line,offset-start)
            }
            let inputs = ["x","😀","\n","e\u{301}","👨‍👩‍👧‍👦","","\r\n"]
            for step in 0..<300 {
                var a = random(model.count + 1), b: Int
                while !legal(a) { a = random(model.count + 1) }
                b = min(model.count, a + random(12)); while !legal(b) { b -= 1 }
                let text = inputs[random(inputs.count)]
                let replacement = text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\n",with:eol.rawValue)
                let p = position(a), q = position(b), oldVersion = d.version
                try d.apply([TextEdit(TextRange(p,q),text)])
                model.replaceSubrange(a..<b,with:replacement.utf16)
                #expect(d.snapshot.text.utf16.elementsEqual(model), "step \(step)")
                if oldVersion != d.version { versions.append(d.snapshot.text) }
                for _ in 0..<6 {
                    var i = random(model.count + 1); while !legal(i) { i = random(model.count + 1) }
                    let expected = position(i)
                    #expect(try d.snapshot.position(at:i) == expected)
                    #expect(try d.snapshot.offset(at:expected) == i)
                }
            }
            for text in versions.dropLast().reversed() { try d.undo(); #expect(d.snapshot.text == text) }
            #expect(!d.canUndo)
            for text in versions.dropFirst() { try d.redo(); #expect(d.snapshot.text == text) }
            #expect(!d.canRedo)
        }
    }
    @Test func listenersRunInOrderAndSkipThoseCancelledEarlier() throws {
        let d = Document(id:"listeners",text:"")
        var calls: [String] = [], second: Subscription?
        let first = try d.observe { _ in calls.append("first"); second?.cancel() }
        second = try d.observe { _ in calls.append("second") }
        let third = try d.observe { _ in calls.append("third") }
        try d.apply([TextEdit(r(0,0),"a")])
        #expect(calls == ["first","third"])
        first.cancel(); third.cancel()
    }
    @Test func rangesOutsideSimultaneousEditsMoveWithTheText() throws {
        var state: UInt64 = 0x5eed
        func random(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1; return Int((state >> 32) % UInt64(n)) }
        for eol in [EndOfLine.lf, .crlf] {
            var model = Array(String(repeating: "ab😀 cd\nef\n", count: 12).replacingOccurrences(of: "\n", with: eol.rawValue).utf16)
            let d = Document(id: "outside", text: String(decoding: model, as: UTF16.self), endOfLine: eol)
            func legal(_ i: Int) -> Bool {
                if i == 0 || i == model.count { return true }
                return !((0xD800...0xDBFF).contains(model[i-1]) && (0xDC00...0xDFFF).contains(model[i]) || model[i-1] == 13 && model[i] == 10)
            }
            func position(_ offset: Int) -> Position {
                var line = 0, start = 0
                for i in 0..<offset where model[i] == 10 { line += 1; start = i + 1 }
                return Position(line, offset - start)
            }
            func legalOffset() -> Int { var i = random(model.count + 1); while !legal(i) { i = random(model.count + 1) }; return i }
            for _ in 0..<60 {
                var ranges: [(UUID, Int, Int)] = []
                for _ in 0..<40 {
                    let a = legalOffset(), b = legalOffset()
                    ranges.append((try d.trackRange(TextRange(position(min(a,b)), position(max(a,b)))), min(a,b), max(a,b)))
                }
                // Short spans, one in each half, keep the document from shrinking away.
                let candidates = (0...model.count).filter(legal), n = candidates.count
                let i = random(n / 2 - 4), j = n / 2 + random(n / 2 - 3)
                let spans = [(candidates[i], candidates[i + random(3)]), (candidates[j], candidates[j + random(3)])]
                let texts = ["x", "😀\ny", ""]
                let edits = spans.map { TextEdit(TextRange(position($0.0), position($0.1)), texts[random(texts.count)]) }
                let replacements = edits.map { Array($0.text.replacingOccurrences(of: "\n", with: eol.rawValue).utf16) }
                let first = spans[0].0, last = spans[1].1
                let delta = zip(spans, replacements).reduce(0) { $0 + $1.1.count - ($1.0.1 - $1.0.0) }
                try d.apply(edits)
                for (span, replacement) in zip(spans, replacements).reversed() { model.replaceSubrange(span.0..<span.1, with: replacement) }
                for (id, start, end) in ranges where (start < first || start > last) && (end < first || end > last) {
                    let moved = { (offset: Int) in offset < first ? offset : offset + delta }
                    #expect(try d.trackedRange(id: id)?.range == TextRange(position(moved(start)), position(moved(end))))
                }
                for (id, _, _) in ranges { try d.removeTrackedRange(id: id) }
                #expect(d.snapshot.text.utf16.elementsEqual(model))
            }
        }
    }
    @Test func subscriptionsSnapshotsAndDisposal() throws {
        let d = Document(id:"lifetime",text:"a")
        let saved = d.snapshot
        var events = 0
        let subscription = try d.observe { _ in
            events += 1
            #expect(throws: EditorError.reentrantMutation) { try d.apply([TextEdit(self.r(0,0),"x")]) }
        }
        try d.apply([TextEdit(r(0,0),"b")]); #expect(events == 1)
        subscription.cancel(); try d.apply([TextEdit(r(0,0),"c")]); #expect(events == 1)
        try d.dispose()
        #expect(throws: EditorError.disposed) { try d.apply([]) }
        #expect(saved.text == "a")
    }
    @Test func replacementTemplatesHonorFoundationEscapesAndCaptureNumbers() throws {
        let pattern = "(a)(b)?"
        let regex = try NSRegularExpression(pattern: pattern)
        for template in [#"\$1"#, "$12", #"\\$1"#, "$0-$1-$2", #"\$12"#, #"x\ny"#] {
            for eol in [EndOfLine.lf, .crlf] {
                let original = "a" + eol.rawValue + "ab"
                let expected = regex.stringByReplacingMatches(in: original,
                    range: NSRange(location: 0, length: original.utf16.count), withTemplate: template)
                let document = Document(id: "replacement", text: original, endOfLine: eol)
                try document.replaceAll(pattern, with: template, options: .init(regularExpression: true))
                #expect(Array(document.snapshot.text.utf16) == Array(expected.utf16))
                if expected != original {
                    try document.undo(); #expect(document.snapshot.text == original)
                    try document.redo(); #expect(document.snapshot.text == expected)
                }
            }
        }
        let document = Document(id: "dollars", text: "a")
        try document.replaceAll("(a)", with: "$$-$1", options: .init(regularExpression: true))
        #expect(document.snapshot.text == "$-a")
    }
    @Test func newlineNormalizationPreservesExactUnicodeUnits() throws {
        let suffixes = ["\u{301}", "\u{308}\u{301}", "😀", "e\u{301}"]
        for eol in [EndOfLine.lf, .crlf] {
            for newline in ["\n", "\r", "\r\n"] {
                for suffix in suffixes {
                    let expected = eol.rawValue + suffix
                    let document = Document(id: "unicode", text: newline + suffix, endOfLine: eol)
                    #expect(Array(document.snapshot.text.utf16) == Array(expected.utf16))
                    #expect(try document.snapshot.offset(at: Position(0, 0)) == 0)
                    #expect(try document.snapshot.line(0) == "")
                    #expect(Array(try document.snapshot.line(1).utf16) == Array(suffix.utf16))
                    try document.apply([TextEdit(document.snapshot.fullRange, newline + suffix + "x")])
                    #expect(Array(document.snapshot.text.utf16) == Array((expected + "x").utf16))
                    try document.undo()
                    #expect(Array(document.snapshot.text.utf16) == Array(expected.utf16))
                    try document.redo()
                    #expect(Array(document.snapshot.text.utf16) == Array((expected + "x").utf16))
                }
            }
        }
    }
    @Test func unicodeNewlineUndoKeepsTrackedRangesValidForTheNextEdit() throws {
        for eol in [EndOfLine.lf, .crlf] {
            let document = Document(id: "undo", endOfLine: eol)
            try document.apply([TextEdit(document.snapshot.fullRange, "\n")])
            try document.apply([TextEdit(TextRange(Position(1, 0), Position(1, 0)), "\u{301}")])
            let original = Array(document.snapshot.text.utf16)
            let marker = try document.trackRange(TextRange(Position(1, 0), Position(1, 1)), stickiness: .growBoth)
            let session = try EditorSession(document: document)
            try session.setSelections([Selection(Position(1, 1))])
            try document.apply([TextEdit(document.snapshot.fullRange, "replacement")])
            try document.undo()
            #expect(Array(document.snapshot.text.utf16) == original)
            let range = try #require(document.trackedRange(id: marker)?.range)
            // Validate before editing so a corrupt range reports a test failure
            // instead of terminating the entire runner in range tracking.
            _ = try document.snapshot.offsets(in: range)
            #expect(session.selections == [Selection(Position(1, 1))])
            try document.apply([TextEdit(TextRange(Position(1, 1), Position(1, 1)), "x")])
            #expect(Array(document.snapshot.text.utf16) == Array((eol.rawValue + "\u{301}x").utf16))
            _ = try document.snapshot.offsets(in: try #require(document.trackedRange(id: marker)?.range))
            try document.undo(); try document.undo(); try document.redo()
            _ = try document.snapshot.offsets(in: try #require(document.trackedRange(id: marker)?.range))
            try session.dispose()
        }
    }
    @Test func regexAnchorsSearchAndReplaceEachLogicalLine() throws {
        let regex = SearchOptions(regularExpression: true)
        for eol in [EndOfLine.lf, .crlf] {
            let document = Document(id: "anchors", text: "a\nfoo\nb\n", endOfLine: eol)
            #expect(try document.snapshot.search("^foo$", options: regex).map(\.range) == [TextRange(Position(1, 0), Position(1, 3))])
            #expect(try document.snapshot.search("^", options: regex).map { $0.range.start } == [Position(0, 0), Position(1, 0), Position(2, 0), Position(3, 0)])
            #expect(try document.snapshot.search("$", options: regex).map { $0.range.start } == [Position(0, 1), Position(1, 3), Position(2, 1), Position(3, 0)])
            try document.replaceAll("^", with: ">", options: regex)
            #expect(document.snapshot.text == [">a", ">foo", ">b", ">"].joined(separator: eol.rawValue))
            try document.undo()
            try document.replaceAll("$", with: "!", options: regex)
            #expect(document.snapshot.text == ["a!", "foo!", "b!", "!"].joined(separator: eol.rawValue))
            try document.undo()
            #expect(document.snapshot.text == ["a", "foo", "b", ""].joined(separator: eol.rawValue))
            #expect(try document.snapshot.search("^FOO$", options: .init(regularExpression: true, caseSensitive: false)).count == 1)
            #expect(try document.snapshot.search("^a\\r?\\nfoo$", options: regex).map(\.range) == [TextRange(Position(0, 0), Position(1, 3))])
            #expect(try document.snapshot.search("^$", options: regex).map(\.range) == [TextRange(Position(3, 0), Position(3, 0))])
            let scoped = TextRange(Position(1, 1), Position(1, 3))
            #expect(try document.snapshot.search("^oo$", options: regex, in: scoped).isEmpty)
            #expect(try document.snapshot.search("oo$", options: regex, in: scoped).map(\.range) == [scoped])
            let wholeLine = TextRange(Position(1, 0), Position(1, 3))
            #expect(try document.snapshot.search("^foo$", options: regex, in: wholeLine).map(\.range) == [wholeLine])
            let empty = Document(id: "empty", endOfLine: eol)
            #expect(try empty.snapshot.search("^$", options: regex).map(\.range) == [empty.snapshot.fullRange])
        }
    }
    @Test func regexEngineFailuresThrowInsteadOfDroppingMatches() throws {
        // A long subject exhausts ICU's backtracking stack for this pattern.
        for text in [String(repeating: "ab", count: 250_000) + "c\nabc", "abc\n" + String(repeating: "ab", count: 250_000) + "c"] {
            let document = Document(id: "overflow", text: text)
            let options = SearchOptions(regularExpression: true)
            // Line by line, and across lines, where the whole document is one subject.
            for pattern in ["(.)*c", "(.|\\n)*c"] {
                #expect(throws: EditorError.searchFailed) { try document.snapshot.search(pattern, options: options) }
                #expect(throws: EditorError.searchFailed) { try document.replaceAll(pattern, with: "x", options: options) }
            }
            #expect(document.snapshot.text == text && document.version == 1)
        }
    }
    @Test func endpointsAtTheStartOfReplacedTextStayBeforeTheNewText() throws {
        let d = Document(id: "boundary", text: "abcdefgh")
        let typing = try EditorSession(document: d), other = try EditorSession(document: d)
        try other.setSelections([Selection(Position(0, 3))])
        let inside = try d.trackRange(TextRange(Position(0, 3), Position(0, 8)))
        let before = try d.trackRange(TextRange(Position(0, 0), Position(0, 3)), stickiness: .growBoth)
        let exact = try d.trackRange(TextRange(Position(0, 3), Position(0, 5)))
        try typing.setSelections([Selection(anchor: Position(0, 3), head: Position(0, 5))])
        try typing.type("xyz")
        #expect(d.snapshot.text == "abcxyzfgh")
        // The replaced text was inside the first range and outside the second.
        #expect(try d.trackedRange(id: inside)?.range == TextRange(Position(0, 3), Position(0, 9)))
        #expect(try d.trackedRange(id: before)?.range == TextRange(Position(0, 0), Position(0, 3)))
        #expect(try d.trackedRange(id: exact)?.range == TextRange(Position(0, 3), Position(0, 6)))
        #expect(other.selections == [Selection(Position(0, 3))])
        #expect(typing.selections == [Selection(Position(0, 6))])
    }
    @Test func theTrailingEmptyLineMatchesLineAnchorsOnly() throws {
        for eol in [EndOfLine.lf, .crlf] {
            let d = Document(id: "tail", text: "ab\n", endOfLine: eol)
            let regex = SearchOptions(regularExpression: true)
            #expect(try d.snapshot.search("^", options: regex).map(\.range.start) == [Position(0, 0), Position(1, 0)])
            #expect(try d.snapshot.search("^$\\n?", options: regex).map(\.range.start) == [Position(1, 0)])
            #expect(try d.snapshot.search("\\A|\\n", options: regex).map(\.range.start) == [Position(0, 0), Position(0, 2)])
            #expect(try d.snapshot.search("(?=\\n)", options: regex).map(\.range.start) == [Position(0, 2)])
            try d.replaceAll("\\A|\\n", with: "X", options: regex)
            #expect(d.snapshot.text == "XabX")
        }
    }
    @Test func onlyLineFeedsEndLogicalLinesInPatterns() throws {
        let regex = SearchOptions(regularExpression: true)
        for separator in ["\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            let d = Document(id: "separators", text: "a\(separator)b")
            #expect(try d.snapshot.search("^b", options: regex).isEmpty)
            #expect(try d.snapshot.search("a$", options: regex).isEmpty)
            #expect(try d.snapshot.search("a.b", options: regex).count == 1)
            #expect(try d.snapshot.search("^", options: regex).count == 1)
        }
    }
    @Test func editsThatCancelOutOnceMergedAreNoOps() throws {
        let d = Document(id: "cancel", text: "ab")
        var events = 0
        let observation = try d.observe { _ in events += 1 }
        try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 1)), ""), TextEdit(TextRange(Position(0, 1), Position(0, 1)), "a")])
        #expect(d.snapshot.text == "ab" && d.version == 1 && !d.canUndo && events == 0)
        // A no-op part next to a real change still merges into one change.
        try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 1)), "a"), TextEdit(TextRange(Position(0, 1), Position(0, 2)), "c")])
        #expect(d.snapshot.text == "ac" && d.version == 2)
        try d.undo()
        #expect(d.snapshot.text == "ab")
        observation.cancel()
    }
    @Test func differentHistoryGroupsAreSeparateUndoSteps() throws {
        let d = Document(id: "groups", text: "")
        try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "a")], historyGroup: "typing")
        try d.apply([TextEdit(TextRange(Position(0, 1), Position(0, 1)), "b")], historyGroup: "typing")
        try d.apply([TextEdit(TextRange(Position(0, 2), Position(0, 2)), "c")], historyGroup: "paste")
        try d.undo()
        #expect(d.snapshot.text == "ab")
        try d.undo()
        #expect(d.snapshot.text == "" && !d.canUndo)
    }
    @Test func wholeWordEdgesFollowTheMatchedCharacters() throws {
        let d = Document(id: "words", text: "foo foo_bar foo1 bar_foo #heading foo.bar")
        for regex in [false, true] {
            let options = SearchOptions(regularExpression: regex, wholeWord: true)
            // Digits and underscore are word characters.
            #expect(try d.snapshot.search("foo", options: options).map(\.range.start) == [Position(0, 0), Position(0, 34)])
            // A match whose own edge character is a separator needs no separator beside it.
            #expect(try d.snapshot.search("#", options: options).map(\.range.start) == [Position(0, 25)])
            #expect(try d.snapshot.search(regex ? "foo\\." : "foo.", options: options).map(\.range.start) == [Position(0, 34)])
            #expect(try d.snapshot.search("head", options: options).isEmpty)
        }
    }
    @Test func versionsKeepIncreasingThroughHistoryAndComposition() throws {
        let d = Document(id: "versions", text: "a")
        let session = try EditorSession(document: d)
        var last = d.version
        func advanced() -> Bool { defer { last = d.version }; return d.version > last }
        try session.type("b"); #expect(advanced())
        let edited = d.version
        try d.undo(); #expect(advanced())
        try d.redo(); #expect(advanced())
        try session.beginComposition(); try session.updateComposition("c"); #expect(advanced())
        try session.cancelComposition(); #expect(advanced())
        #expect(throws: EditorError.staleVersion(expected: edited, actual: d.version)) {
            try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "x")], expectedVersion: edited)
        }
    }
    @Test func searchRejectsBadScopesAndPatterns() throws {
        let d = Document(id: "bad", text: "foo # c")
        #expect(throws: EditorError.invalidPosition) { try d.snapshot.search("", in: TextRange(Position(5, 0), Position(9, 0))) }
        #expect(throws: EditorError.invalidPattern) { try d.snapshot.search("(", options: SearchOptions(regularExpression: true)) }
        // Whole-word search leaves the pattern itself alone, so free-spacing comments still work.
        let options = SearchOptions(regularExpression: true, wholeWord: true)
        #expect(try d.snapshot.search("(?x) foo # comment", options: options).map(\.range.start) == [Position(0, 0)])
    }
    @Test func literalReplacementsAreInsertedVerbatim() throws {
        let d = Document(id: "verbatim", text: "price: 5")
        try d.replaceAll("price", with: "$1 $$ \\1 $0")
        #expect(d.snapshot.text == "$1 $$ \\1 $0: 5")
    }
    @Test func lineStartsAtTheEndKeepOtherAnchorsIntact() throws {
        for eol in [EndOfLine.lf, .crlf] {
            let d = Document(id: "anchors", text: "ab\n", endOfLine: eol)
            let regex = SearchOptions(regularExpression: true)
            func starts(_ pattern: String) throws -> [Position] { try d.snapshot.search(pattern, options: regex).map(\.range.start) }
            #expect(try starts("\\A|(?=\\n)") == [Position(0, 0), Position(0, 2)])
            #expect(try starts("^\\n?") == [Position(0, 0), Position(1, 0)])
            // A negated class, an escaped caret and a quoted caret are not anchors.
            #expect(try starts("[^a\\n]\\n") == [Position(0, 1)])
            #expect(try starts("\\^|\\Q^\\E|\\n") == [Position(0, 2)])
        }
    }
}
