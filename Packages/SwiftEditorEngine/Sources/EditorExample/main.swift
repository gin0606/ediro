import EditorEngine

@main struct Example {
    @MainActor static func main() async throws {
        let engine = EditorWorkspace()
        let document = try engine.createDocument(id: "example.swift", text: "pri\nsecond line\n", language: "swift")
        let editor = try EditorSession(document: document)
        let events = try document.observe { event in print("event: \(event.kind), version: \(event.version)") }
        let provider = try engine.register(language: "swift", features: [.completion, .diagnostics], provider: ClosureProvider { request in
            switch request.feature {
            case .completion:
                return .completion([CompletionItem(label: "print", edit: WorkspaceEdit([DocumentEdits(
                    snapshot: request.snapshot,
                    edits: [TextEdit(TextRange(Position(0,0), Position(0,3)), "print")])]))])
            case .diagnostics:
                return .diagnostics([Diagnostic(range: TextRange(Position(0,0), Position(0,5)), severity: .information, message: "Example provider diagnostic")])
            default: throw EditorError.invalidProviderResult
            }
        })
        try editor.move(.lineEnd)
        let completion = try await engine.request(documentID: document.id, feature: .completion, position: editor.selections[0].head)
        try engine.apply(completion)
        try editor.type("(\"Hello\")")
        _ = try await engine.request(documentID: document.id, feature: .diagnostics)
        let fold = FoldingRange(range: TextRange(Position(0,0), Position(1,11)))
        try document.setFoldingRanges([fold], version: document.version)
        try editor.setCollapsed(true, foldID: fold.id)
        print("diagnostics: \(try document.semantics().diagnostics.count), hidden: \(try editor.hiddenLineRanges())")
        try document.undo(); try document.redo()
        print(document.snapshot.text)
        events.cancel(); provider.cancel(); try engine.dispose()
    }
}
