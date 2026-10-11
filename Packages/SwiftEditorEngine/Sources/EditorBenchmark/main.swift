import EditorEngine
import Foundation

@main struct Benchmark {
    @MainActor static func main() throws {
        let clock = ContinuousClock()
        func measure(_ label: String, _ body: () throws -> Void) rethrows {
            let start = clock.now; try body(); print("\(label): \(start.duration(to: clock.now))")
        }
        for lines in [1_000, 10_000, 50_000] {
            let text = String(repeating: "let value = 12345 // benchmark 😀\n", count: lines)
            print("lines=\(lines), UTF16=\(text.utf16.count), edits=200, conversions=1000, searches=5, comparison edits=20")
            var document: Document!
            measure("load") { document = Document(id: "benchmark", text: text) }
            try measure("local edits (history retained)") {
                for i in 0..<200 { let p = Position(lines / 2, i % 10); try document.apply([TextEdit(TextRange(p,p), "x")]) }
            }
            try measure("position roundtrips") {
                for i in 0..<1000 { let p = Position(i % lines, 5); let offset = try document.snapshot.offset(at: p); _ = try document.snapshot.position(at: offset) }
            }
            try measure("literal search") { for _ in 0..<5 { _ = try document.snapshot.search("value") } }
            let highlighted = Document(id: "tokens", text: text)
            let starts = [0, 4, 10, 12, 18, 21], ends = [3, 9, 11, 17, 20, 30]
            let tokens = (0..<lines).flatMap { line in
                zip(starts, ends).map { HighlightToken(range: TextRange(Position(line, $0), Position(line, $1)), kind: "word") }
            }
            try highlighted.setTokens(tokens, version: highlighted.version)
            try measure("local edits with \(tokens.count) tracked tokens") {
                for i in 0..<200 { let p = Position(lines / 2, i % 10); try highlighted.apply([TextEdit(TextRange(p,p), "x")]) }
            }
            try measure("replace all with \(tokens.count) tracked tokens") { try highlighted.replaceAll("value", with: "amount") }
            try highlighted.dispose()
            let comparison = Document(id: "rope-comparison", text: text)
            try measure("rope comparison (20 local edits with history)") {
                for i in 0..<20 { let p = Position(lines / 2, i % 10); try comparison.apply([TextEdit(TextRange(p,p), "x")]) }
            }
            var flat = Array(text.utf16)
            let midpoint = flat.count / 2
            measure("flat UTF16 baseline edits with retained snapshots") {
                var snapshots: [[UInt16]] = []; snapshots.reserveCapacity(20)
                for i in 0..<20 { snapshots.append(flat); flat.insert(120, at: midpoint + i % 10) }
                precondition(snapshots.count == 20)
            }
            try comparison.dispose(); try document.dispose()
        }
    }
}
