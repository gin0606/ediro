import Testing
import Foundation
import EditorEngine

typealias TextRange = EditorEngine.TextRange

@MainActor final class GateProvider: LanguageProvider {
    var pending: [(LanguageRequest, CheckedContinuation<LanguageResult, Error>)] = []
    var cancellations: [Int: Bool] = [:]
    private var starts: [(Int, CheckedContinuation<Void, Never>)] = []
    func provide(_ request:LanguageRequest) async throws -> LanguageResult {
        let index = pending.count
        let result: LanguageResult = try await withCheckedThrowingContinuation {
            pending.append((request, $0))
            let ready = starts.filter { $0.0 <= pending.count }
            starts.removeAll { $0.0 <= pending.count }
            for (_, continuation) in ready { continuation.resume() }
        }
        cancellations[index] = Task.isCancelled
        return result
    }
    func waitFor(_ count:Int) async throws {
        if pending.count >= count { return }
        await withCheckedContinuation { starts.append((count, $0)) }
    }
    func finish(_ index:Int,_ result:LanguageResult) { pending[index].1.resume(returning:result) }
    /// The provider task records cancellation after it resumes, which can follow the caller.
    func cancellation(_ index: Int) async -> Bool {
        while cancellations[index] == nil { await Task.yield() }
        return cancellations[index]!
    }
}

/// A provider that never finishes on its own, either stopping on cancellation or ignoring it.
@MainActor final class StallingProvider: LanguageProvider {
    let honorsCancellation: Bool
    var started = 0
    private var held: [CheckedContinuation<LanguageResult, Error>] = []
    init(honorsCancellation: Bool) { self.honorsCancellation = honorsCancellation }
    func provide(_ request: LanguageRequest) async throws -> LanguageResult {
        started += 1
        if honorsCancellation { try await Task.sleep(for: .seconds(3600)); return .hover(nil) }
        return try await withCheckedThrowingContinuation { held.append($0) }
    }
    func release() { for continuation in held { continuation.resume(returning: .hover(nil)) }; held = [] }
}

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct LanguageTests {
    func edit(_ request:LanguageRequest,_ text:String) -> WorkspaceEdit {
        WorkspaceEdit([DocumentEdits(documentID:request.snapshot.documentID,expectedVersion:request.snapshot.version,
            edits:[TextEdit(request.snapshot.fullRange,text)])])
    }
    @Test func everyLanguageFeatureAndEditingApplication() async throws {
        let engine = EditorWorkspace()
        let d = try engine.createDocument(id:"language",text:"abc\nxyz",language:"test")
        let token = try engine.register(language:"test",features:Set(LanguageFeature.allCases),provider:ClosureProvider { request in
            let range = request.snapshot.fullRange
            switch request.feature {
            case .completion: return .completion([CompletionItem(label:"completed",edit:self.edit(request,"completed\nxyz"))])
            case .hover: return .hover(Hover(range:range,contents:["documentation"]))
            case .signatureHelp: return .signatureHelp(SignatureHelp(signatures:[Signature(label:"call(a)",parameters:["a"])],activeParameter:0))
            case .definition: return .definition([DocumentLocation(documentID:d.id,range:range)])
            case .references: return .references([DocumentLocation(documentID:d.id,range:range)])
            case .documentSymbols: return .documentSymbols([DocumentSymbol(name:"root",kind:"function",range:range,selectionRange:TextRange(Position(0,0),Position(0,1)))])
            case .rename: return .rename(self.edit(request, "renamed\nxyz"))
            case .codeActions: return .codeActions([CodeAction(title:"Fix",kind:"quickfix",edit:self.edit(request,"fixed\nxyz"))])
            case .formatting: return .formatting(self.edit(request,"formatted\nxyz"))
            case .tokens: return .tokens([HighlightToken(range:range,kind:"lexical")])
            case .semanticTokens: return .semanticTokens([HighlightToken(range:range,kind:"function",modifiers:["declaration"])])
            case .diagnostics: return .diagnostics([Diagnostic(range:range,severity:.error,message:"problem")])
            case .folding: return .folding([FoldingRange(range:range)])
            case .inlayHints: return .inlayHints([InlayHint(position:Position(0,0),label:"hint",edits:[TextEdit(TextRange(Position(0,0),Position(0,0)),"hint")])])
            }
        })
        // Spelled out, because the undo checks below depend on the order the edits are applied in.
        let features: [LanguageFeature] = [.completion, .hover, .signatureHelp, .definition, .references, .documentSymbols,
                                           .rename, .codeActions, .formatting, .tokens, .semanticTokens, .diagnostics, .folding, .inlayHints]
        #expect(Set(features) == Set(LanguageFeature.allCases))
        for feature in features {
            let response = try await engine.request(documentID:d.id,feature:feature,position:Position(0,0),range:d.snapshot.fullRange,newName:"renamed")
            #expect(response.result.feature == feature)
            guard case .ready(let retained) = engine.status(documentID:d.id,feature:feature) else { Issue.record("Result not retained"); continue }
            #expect(retained.result == response.result)
            switch response.result {
            case .completion(let items): #expect(items[0].label == "completed"); try engine.apply(response); #expect(d.snapshot.text == "completed\nxyz")
            case .hover(let hover): #expect(hover?.contents == ["documentation"])
            case .signatureHelp(let help): #expect(help?.activeParameter == 0)
            case .definition(let locations), .references(let locations): #expect(locations[0].documentID == d.id)
            case .documentSymbols(let symbols): #expect(symbols[0].name == "root")
            case .rename: try engine.apply(response); #expect(d.snapshot.text == "renamed\nxyz")
            case .codeActions: try engine.apply(response); #expect(d.snapshot.text == "fixed\nxyz")
            case .formatting: try engine.apply(response); #expect(d.snapshot.text == "formatted\nxyz")
            case .tokens: #expect(try d.semantics().tokens[0].kind == "lexical")
            case .semanticTokens: #expect(try d.semantics().semanticTokens[0].modifiers == ["declaration"])
            case .diagnostics: #expect(try d.semantics().diagnostics[0].message == "problem")
            case .folding: #expect(try d.semantics().foldingRanges.count == 1)
            case .inlayHints:
                let hints = try d.semantics().inlayHints
                #expect(hints[0].label == "hint")
                try d.apply(hints[0].edits,expectedVersion:response.version)
                #expect(d.snapshot.text.hasPrefix("hint"))
            }
        }
        try d.undo(); #expect(d.snapshot.text == "formatted\nxyz")
        try d.undo(); #expect(d.snapshot.text == "fixed\nxyz")
        try d.redo(); #expect(d.snapshot.text == "formatted\nxyz")
        token.cancel(); await #expect(throws:EditorError.noProvider) { try await engine.request(documentID:d.id,feature:.hover) }
        try engine.dispose()
    }
    @Test func notificationsReportEveryChangedState() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "changes", text: "# A\na\nb", language: "md")
        let session = try EditorSession(document: d)
        var events: [(ChangeKind, DocumentChanges)] = []
        let observation = try d.observe { events.append(($0.kind, $0.changes)) }
        defer { observation.cancel() }
        func expectEvents(_ expected: [(ChangeKind, DocumentChanges)], sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(events.map(\.0) == expected.map(\.0), sourceLocation: sourceLocation)
            #expect(events.map(\.1) == expected.map(\.1), sourceLocation: sourceLocation)
            events = []
        }
        let fold = FoldingRange(range: TextRange(Position(0, 0), Position(2, 0)))
        let registration = try workspace.register(language: "md", features: [.folding], provider: ClosureProvider { _ in .folding([fold]) })
        expectEvents([(.language, [])])
        _ = try await workspace.request(documentID: d.id, feature: .folding)
        expectEvents([(.language, [.requests]), (.language, [.requests, .semantics])])
        try session.setCollapsed(true, foldID: fold.id)
        expectEvents([(.semantics, [.semantics])])
        // The caret stays on a line the collapsed fold does not hide.
        try session.setSelections([Selection(Position(2, 1))])
        expectEvents([(.selection, [.selection])])
        // The first edit makes the result stale and invalidates the ready status.
        try session.type("x")
        expectEvents([(.edit, [.text, .selection, .semantics, .requests])])
        // Neither the unmoved fold nor the already invalidated status changes again.
        try session.type("x")
        expectEvents([(.edit, [.text, .selection])])
        // A new line inside the fold moves its end.
        try d.apply([TextEdit(TextRange(Position(1, 0), Position(1, 0)), "\n")])
        expectEvents([(.edit, [.text, .selection, .semantics])])
        try session.setSelections(session.selections)
        expectEvents([(.selection, [])])
        registration.cancel()
        expectEvents([(.language, [.semantics])])
        try session.beginComposition()
        try session.updateComposition("y")
        try session.commitComposition()
        expectEvents([(.composition, [.composition]), (.composition, [.text, .selection, .composition]), (.composition, [.composition])])
        try session.dispose()
        expectEvents([(.selection, [.selection])])
        // Disposing the document detaches its remaining sessions.
        let remaining = try EditorSession(document: d)
        try d.dispose()
        expectEvents([(.disposed, [.selection])])
        #expect(remaining.isDisposed)
    }
    @Test func workspacePreflightAtomicObservationAndIndependentUndo() throws {
        let engine = EditorWorkspace()
        let a = try engine.createDocument(id:"a",text:"aaa"), b = try engine.createDocument(id:"b",text:"bbb")
        func transaction(_ bVersion:Int) -> WorkspaceEdit {
            WorkspaceEdit([DocumentEdits(documentID:"a",expectedVersion:a.version,edits:[TextEdit(a.snapshot.fullRange,"AAA")]),
                DocumentEdits(documentID:"b",expectedVersion:bVersion,edits:[TextEdit(b.snapshot.fullRange,"BBB")])])
        }
        #expect(throws:EditorError.staleVersion(expected:0,actual:1)) { try engine.apply(transaction(0)) }
        #expect(a.snapshot.text == "aaa" && b.snapshot.text == "bbb")
        let missing = WorkspaceEdit([DocumentEdits(documentID:"a",expectedVersion:1,edits:[TextEdit(a.snapshot.fullRange,"AAA")]),DocumentEdits(documentID:"missing",expectedVersion:1,edits:[])])
        #expect(throws:EditorError.missingDocument("missing")) { try engine.apply(missing) }
        #expect(a.snapshot.text == "aaa")
        var events = 0
        let token = try a.observe { _ in
            events += 1; #expect(a.snapshot.text == "AAA" && b.snapshot.text == "BBB")
            #expect(throws:EditorError.reentrantMutation) { try b.apply([]) }
        }
        try engine.apply(transaction(b.version)); #expect(events == 1); token.cancel()
        try a.undo(); #expect(a.snapshot.text == "aaa" && b.snapshot.text == "BBB")
        try b.undo(); #expect(b.snapshot.text == "bbb")
        try engine.closeDocument(id:"a")
        #expect(throws:EditorError.missingDocument("a")) { try engine.document(id:"a") }
        try engine.dispose()
    }
    @Test func staleChangedAndReorderedRequestsNeverPublish() async throws {
        let engine = EditorWorkspace(), provider = GateProvider()
        let d = try engine.createDocument(id:"stale",text:"abc")
        let token = try engine.register(language:"*",features:[.hover],provider:provider)
        let first = Task { try await engine.request(documentID:d.id,feature:.hover) }
        try await provider.waitFor(1)
        let second = Task { try await engine.request(documentID:d.id,feature:.hover) }
        try await provider.waitFor(2)
        provider.finish(1,.hover(Hover(range:d.snapshot.fullRange,contents:["second"])))
        let newest = try await second.value
        provider.finish(0,.hover(Hover(range:d.snapshot.fullRange,contents:["first"])))
        await #expect(throws:EditorError.staleResult) { try await first.value }
        guard case .ready(let response) = engine.status(documentID:d.id,feature:.hover) else { Issue.record("Missing newest response"); return }
        #expect(response.result == newest.result)
        let third = Task { try await engine.request(documentID:d.id,feature:.hover) }
        try await provider.waitFor(3)
        try d.apply([TextEdit(TextRange(Position(0,0),Position(0,0)),"x")])
        provider.finish(2,.hover(nil))
        await #expect(throws:EditorError.staleResult) { try await third.value }
        guard case .invalidated = engine.status(documentID:d.id,feature:.hover) else { Issue.record("Stale response survived edit"); return }
        token.cancel(); try engine.dispose()
    }
    @Test func requestEndingsDecideOutcomesWhateverTheProviderDoes() async throws {
        for honors in [false, true] {
            let workspace = EditorWorkspace()
            let d = try workspace.createDocument(id:"endings",text:"abc")
            let provider = StallingProvider(honorsCancellation:honors)
            let registration = try workspace.register(language:"*",features:[.hover],provider:provider)
            func start() async -> Task<LanguageResponse, Error> {
                let started = provider.started
                let task = Task { try await workspace.request(documentID:d.id,feature:.hover) }
                while provider.started == started { await Task.yield() }
                return task
            }
            func status() -> String {
                switch workspace.status(documentID:d.id,feature:.hover) {
                case .cancelled: "cancelled"
                case .invalidated: "invalidated"
                case .pending: "pending"
                default: "other"
                }
            }
            var request = await start()
            workspace.cancelRequest(documentID:d.id,feature:.hover)
            await #expect(throws:EditorError.cancelled) { try await request.value }
            #expect(status() == "cancelled")
            request = await start()
            let successor = await start()
            await #expect(throws:EditorError.staleResult) { try await request.value }
            #expect(status() == "pending")
            workspace.cancelRequest(documentID:d.id,feature:.hover)
            await #expect(throws:EditorError.cancelled) { try await successor.value }
            request = await start()
            try d.apply([TextEdit(TextRange(Position(0,0),Position(0,0)),"x")])
            await #expect(throws:EditorError.staleResult) { try await request.value }
            #expect(status() == "invalidated")
            request = await start()
            let replacement = try workspace.register(language:"*",features:[.hover],provider:provider)
            await #expect(throws:EditorError.staleResult) { try await request.value }
            #expect(status() == "invalidated")
            request = await start()
            request.cancel()
            await #expect(throws:CancellationError.self) { try await request.value }
            #expect(status() == "cancelled")
            request = await start()
            try workspace.closeDocument(id:d.id)
            await #expect(throws:EditorError.staleResult) { try await request.value }
            provider.release(); replacement.cancel(); registration.cancel(); try workspace.dispose()
        }
    }
    @Test func providerCancellationErrorsAreFailures() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id:"provider cancellation")
        let registration = try workspace.register(language:"*",features:[.hover],provider:ClosureProvider { _ in throw CancellationError() })
        await #expect(throws:CancellationError.self) { try await workspace.request(documentID:d.id,feature:.hover) }
        guard case .failed(let error) = workspace.status(documentID:d.id,feature:.hover) else { Issue.record("Provider failure was not retained"); return }
        #expect(error is CancellationError)
        registration.cancel(); try workspace.dispose()
    }
    @Test func failureCancellationUnregisterAndDisposal() async throws {
        enum Failure: Error { case provider }
        let engine = EditorWorkspace()
        let d = try engine.createDocument(id:"fail",text:"abc")
        let fail = try engine.register(language:"*",features:[.hover],provider:ClosureProvider { _ in throw Failure.provider })
        await #expect(throws:Failure.provider) { try await engine.request(documentID:d.id,feature:.hover) }
        guard case .failed(let error) = engine.status(documentID:d.id,feature:.hover) else { Issue.record("Failure hidden"); return }
        #expect(error is Failure); fail.cancel()
        let gate = GateProvider()
        let token = try engine.register(language:"*",features:[.hover],provider:gate)
        let cancelled = Task { try await engine.request(documentID:d.id,feature:.hover) }
        try await gate.waitFor(1); cancelled.cancel(); gate.finish(0,.hover(nil))
        await #expect(throws:CancellationError.self) { try await cancelled.value }
        let removed = Task { try await engine.request(documentID:d.id,feature:.hover) }
        try await gate.waitFor(2); token.cancel(); gate.finish(1,.hover(nil))
        await #expect(throws:EditorError.staleResult) { try await removed.value }
        let token2 = try engine.register(language:"*",features:[.hover],provider:gate)
        let closed = Task { try await engine.request(documentID:d.id,feature:.hover) }
        try await gate.waitFor(3); try engine.closeDocument(id:d.id)
        _ = try engine.createDocument(id:d.id,text:"new")
        gate.finish(2,.hover(nil))
        await #expect(throws:EditorError.staleResult) { try await closed.value }
        let disposed = Task { try await engine.request(documentID:d.id,feature:.hover) }
        try await gate.waitFor(4); try engine.dispose(); gate.finish(3,.hover(nil))
        await #expect(throws:EditorError.staleResult) { try await disposed.value }
        token2.cancel()
    }
    @Test func retainedEditingResultsCannotApplyAfterInvalidation() async throws {
        let engine = EditorWorkspace()
        let d = try engine.createDocument(id:"apply",text:"abc")
        let token = try engine.register(language:"*",features:[.completion],provider:ClosureProvider { r in
            .completion([CompletionItem(label:"x",edit:self.edit(r,"x"))])
        })
        let result = try await engine.request(documentID:d.id,feature:.completion)
        try d.apply([TextEdit(TextRange(Position(0,0),Position(0,0)),"z")])
        #expect(throws:EditorError.staleVersion(expected:result.version,actual:d.version)) { try engine.apply(result) }
        let fresh = try await engine.request(documentID:d.id,feature:.completion)
        token.cancel()
        #expect(throws:EditorError.staleResult) { try engine.apply(fresh) }
        #expect(d.snapshot.text == "zabc")
        try engine.dispose()
    }
    @Test func invalidResultsFailAndCoherentSemanticNotification() async throws {
        let engine = EditorWorkspace()
        let d = try engine.createDocument(id:"validation",text:"abc")
        let wrong = try engine.register(language:"*",features:[.hover],provider:ClosureProvider { _ in .completion([]) })
        await #expect(throws:EditorError.invalidProviderResult) { try await engine.request(documentID:d.id,feature:.hover) }; wrong.cancel()
        let token = try engine.register(language:"*",features:[.diagnostics],provider:ClosureProvider { r in .diagnostics([Diagnostic(range:r.snapshot.fullRange,severity:.error,message:"error")]) })
        var sawReady = false
        let observation = try d.observe { _ in
            if case .ready = engine.status(documentID:d.id,feature:.diagnostics) {
                sawReady = true; #expect((try? d.semantics().diagnostics.count) == 1)
            }
        }
        _ = try await engine.request(documentID:d.id,feature:.diagnostics)
        #expect(sawReady)
        observation.cancel(); token.cancel(); try engine.dispose()
    }
    @Test func pendingProviderReplacementRetainsOnlyTheNewResponse() async throws {
        let workspace = EditorWorkspace()
        let document = try workspace.createDocument(id: "provider", text: "a")
        let old = GateProvider(), new = GateProvider()
        let oldRegistration = try workspace.register(language: "*", features: [.hover], provider: old)
        let first = Task { try await workspace.request(documentID: document.id, feature: .hover) }
        try await old.waitFor(1)
        let newRegistration = try workspace.register(language: "*", features: [.hover], provider: new)
        let second = Task { try await workspace.request(documentID: document.id, feature: .hover) }
        try await new.waitFor(1)
        new.finish(0, .hover(Hover(range: document.snapshot.fullRange, contents: ["new"])))
        let response = try await second.value
        old.finish(0, .hover(Hover(range: document.snapshot.fullRange, contents: ["old"])))
        await #expect(throws: EditorError.staleResult) { try await first.value }
        #expect(await old.cancellation(0))
        if case .ready(let retained) = workspace.status(documentID: document.id, feature: .hover) {
            #expect(retained.result == response.result)
        } else { Issue.record("Replacement provider's result was lost") }
        oldRegistration.cancel(); newRegistration.cancel(); try workspace.dispose()
    }
    @Test func cancellationReachesTheProviderTask() async throws {
        for callerCancellation in [false, true] {
            let workspace = EditorWorkspace()
            let document = try workspace.createDocument(id: "cancellation", text: "a")
            let provider = GateProvider()
            let registration = try workspace.register(language: "*", features: [.hover], provider: provider)
            let request = Task { try await workspace.request(documentID: document.id, feature: .hover) }
            try await provider.waitFor(1)
            if callerCancellation { request.cancel() }
            else { workspace.cancelRequest(documentID: document.id, feature: .hover) }
            provider.finish(0, .hover(nil))
            if callerCancellation { await #expect(throws: CancellationError.self) { try await request.value } }
            else { await #expect(throws: EditorError.cancelled) { try await request.value } }
            #expect(await provider.cancellation(0))
            registration.cancel(); try workspace.dispose()
        }
    }
    @Test func emptyDiagnosticsBecomeStaleOnEditUndoAndRedo() async throws {
        for providerOwned in [false, true] {
            let workspace = EditorWorkspace()
            let document = try workspace.createDocument(id: "diagnostics", text: "a")
            #expect(try document.semantics().diagnosticsFreshness == .unavailable)
            var registration: Subscription?
            if providerOwned {
                registration = try workspace.register(language: "*", features: [.diagnostics], provider: ClosureProvider { _ in .diagnostics([]) })
                _ = try await workspace.request(documentID: document.id, feature: .diagnostics)
            } else { try document.setDiagnostics([], version: document.version) }
            #expect(try document.semantics().diagnosticsFreshness == .current)
            try document.apply([TextEdit(document.snapshot.fullRange, "a")])
            #expect(try document.semantics().diagnosticsFreshness == .current)
            let source = document.version
            try document.apply([TextEdit(document.snapshot.fullRange, "b")])
            #expect(try document.semantics().diagnosticsFreshness == .stale(version: source))
            try document.setDiagnostics([], version: document.version)
            let beforeUndo = document.version
            try document.undo()
            #expect(try document.semantics().diagnosticsFreshness == .stale(version: beforeUndo))
            try document.setDiagnostics([], version: document.version)
            let beforeRedo = document.version
            try document.redo()
            #expect(try document.semantics().diagnosticsFreshness == .stale(version: beforeRedo))
            registration?.cancel(); try workspace.dispose()
        }
    }
    @Test func editingResultsRejectReopenedTargetsBeforeChangingAnyDocument() async throws {
        for feature in [LanguageFeature.completion, .codeActions, .rename, .formatting] {
            let workspace = EditorWorkspace()
            let source = try workspace.createDocument(id: "source", text: "aaa")
            let target = try workspace.createDocument(id: "target", text: "bbb")
            let token = try workspace.register(language: "*", features: [feature], provider: ClosureProvider { request in
                let edit = WorkspaceEdit([
                    DocumentEdits(documentID: source.id, expectedVersion: request.snapshot.version, edits: [TextEdit(request.snapshot.fullRange, "AAA")]),
                    DocumentEdits(documentID: target.id, expectedVersion: target.version, edits: [TextEdit(target.snapshot.fullRange, "BBB")])
                ])
                switch request.feature {
                case .completion: return .completion([CompletionItem(label: "replace", edit: edit)])
                case .codeActions: return .codeActions([CodeAction(title: "replace", kind: "quickfix", edit: edit)])
                case .rename: return .rename(edit)
                case .formatting: return .formatting(edit)
                default: throw EditorError.invalidProviderResult
                }
            })
            let response = try await workspace.request(documentID: source.id, feature: feature)
            try workspace.closeDocument(id: target.id)
            let reopened = try workspace.createDocument(id: target.id, text: "NEW")
            #expect(reopened.version == target.version)
            #expect(throws: EditorError.staleResult) { try workspace.apply(response) }
            let extracted: WorkspaceEdit
            switch response.result {
            case .completion(let items): extracted = items[0].edit
            case .codeActions(let actions): extracted = actions[0].edit
            case .rename(let edit), .formatting(let edit): extracted = edit
            default: throw EditorError.invalidProviderResult
            }
            #expect(throws: EditorError.staleResult) { try workspace.apply(extracted) }
            #expect(source.snapshot.text == "aaa" && reopened.snapshot.text == "NEW")
            #expect(source.version == 1 && reopened.version == 1)
            #expect(!source.canUndo && !reopened.canUndo)
            token.cancel(); try workspace.dispose()
        }
    }
    @Test func pendingEditingResultRejectsTargetReopenedDuringRequest() async throws {
        let workspace = EditorWorkspace()
        let source = try workspace.createDocument(id: "source", text: "aaa")
        let target = try workspace.createDocument(id: "target", text: "bbb")
        let gate = GateProvider()
        let registration = try workspace.register(language: "*", features: [.rename], provider: gate)
        let request = Task { try await workspace.request(documentID: source.id, feature: .rename) }
        try await gate.waitFor(1)
        let edit = WorkspaceEdit([
            DocumentEdits(documentID: source.id, expectedVersion: 1, edits: [TextEdit(source.snapshot.fullRange, "AAA")]),
            DocumentEdits(documentID: target.id, expectedVersion: 1, edits: [TextEdit(target.snapshot.fullRange, "BBB")])
        ])
        try workspace.closeDocument(id: target.id)
        let reopened = try workspace.createDocument(id: target.id, text: "NEW")
        gate.finish(0, .rename(edit))
        await #expect(throws: EditorError.staleResult) { try await request.value }
        if case .ready = workspace.status(documentID: source.id, feature: .rename) { Issue.record("Reopened target's result was published") }
        #expect(source.snapshot.text == "aaa" && reopened.snapshot.text == "NEW")
        registration.cancel(); try workspace.dispose()
    }
    @Test func snapshotBoundWorkspaceEditsRejectReopenedTargets() throws {
        let workspace = EditorWorkspace()
        let target = try workspace.createDocument(id: "target", text: "old")
        let snapshot = target.snapshot
        let edit = WorkspaceEdit([DocumentEdits(snapshot: snapshot, edits: [TextEdit(snapshot.fullRange, "updated")])])
        try workspace.closeDocument(id: target.id)
        let reopened = try workspace.createDocument(id: target.id, text: "NEW")
        #expect(throws: EditorError.staleResult) { try workspace.apply(edit) }
        #expect(reopened.snapshot.text == "NEW" && !reopened.canUndo)
        let fresh = reopened.snapshot
        try workspace.apply(WorkspaceEdit([DocumentEdits(snapshot: fresh, edits: [TextEdit(fresh.fullRange, "fresh")])]))
        #expect(reopened.snapshot.text == "fresh")
        try reopened.undo(); #expect(reopened.snapshot.text == "NEW")
        try workspace.dispose()
    }
    @Test func workspaceEditsRejectDuplicateTargets() async throws {
        let workspace = EditorWorkspace()
        let a = try workspace.createDocument(id: "a", text: "abc"), b = try workspace.createDocument(id: "b", text: "xyz")
        let first = DocumentEdits(documentID: "a", expectedVersion: a.version, edits: [TextEdit(TextRange(Position(0, 0), Position(0, 1)), "1")])
        let second = DocumentEdits(documentID: "a", expectedVersion: a.version, edits: [TextEdit(TextRange(Position(0, 2), Position(0, 3)), "2")])
        let other = DocumentEdits(documentID: "b", expectedVersion: b.version, edits: [TextEdit(TextRange(Position(0, 0), Position(0, 0)), "!")])
        #expect(throws: EditorError.overlappingEdits) { try workspace.apply(WorkspaceEdit([other, first, second])) }
        #expect(a.snapshot.text == "abc" && b.snapshot.text == "xyz" && a.version == 1 && b.version == 1 && !a.canUndo && !b.canUndo)
        let token = try workspace.register(language: "*", features: [.rename], provider: ClosureProvider { _ in .rename(WorkspaceEdit([first, second])) })
        await #expect(throws: EditorError.invalidProviderResult) { try await workspace.request(documentID: "a", feature: .rename, newName: "n") }
        guard case .failed(let error) = workspace.status(documentID: "a", feature: .rename) else { Issue.record("Duplicate targets were accepted"); return }
        #expect(error as? EditorError == .invalidProviderResult)
        token.cancel(); try workspace.dispose()
    }
    @Test func providersServeOnlyTheirLanguage() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "md", text: "abc", language: "md")
        let swift = try workspace.register(language: "swift", features: [.diagnostics], provider: ClosureProvider { _ in .diagnostics([]) })
        await #expect(throws: EditorError.noProvider) { try await workspace.request(documentID: d.id, feature: .diagnostics) }
        swift.cancel()
        let diagnostic = Diagnostic(range: TextRange(Position(0, 0), Position(0, 1)), severity: .warning, message: "md")
        let markdown = try workspace.register(language: "md", features: [.diagnostics], provider: ClosureProvider { _ in .diagnostics([diagnostic]) })
        _ = try await workspace.request(documentID: d.id, feature: .diagnostics)
        var events = 0
        let observation = try d.observe { _ in events += 1 }
        // Registering and unregistering another language leaves this document alone.
        let other = try workspace.register(language: "swift", features: [.diagnostics], provider: ClosureProvider { _ in .diagnostics([]) })
        other.cancel()
        #expect(events == 0)
        guard case .ready = workspace.status(documentID: d.id, feature: .diagnostics) else { Issue.record("Unrelated registration invalidated the result"); return }
        #expect(try d.semantics().diagnostics == [diagnostic] && d.semantics().diagnosticsFreshness == .current)
        observation.cancel(); markdown.cancel(); try workspace.dispose()
    }
    @Test func featuresRequestIndependently() async throws {
        let workspace = EditorWorkspace(), provider = GateProvider()
        let d = try workspace.createDocument(id: "features", text: "abc")
        let token = try workspace.register(language: "*", features: [.diagnostics, .tokens], provider: provider)
        let diagnostics = Task { try await workspace.request(documentID: d.id, feature: .diagnostics) }
        try await provider.waitFor(1)
        let tokens = Task { try await workspace.request(documentID: d.id, feature: .tokens) }
        try await provider.waitFor(2)
        provider.finish(1, .tokens([HighlightToken(range: TextRange(Position(0, 0), Position(0, 3)), kind: "word")]))
        _ = try await tokens.value
        provider.finish(0, .diagnostics([]))
        _ = try await diagnostics.value
        for feature in [LanguageFeature.diagnostics, .tokens] {
            guard case .ready = workspace.status(documentID: d.id, feature: feature) else { Issue.record("\(feature) was not ready"); continue }
        }
        #expect(try d.semantics().tokens.count == 1)
        token.cancel(); try workspace.dispose()
    }
    @Test func editingResultsApplyTheChosenItem() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "items", text: "ab")
        func edit(_ text: String) -> WorkspaceEdit {
            WorkspaceEdit([DocumentEdits(documentID: d.id, expectedVersion: d.version, edits: [TextEdit(TextRange(Position(0, 2), Position(0, 2)), text)])])
        }
        let token = try workspace.register(language: "*", features: [.completion, .codeActions], provider: ClosureProvider { request in
            request.feature == .completion
                ? .completion([CompletionItem(label: "first", edit: edit("1")), CompletionItem(label: "second", edit: edit("2"))])
                : .codeActions([CodeAction(title: "first", kind: "fix", edit: edit("3")), CodeAction(title: "second", kind: "fix", edit: edit("4"))])
        })
        for (feature, chosen) in [(LanguageFeature.completion, "ab2"), (.codeActions, "ab4")] {
            try d.apply([TextEdit(d.snapshot.fullRange, "ab")])
            let response = try await workspace.request(documentID: d.id, feature: feature)
            let version = d.version
            #expect(throws: EditorError.invalidRange) { try workspace.apply(response, item: 2) }
            #expect(d.snapshot.text == "ab" && d.version == version)
            try workspace.apply(response, item: 1)
            #expect(d.snapshot.text == chosen)
        }
        token.cancel(); try workspace.dispose()
    }
    @Test func invalidProviderResultsFail() async throws {
        let range = TextRange(Position(0, 0), Position(0, 2)), inner = TextRange(Position(0, 0), Position(0, 1))
        let results: [LanguageResult] = [
            .documentSymbols([DocumentSymbol(name: "s", kind: "k", range: inner, selectionRange: range)]),
            .documentSymbols([DocumentSymbol(name: "s", kind: "k", range: inner, selectionRange: inner,
                                             children: [DocumentSymbol(name: "c", kind: "k", range: range, selectionRange: inner)])]),
            .hover(Hover(range: TextRange(Position(0, 0), Position(3, 0)), contents: ["x"])),
            .definition([DocumentLocation(documentID: "invalid", range: TextRange(Position(9, 0), Position(9, 0)))]),
        ]
        for result in results {
            let workspace = EditorWorkspace()
            let d = try workspace.createDocument(id: "invalid", text: "abc")
            let token = try workspace.register(language: "*", features: [result.feature], provider: ClosureProvider { _ in result })
            await #expect(throws: EditorError.invalidProviderResult) { try await workspace.request(documentID: d.id, feature: result.feature) }
            guard case .failed = workspace.status(documentID: d.id, feature: result.feature) else { Issue.record("\(result) was not failed"); continue }
            token.cancel(); try workspace.dispose()
        }
    }
    @Test func navigationMayNameUnopenedDocuments() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "open", text: "abc")
        let location = DocumentLocation(documentID: "unopened.swift", range: TextRange(Position(40, 2), Position(40, 5)))
        let token = try workspace.register(language: "*", features: [.definition], provider: ClosureProvider { _ in .definition([location]) })
        let response = try await workspace.request(documentID: d.id, feature: .definition)
        #expect(response.result == .definition([location]))
        token.cancel(); try workspace.dispose()
    }
    @Test func editingResultsRejectTargetsOpenedDuringTheRequest() async throws {
        let workspace = EditorWorkspace(), provider = GateProvider()
        let d = try workspace.createDocument(id: "source", text: "abc")
        let token = try workspace.register(language: "*", features: [.rename], provider: provider)
        let request = Task { try await workspace.request(documentID: d.id, feature: .rename, newName: "n") }
        try await provider.waitFor(1)
        let opened = try workspace.createDocument(id: "opened", text: "xyz")
        provider.finish(0, .rename(WorkspaceEdit([DocumentEdits(documentID: opened.id, expectedVersion: opened.version,
            edits: [TextEdit(TextRange(Position(0, 0), Position(0, 1)), "n")])])))
        await #expect(throws: EditorError.staleResult) { try await request.value }
        if case .ready = workspace.status(documentID: d.id, feature: .rename) { Issue.record("A result for a newly opened target became ready") }
        #expect(opened.snapshot.text == "xyz")
        token.cancel(); try workspace.dispose()
    }
    @Test func closingADocumentForgetsItsStatuses() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "closed", text: "abc")
        let token = try workspace.register(language: "*", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
        _ = try await workspace.request(documentID: d.id, feature: .hover)
        try workspace.closeDocument(id: d.id)
        guard case .idle = workspace.status(documentID: d.id, feature: .hover) else { Issue.record("Status survived close"); return }
        _ = try workspace.createDocument(id: d.id, text: "new")
        guard case .idle = workspace.status(documentID: d.id, feature: .hover) else { Issue.record("Reopened document saw an old status"); return }
        token.cancel(); try workspace.dispose()
    }
    @Test func invalidAndStaleEditingResultsAreClassified() async throws {
        let workspace = EditorWorkspace(), provider = GateProvider()
        let d = try workspace.createDocument(id: "source", text: "abc"), other = try workspace.createDocument(id: "other", text: "xyz")
        let token = try workspace.register(language: "*", features: [.rename], provider: provider)
        func outcome(_ result: (Int) -> LanguageResult, editing: Bool = false) async throws -> EditorError? {
            let started = provider.pending.count
            let request = Task { try await workspace.request(documentID: d.id, feature: .rename, newName: "n") }
            try await provider.waitFor(started + 1)
            let version = other.version
            if editing { try other.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "!")]) }
            provider.finish(started, result(version))
            do { _ = try await request.value; return nil } catch { return error as? EditorError }
        }
        func rename(_ id: String, version: Int, end: Int = 1) -> LanguageResult {
            .rename(WorkspaceEdit([DocumentEdits(documentID: id, expectedVersion: version, edits: [TextEdit(TextRange(Position(0, 0), Position(0, end)), "n")])]))
        }
        // Results that could never apply are the provider's error.
        #expect(try await outcome { _ in rename("unopened", version: 1) } == .invalidProviderResult)
        #expect(try await outcome { rename("other", version: $0, end: 9) } == .invalidProviderResult)
        #expect(try await outcome { rename("other", version: $0 + 5) } == .invalidProviderResult)
        // A target edited during the request makes the result stale instead.
        #expect(try await outcome({ rename("other", version: $0) }, editing: true) == .staleResult)
        // Even when the provider names the version the target has now.
        #expect(try await outcome({ rename("other", version: $0 + 1) }, editing: true) == .staleResult)
        #expect(try await outcome { rename("other", version: $0) } == nil)
        token.cancel(); try workspace.dispose()
    }
    @Test func invalidSemanticResultsFailAsProviderErrors() async throws {
        let fold = { (a: Int, b: Int, c: Int, e: Int) in FoldingRange(range: TextRange(Position(a, b), Position(c, e))) }
        let shared = fold(0, 0, 2, 1)
        let results: [LanguageResult] = [
            .folding([fold(0, 0, 2, 1), fold(1, 0, 3, 1)]),
            .folding([fold(0, 0, 1, 0)]),
            .folding([shared, FoldingRange(id: shared.id, range: TextRange(Position(1, 0), Position(2, 1)))]),
            .inlayHints([InlayHint(position: Position(0, 0), label: "x", edits: [TextEdit(TextRange(Position(0, 0), Position(9, 0)), "x")])]),
            .completion([CompletionItem(label: "x", edit: WorkspaceEdit([DocumentEdits(documentID: "invalid", expectedVersion: 1,
                edits: [TextEdit(TextRange(Position(0, 0), Position(9, 0)), "x")])]))]),
        ]
        for result in results {
            let workspace = EditorWorkspace()
            let d = try workspace.createDocument(id: "invalid", text: "a\nb\nc\nd")
            let token = try workspace.register(language: "*", features: [result.feature], provider: ClosureProvider { _ in result })
            await #expect(throws: EditorError.invalidProviderResult) { try await workspace.request(documentID: d.id, feature: result.feature) }
            #expect(try d.semantics().foldingRanges.isEmpty && d.semantics().inlayHints.isEmpty)
            token.cancel(); try workspace.dispose()
        }
    }
    @Test func unchangedStatusesReportNoRequestChange() async throws {
        let workspace = EditorWorkspace(), provider = GateProvider()
        let d = try workspace.createDocument(id: "statuses", text: "abc")
        var changes: [DocumentChanges] = []
        let observation = try d.observe { changes.append($0.changes) }
        await #expect(throws: EditorError.noProvider) { try await workspace.request(documentID: d.id, feature: .hover) }
        await #expect(throws: EditorError.noProvider) { try await workspace.request(documentID: d.id, feature: .hover) }
        let token = try workspace.register(language: "*", features: [.hover], provider: provider)
        let first = Task { try await workspace.request(documentID: d.id, feature: .hover) }
        try await provider.waitFor(1)
        let second = Task { try await workspace.request(documentID: d.id, feature: .hover) }
        try await provider.waitFor(2)
        provider.finish(1, .hover(nil))
        _ = try await second.value
        provider.finish(0, .hover(nil))
        await #expect(throws: EditorError.staleResult) { try await first.value }
        // noProvider, the same failure again, then registration, pending, pending again and ready.
        #expect(changes == [[.requests], [], [.requests], [.requests], [], [.requests]])
        observation.cancel(); token.cancel(); try workspace.dispose()
    }
    @Test func cancelledCallersReceiveCancellationWhateverEndedTheRequest() async throws {
        let workspace = EditorWorkspace(), provider = StallingProvider(honorsCancellation: false)
        let d = try workspace.createDocument(id: "cancelled", text: "abc")
        let token = try workspace.register(language: "*", features: [.hover], provider: provider)
        for ending in ["edit", "cancelRequest"] {
            let started = provider.started
            let request = Task { try await workspace.request(documentID: d.id, feature: .hover) }
            while provider.started == started { await Task.yield() }
            // The caller is cancelled before it resumes from the engine's own ending.
            switch ending {
            case "edit": try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "x")])
            default: workspace.cancelRequest(documentID: d.id, feature: .hover)
            }
            request.cancel()
            await #expect(throws: CancellationError.self) { try await request.value }
        }
        provider.release(); token.cancel(); try workspace.dispose()
    }
    @Test func registeringFromANotificationIsRejected() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "register", text: "abc", language: "md")
        try d.setDiagnostics([Diagnostic(range: TextRange(Position(0, 0), Position(0, 1)), severity: .hint, message: "kept")], version: d.version)
        var attempts = 0
        let observation = try d.observe { _ in
            attempts += 1
            #expect(throws: EditorError.reentrantMutation) {
                try workspace.register(language: "md", features: [.diagnostics], provider: ClosureProvider { _ in .diagnostics([]) })
            }
        }
        try d.apply([TextEdit(TextRange(Position(0, 3), Position(0, 3)), "!")])
        observation.cancel()
        #expect(try attempts == 1 && d.semantics().diagnostics.count == 1)
        await #expect(throws: EditorError.noProvider) { try await workspace.request(documentID: d.id, feature: .diagnostics) }
        try workspace.dispose()
    }
    @Test func signatureHelpClearsOutOfRangeIndices() async throws {
        let cases: [(SignatureHelp, SignatureHelp)] = [
            (SignatureHelp(signatures: []), SignatureHelp(signatures: [])),
            (SignatureHelp(signatures: [], activeSignature: 3, activeParameter: 1), SignatureHelp(signatures: [])),
            (SignatureHelp(signatures: [Signature(label: "f")], activeSignature: 1, activeParameter: 0), SignatureHelp(signatures: [Signature(label: "f")])),
            (SignatureHelp(signatures: [Signature(label: "f", parameters: ["a"])], activeParameter: 1), SignatureHelp(signatures: [Signature(label: "f", parameters: ["a"])])),
            (SignatureHelp(signatures: [Signature(label: "f", parameters: ["a"])], activeParameter: 0),
             SignatureHelp(signatures: [Signature(label: "f", parameters: ["a"])], activeParameter: 0)),
        ]
        for (sent, received) in cases {
            let workspace = EditorWorkspace()
            let d = try workspace.createDocument(id: "signature", text: "f()")
            let token = try workspace.register(language: "*", features: [.signatureHelp], provider: ClosureProvider { _ in .signatureHelp(sent) })
            #expect(try await workspace.request(documentID: d.id, feature: .signatureHelp).result == .signatureHelp(received))
            token.cancel(); try workspace.dispose()
        }
    }
    @Test func locationsInDocumentsChangedDuringTheRequestAreStale() async throws {
        let workspace = EditorWorkspace(), provider = GateProvider()
        let d = try workspace.createDocument(id: "source", text: "abc"), other = try workspace.createDocument(id: "other", text: "a\nb\nc")
        let token = try workspace.register(language: "*", features: [.definition], provider: provider)
        let location = { (id: String) in LanguageResult.definition([DocumentLocation(documentID: id, range: TextRange(Position(2, 0), Position(2, 1)))]) }
        for change in ["edit", "open", "none"] {
            let started = provider.pending.count
            let request = Task { try await workspace.request(documentID: d.id, feature: .definition) }
            try await provider.waitFor(started + 1)
            var target = other.id
            switch change {
            case "edit": try other.apply([TextEdit(TextRange(Position(0, 0), Position(2, 0)), "")])
            case "open": target = "opened\(started)"; _ = try workspace.createDocument(id: target, text: "x\ny\nz")
            default: break
            }
            provider.finish(started, location(target))
            if change == "none" { _ = try await request.value } else { await #expect(throws: EditorError.staleResult) { try await request.value } }
            if change == "edit" { try other.undo() }
        }
        token.cancel(); try workspace.dispose()
    }
    @Test func requestsPassTheirArgumentsAfterCheckingThem() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "arguments", text: "a😀b")
        var received: [LanguageRequest] = []
        let token = try workspace.register(language: "*", features: [.rename, .formatting], provider: ClosureProvider { request in
            received.append(request)
            return request.feature == .rename ? .rename(WorkspaceEdit([])) : .formatting(WorkspaceEdit([]))
        })
        _ = try await workspace.request(documentID: d.id, feature: .rename, position: Position(0, 1), newName: "n")
        _ = try await workspace.request(documentID: d.id, feature: .formatting, range: TextRange(Position(0, 0), Position(0, 3)))
        #expect(received.map(\.position) == [Position(0, 1), nil] && received.map(\.range) == [nil, TextRange(Position(0, 0), Position(0, 3))])
        #expect(received.map(\.newName) == ["n", nil] && received.allSatisfy { $0.snapshot.version == d.version })
        await #expect(throws: EditorError.invalidBoundary) { try await workspace.request(documentID: d.id, feature: .rename, position: Position(0, 2)) }
        await #expect(throws: EditorError.invalidPosition) {
            try await workspace.request(documentID: d.id, feature: .formatting, range: TextRange(Position(0, 0), Position(1, 0)))
        }
        #expect(received.count == 2)
        token.cancel(); try workspace.dispose()
    }
    @Test func supersededResponsesCannotApply() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "superseded", text: "ab")
        var count = 0
        let token = try workspace.register(language: "*", features: [.completion], provider: ClosureProvider { _ in
            count += 1
            return .completion([CompletionItem(label: "\(count)", edit: WorkspaceEdit([DocumentEdits(documentID: "superseded", expectedVersion: 1,
                edits: [TextEdit(TextRange(Position(0, 2), Position(0, 2)), "\(count)")])]))])
        })
        let first = try await workspace.request(documentID: d.id, feature: .completion)
        let second = try await workspace.request(documentID: d.id, feature: .completion)
        #expect(throws: EditorError.staleResult) { try workspace.apply(first) }
        #expect(d.snapshot.text == "ab")
        try workspace.apply(second)
        #expect(d.snapshot.text == "ab2")
        token.cancel(); try workspace.dispose()
    }
    @Test func workspaceMisuseHasItsOwnErrors() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "misuse", text: "abc")
        #expect(throws: EditorError.duplicateDocument) { try workspace.createDocument(id: d.id, text: "other") }
        #expect(try workspace.document(id: d.id) === d && d.snapshot.text == "abc")
        let token = try workspace.register(language: "*", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
        let hover = try await workspace.request(documentID: d.id, feature: .hover)
        #expect(throws: EditorError.notApplicable) { try workspace.apply(hover) }
        // Registering for any language waits until no notification is running.
        let other = try workspace.createDocument(id: "other", text: "", language: "swift")
        var attempts = 0
        let observation = try d.observe { _ in
            attempts += 1
            #expect(throws: EditorError.reentrantMutation) {
                try workspace.register(language: "swift", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
            }
        }
        try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "x")])
        #expect(attempts == 1)
        await #expect(throws: EditorError.noProvider) { try await workspace.request(documentID: other.id, feature: .definition) }
        observation.cancel(); token.cancel(); try workspace.dispose()
    }
    @Test func closingSeesNoStatusDuringItsNotification() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "closing", text: "abc")
        let token = try workspace.register(language: "*", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
        _ = try await workspace.request(documentID: d.id, feature: .hover)
        var observed = false
        let observation = try d.observe { event in
            guard event.kind == .disposed else { return }
            if case .idle = workspace.status(documentID: d.id, feature: .hover) { observed = true }
        }
        try workspace.closeDocument(id: d.id)
        #expect(observed)
        observation.cancel(); token.cancel(); try workspace.dispose()
    }
    @Test func unregisteringFromAStandaloneNotificationWaitsForIt() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "owned", text: "abc")
        let token = try workspace.register(language: "*", features: [.diagnostics], provider: ClosureProvider { request in
            .diagnostics([Diagnostic(range: request.snapshot.fullRange, severity: .hint, message: "provided")])
        })
        _ = try await workspace.request(documentID: d.id, feature: .diagnostics)
        let standalone = Document(id: "standalone", text: "x")
        var seen: [SemanticFreshness] = []
        let first = try standalone.observe { _ in token.cancel() }
        let second = try standalone.observe { _ in seen.append((try? d.semantics().diagnosticsFreshness) ?? .unavailable) }
        try standalone.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "y")])
        // The second listener still sees the provider's data; it goes once the notification ends.
        #expect(try seen == [.current] && d.semantics().diagnosticsFreshness == .unavailable)
        first.cancel(); second.cancel(); try workspace.dispose()
    }
    @Test func registryAndDisposalWaitForEveryNotification() async throws {
        let workspace = EditorWorkspace()
        let a = try workspace.createDocument(id: "a", text: "a"), b = try workspace.createDocument(id: "b", text: "b")
        let standalone = Document(id: "standalone", text: "s")
        var attempts = 0
        let observation = try standalone.observe { _ in
            attempts += 1
            #expect(throws: EditorError.reentrantMutation) {
                try workspace.register(language: "*", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
            }
            #expect(throws: EditorError.reentrantMutation) { try workspace.dispose() }
        }
        try standalone.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "x")])
        observation.cancel()
        // While one document's disposal notification runs, the others reject writes.
        var blocked = 0
        let observations = try [a, b].map { doc in
            try doc.observe { event in
                guard event.kind == .disposed else { return }
                let other = doc === a ? b : a
                if other.isDisposed { return }
                #expect(throws: EditorError.reentrantMutation) { try other.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "!")]) }
                #expect(throws: EditorError.reentrantMutation) { try EditorSession(document: other) }
                blocked += 1
            }
        }
        try workspace.dispose()
        #expect(attempts == 1 && blocked == 1 && a.snapshot.text == "a" && b.snapshot.text == "b")
        observations.forEach { $0.cancel() }
    }
    @Test func nonEditingResponsesAreNotApplicableBeforeTheyAreStale() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "hover", text: "abc")
        let token = try workspace.register(language: "*", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
        let hover = try await workspace.request(documentID: d.id, feature: .hover)
        try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "x")])
        #expect(throws: EditorError.notApplicable) { try workspace.apply(hover) }
        token.cancel(); try workspace.dispose()
    }
    @Test func unregisteringRemovesEveryKindOfProviderData() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "kinds", text: "a\nb\nc")
        let session = try EditorSession(document: d)
        let fold = FoldingRange(range: TextRange(Position(0, 0), Position(2, 1)))
        let token = try workspace.register(language: "*", features: [.semanticTokens, .inlayHints, .folding], provider: ClosureProvider { request in
            switch request.feature {
            case .semanticTokens: .semanticTokens([HighlightToken(range: TextRange(Position(0, 0), Position(0, 1)), kind: "k")])
            case .inlayHints: .inlayHints([InlayHint(position: Position(0, 1), label: "h")])
            default: .folding([fold])
            }
        })
        for feature in [LanguageFeature.semanticTokens, .inlayHints, .folding] { _ = try await workspace.request(documentID: d.id, feature: feature) }
        try session.setCollapsed(true, foldID: fold.id)
        token.cancel()
        let view = try d.semantics()
        #expect(view.semanticTokens.isEmpty && view.semanticTokensFreshness == .unavailable)
        #expect(view.inlayHints.isEmpty && view.inlayHintsFreshness == .unavailable)
        #expect(view.foldingRanges.isEmpty && view.foldingRangesFreshness == .unavailable)
        #expect(try session.collapsedFolds.isEmpty && session.hiddenLineRanges().isEmpty)
        try workspace.dispose()
    }
    @Test func cancellingASubscriptionTwiceDoesNothingMore() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "twice", text: "abc")
        let first = try workspace.register(language: "*", features: [.diagnostics], provider: ClosureProvider { _ in .diagnostics([]) })
        first.cancel()
        let second = try workspace.register(language: "*", features: [.diagnostics], provider: ClosureProvider { _ in .diagnostics([]) })
        _ = try await workspace.request(documentID: d.id, feature: .diagnostics)
        first.cancel()
        guard case .ready = workspace.status(documentID: d.id, feature: .diagnostics) else { Issue.record("A repeated cancel invalidated the result"); return }
        #expect(try d.semantics().diagnosticsFreshness == .current)
        second.cancel(); try workspace.dispose()
    }
    @Test func targetsClosedDuringTheRequestMakeResultsStale() async throws {
        let workspace = EditorWorkspace(), provider = GateProvider()
        let d = try workspace.createDocument(id: "source", text: "abc")
        let token = try workspace.register(language: "*", features: [.rename, .definition], provider: provider)
        for feature in [LanguageFeature.rename, .definition] {
            let target = try workspace.createDocument(id: "target-\(feature)", text: "xyz")
            let started = provider.pending.count
            let request = Task { try await workspace.request(documentID: d.id, feature: feature, newName: "n") }
            try await provider.waitFor(started + 1)
            try workspace.closeDocument(id: target.id)
            let range = TextRange(Position(0, 0), Position(0, 1))
            provider.finish(started, feature == .rename
                ? .rename(WorkspaceEdit([DocumentEdits(documentID: target.id, expectedVersion: 1, edits: [TextEdit(range, "n")])]))
                : .definition([DocumentLocation(documentID: target.id, range: range)]))
            await #expect(throws: EditorError.staleResult) { try await request.value }
            if case .ready = workspace.status(documentID: d.id, feature: feature) { Issue.record("\(feature) became ready") }
        }
        token.cancel(); try workspace.dispose()
    }
    @Test func documentsAreNotifiedInIDOrder() throws {
        let workspace = EditorWorkspace()
        var order: [String] = []
        let documents = try ["c", "a", "b"].map { try workspace.createDocument(id: $0) }
        let observations = try documents.map { doc in try doc.observe { event in order.append("\(doc.id)\(event.kind == .disposed ? "-" : "+")") } }
        let token = try workspace.register(language: "*", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
        try workspace.dispose()
        #expect(order == ["a+", "b+", "c+", "a-", "b-", "c-"])
        observations.forEach { $0.cancel() }; token.cancel()
    }
    @Test func groupedWorkspaceEditsUndoTogether() throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "grouped", text: "")
        for text in ["a", "b"] {
            try workspace.apply(WorkspaceEdit([DocumentEdits(documentID: d.id, expectedVersion: d.version,
                edits: [TextEdit(TextRange(d.snapshot.fullRange.end, d.snapshot.fullRange.end), text)])]), historyGroup: "paste")
        }
        try d.undo()
        #expect(d.snapshot.text == "" && !d.canUndo)
        try workspace.dispose()
    }
    @Test func closingReportsTheRequestStatusesItRemoves() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "closing flags", text: "abc")
        let token = try workspace.register(language: "*", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
        _ = try await workspace.request(documentID: d.id, feature: .hover)
        var changes: DocumentChanges = []
        let observation = try d.observe { event in if event.kind == .disposed { changes = event.changes } }
        try workspace.closeDocument(id: d.id)
        #expect(changes.contains(.requests))
        observation.cancel(); token.cancel(); try workspace.dispose()
    }
    @Test func writesFromNotificationsAreReentrantEvenDuringComposition() throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "composing writes", text: "ab")
        let session = try EditorSession(document: d)
        var checked = 0
        let observation = try d.observe { event in
            guard event.kind == .composition else { return }
            checked += 1
            #expect(throws: EditorError.reentrantMutation) { try d.apply([TextEdit(TextRange(Position(0, 0), Position(0, 0)), "x")]) }
            #expect(throws: EditorError.reentrantMutation) {
                try workspace.apply(WorkspaceEdit([DocumentEdits(documentID: d.id, expectedVersion: d.version, edits: [])]))
            }
        }
        try session.beginComposition()
        observation.cancel()
        #expect(checked == 1)
        try session.cancelComposition(); try workspace.dispose()
    }
    @Test func deferredWorkWaitsForCompoundOperationsToFinish() throws {
        // A reference, because main-actor observers read it after it changes.
        final class Flag { var on = false }
        // Committing with text notifies an update first; work it defers runs after the commit.
        do {
            let workspace = EditorWorkspace()
            let a = try workspace.createDocument(id: "a", text: "x", language: "md"), b = try workspace.createDocument(id: "b", language: "swift")
            let session = try EditorSession(document: a)
            let token = try workspace.register(language: "swift", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
            var order: [String] = []
            let armed = Flag()
            let onA = try a.observe { event in if armed.on, event.kind == .composition { order.append("a"); token.cancel() } }
            let onB = try b.observe { event in
                guard event.kind == .language else { return }
                order.append("b")
                #expect(throws: EditorError.noComposition) { try a.cancelActiveComposition() }
            }
            try session.beginComposition()
            armed.on = true
            try session.commitComposition("y")
            #expect(a.snapshot.text == "yx" && order.last == "b" && order.filter { $0 == "b" }.count == 1)
            onA.cancel(); onB.cancel(); try workspace.dispose()
        }
        // Closing a composing document notifies a cancellation first; deferred work runs after the close.
        do {
            let workspace = EditorWorkspace()
            let a = try workspace.createDocument(id: "a", text: "x", language: "md"), b = try workspace.createDocument(id: "b", language: "swift")
            let session = try EditorSession(document: a)
            let token = try workspace.register(language: "swift", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
            var reopened: Document?
            let armed = Flag()
            let onA = try a.observe { event in if armed.on, event.kind == .composition { token.cancel() } }
            let onB = try b.observe { event in
                guard event.kind == .language else { return }
                #expect(throws: EditorError.missingDocument("a")) { try workspace.closeDocument(id: "a") }
                reopened = try? workspace.createDocument(id: "a", text: "new")
            }
            try session.beginComposition(); try session.updateComposition("k")
            armed.on = true
            try workspace.closeDocument(id: "a")
            let current = try #require(reopened)
            #expect(workspace.documents["a"] === current && !current.isDisposed && a.isDisposed)
            onA.cancel(); onB.cancel(); try workspace.dispose()
        }
    }
    @Test func undoingWorkspaceEditsRestoresSelections() throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "workspace undo", text: "ab")
        let session = try EditorSession(document: d)
        try session.setSelections([Selection(Position(0, 2))])
        for _ in 0..<2 {
            let end = d.snapshot.fullRange.end
            try workspace.apply(WorkspaceEdit([DocumentEdits(documentID: d.id, expectedVersion: d.version, edits: [TextEdit(TextRange(end, end), "cdef")])]))
        }
        #expect(session.selections == [Selection(Position(0, 10))])
        try d.undo()
        #expect(d.snapshot.text == "abcdef" && session.selections == [Selection(Position(0, 6))])
        try d.undo(); try d.redo()
        #expect(session.selections == [Selection(Position(0, 6))])
        try session.type("!")
        #expect(d.snapshot.text == "abcdef!")
        try workspace.dispose()
    }
    @Test func applicationDataOutlivesProviderRegistrations() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id: "owned", text: "a\nb\nc")
        let range = TextRange(Position(0, 0), Position(0, 1))
        let token = try workspace.register(language: "*", features: [.tokens, .semanticTokens, .folding, .inlayHints], provider: ClosureProvider { request in
            switch request.feature {
            case .tokens: .tokens([HighlightToken(range: range, kind: "provider")])
            case .semanticTokens: .semanticTokens([HighlightToken(range: range, kind: "provider")])
            case .inlayHints: .inlayHints([InlayHint(position: Position(0, 1), label: "provider")])
            default: .folding([FoldingRange(range: TextRange(Position(0, 0), Position(2, 1)))])
            }
        })
        for feature in [LanguageFeature.tokens, .semanticTokens, .folding, .inlayHints] { _ = try await workspace.request(documentID: d.id, feature: feature) }
        // The application replaces every kind; that data is its own.
        try d.setTokens([HighlightToken(range: range, kind: "app")], version: d.version)
        try d.setTokens([HighlightToken(range: range, kind: "app")], semantic: true, version: d.version)
        try d.setFoldingRanges([FoldingRange(range: TextRange(Position(1, 0), Position(2, 1)))], version: d.version)
        try d.setInlayHints([InlayHint(position: Position(0, 1), label: "app")], version: d.version)
        token.cancel()
        let view = try d.semantics()
        #expect(view.tokens.map(\.kind) == ["app"] && view.semanticTokens.map(\.kind) == ["app"])
        #expect(view.foldingRanges.count == 1 && view.inlayHints.map(\.label) == ["app"])
        #expect(view.tokensFreshness == .current && view.semanticTokensFreshness == .current)
        #expect(view.foldingRangesFreshness == .current && view.inlayHintsFreshness == .current)
        try workspace.dispose()
    }
}
