import Testing
import Foundation
@testable import EditorEngine

@Suite(.serialized) @MainActor struct RopeTests {
    @Test func editsKeepTheTreeBalanced() throws {
        let d = Document(id: "balance", text: String(repeating: "line of text\n", count: 2_000))
        var seed: UInt64 = 0x5eed
        for i in 0..<3_000 {
            seed = seed &* 6364136223846793005 &+ 1
            let offset = Int((seed >> 33) % UInt64(d.snapshot.utf16Count))
            // The text is ASCII with LF line breaks, so every offset is a valid boundary.
            let p = try d.snapshot.position(at: offset)
            let text = i % 50 == 0 ? String(repeating: "x", count: 3_000) : "y"
            try d.apply([TextEdit(TextRange(p, p), text)])
        }
        let root = try #require(d.root)
        func leaves(_ node: RopeNode) -> Int { node.left.map { leaves($0) + leaves(node.right!) } ?? 1 }
        let count = leaves(root)
        func leafSizes(_ node: RopeNode) -> [Int] { node.left.map { leafSizes($0) + leafSizes(node.right!) } ?? [node.units.count] }
        // Local edits copy bounded leaves.
        #expect(leafSizes(root).allSatisfy { $0 <= 1_024 })
        // Height stays within a constant factor of the balanced minimum.
        #expect(Double(root.height) <= 2 * (log2(Double(count)) + 2), "height \(root.height) for \(count) leaves")
    }
    @Test func editsShareUntouchedSubtrees() throws {
        let d = Document(id: "sharing", text: String(repeating: "line of text\n", count: 20_000))
        let before = try #require(d.root)
        try d.apply([TextEdit(TextRange(Position(10_000, 3), Position(10_000, 3)), "x")])
        let after = try #require(d.root)
        func nodes(_ node: RopeNode) -> [RopeNode] { [node] + (node.left.map(nodes) ?? []) + (node.right.map(nodes) ?? []) }
        let old = Set(nodes(before).map(ObjectIdentifier.init))
        let fresh = nodes(after).filter { !old.contains(ObjectIdentifier($0)) }
        // Only the path to the edited leaf is new; the rest is shared with the earlier snapshot.
        #expect(fresh.count <= 4 * after.height, "\(fresh.count) new nodes for height \(after.height)")
    }
}
