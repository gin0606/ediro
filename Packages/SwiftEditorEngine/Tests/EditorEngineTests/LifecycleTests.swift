import Testing
import EditorEngine

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct LifecycleTests {
    @Test func providerSemanticOwnershipAndShutdownReentrancy() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id:"ownership",text:"abc")
        let provider = try workspace.register(language:"*",features:[.diagnostics,.tokens],provider:ClosureProvider { r in
            if r.feature == .tokens { return .tokens([HighlightToken(range:r.snapshot.fullRange,kind:"word")]) }
            return .diagnostics([Diagnostic(range:r.snapshot.fullRange,severity:.error,message:"provider")])
        })
        _ = try await workspace.request(documentID:d.id,feature:.diagnostics)
        _ = try await workspace.request(documentID:d.id,feature:.tokens)
        try d.setDiagnostics([Diagnostic(range:d.snapshot.fullRange,severity:.hint,message:"application")],version:d.version)
        #expect(try d.semantics().tokensFreshness == .current)
        provider.cancel()
        #expect(try d.semantics().tokens.isEmpty)
        #expect(try d.semantics().tokensFreshness == .unavailable)
        #expect(try d.semantics().diagnostics[0].message == "application")
        #expect(try d.semantics().diagnosticsFreshness == .current)
        let observer = try d.observe { event in
            if event.kind == .disposed {
                // Writes from the disposal notification are reentrant.
                #expect(throws:EditorError.reentrantMutation) { try workspace.createDocument(id:"escaped shutdown") }
                #expect(throws:EditorError.reentrantMutation) { try workspace.closeDocument(id:d.id) }
                #expect(throws:EditorError.reentrantMutation) { try workspace.dispose() }
                #expect(throws:EditorError.reentrantMutation) {
                    try workspace.register(language:"*",features:[.hover],provider:ClosureProvider { _ in .hover(nil) })
                }
            }
        }
        try workspace.dispose(); observer.cancel()
        #expect(workspace.documents.isEmpty)
    }
    @Test func interiorGraphemeDeletionAndEditorRelease() throws {
        for forward in [false,true] {
            let d = Document(id:"interior",text:"e\u{301}x")
            let session = try EditorSession(document:d)
            try session.setSelections([Selection(Position(0,1))])
            if forward { try session.deleteForward() } else { try session.deleteBackward() }
            #expect(d.snapshot.text == "x")
            try d.undo(); #expect(d.snapshot.utf16Count == 3)
            try session.dispose()
            #expect(throws:EditorError.disposed) { try session.setLayout(nil) }
        }
        let d = Document(id:"weak session",text:"a")
        weak var released: EditorSession?
        do { let session = try EditorSession(document:d); released = session }
        #expect(released == nil)
        try d.apply([TextEdit(TextRange(Position(0,0),Position(0,0)),"x")])
        #expect(d.snapshot.text == "xa")
    }
    @Test func multipleTargetsInvalidEditsLeaveEveryTargetUntouched() throws {
        let workspace = EditorWorkspace()
        let a = try workspace.createDocument(id:"a",text:"abc"), b = try workspace.createDocument(id:"b",text:"xyz")
        let bad = WorkspaceEdit([DocumentEdits(documentID:"a",expectedVersion:1,edits:[TextEdit(a.snapshot.fullRange,"ok")]),
            DocumentEdits(documentID:"b",expectedVersion:1,edits:[TextEdit(TextRange(Position(0,0),Position(0,9)),"bad")])])
        #expect(throws:EditorError.invalidPosition) { try workspace.apply(bad) }
        #expect(a.snapshot.text == "abc" && b.snapshot.text == "xyz" && a.version == 1 && b.version == 1)
        let session = try EditorSession(document:b); try session.beginComposition()
        let composing = WorkspaceEdit([DocumentEdits(documentID:"a",expectedVersion:1,edits:[TextEdit(a.snapshot.fullRange,"ok")]),DocumentEdits(documentID:"b",expectedVersion:1,edits:[])])
        #expect(throws:EditorError.compositionActive) { try workspace.apply(composing) }
        #expect(a.snapshot.text == "abc")
        try session.cancelComposition(); try workspace.dispose()
    }
    @Test func navigationAndMultiDocumentRenameThroughProviders() async throws {
        let workspace = EditorWorkspace()
        let a = try workspace.createDocument(id:"source",text:"alpha"), b = try workspace.createDocument(id:"target",text:"beta")
        let token = try workspace.register(language:"*",features:[.definition,.references,.rename],provider:ClosureProvider { request in
            let location = DocumentLocation(documentID:b.id,range:TextRange(Position(0,1),Position(0,3)))
            if request.feature == .definition { return .definition([location]) }
            if request.feature == .references { return .references([location]) }
            return .rename(WorkspaceEdit([
                DocumentEdits(documentID:a.id,expectedVersion:request.snapshot.version,edits:[TextEdit(request.snapshot.fullRange,"renamed A")]),
                DocumentEdits(documentID:b.id,expectedVersion:b.version,edits:[TextEdit(b.snapshot.fullRange,"renamed B")])]))
        })
        for feature in [LanguageFeature.definition,.references] {
            let response = try await workspace.request(documentID:a.id,feature:feature,position:Position(0,1))
            let locations: [DocumentLocation]
            switch response.result {
            case .definition(let values), .references(let values): locations = values
            default: Issue.record("Wrong navigation result"); continue
            }
            let target = try workspace.document(id:locations[0].documentID)
            let session = try EditorSession(document:target)
            try session.setSelections([Selection(locations[0].range.start)])
            #expect(session.document === b && session.selections[0].head == Position(0,1))
            try session.dispose()
        }
        let obsolete = try await workspace.request(documentID:a.id,feature:.rename,newName:"renamed")
        try b.apply([TextEdit(b.snapshot.fullRange,"external")])
        #expect(throws:EditorError.staleVersion(expected:1,actual:2)) { try workspace.apply(obsolete) }
        #expect(a.snapshot.text == "alpha" && b.snapshot.text == "external")
        let fresh = try await workspace.request(documentID:a.id,feature:.rename,newName:"renamed")
        try workspace.apply(fresh)
        #expect(a.snapshot.text == "renamed A" && b.snapshot.text == "renamed B")
        try a.undo(); try b.undo()
        #expect(a.snapshot.text == "alpha" && b.snapshot.text == "external")
        token.cancel(); try workspace.dispose()
    }
    @Test func searchCombiningWordsAndInvalidExternalLocation() async throws {
        let d = Document(id:"words",text:"e\u{301} e")
        let matches = try d.snapshot.search("e",options:.init(wholeWord:true))
        #expect(matches.count == 1 && matches[0].range.start == Position(0,3))
        let workspace = EditorWorkspace()
        _ = try workspace.createDocument(id:"source",text:"abc")
        let token = try workspace.register(language:"*",features:[.definition],provider:ClosureProvider { _ in
            .definition([DocumentLocation(documentID:"unopened",range:TextRange(Position(1,-1),Position(2,0)))])
        })
        await #expect(throws:EditorError.invalidProviderResult) { try await workspace.request(documentID:"source",feature:.definition) }
        token.cancel(); try workspace.dispose()
    }

    @Test func abandonedCompositionCanBeRestoredAndDisposed() throws {
        for dispose in [false,true] {
            let d = Document(id:"abandoned input",text:"original")
            var began = false
            let observer = try d.observe { event in
                if event.kind == .composition { began = true }
            }
            weak var released: EditorSession?
            do {
                let session = try EditorSession(document:d); released = session
                try session.beginComposition(); #expect(began)
                try session.updateComposition("provisional")
            }
            #expect(released == nil)
            #expect(d.snapshot.text == "provisionaloriginal")
            if dispose { try d.dispose() } else {
                try d.cancelActiveComposition()
                try d.apply([TextEdit(TextRange(Position(0,0),Position(0,0)),"x")])
                try d.undo()
            }
            #expect(d.snapshot.text == "original")
            observer.cancel()
        }
    }
    @Test func registryChangesLeaveProviderDataUnavailable() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id:"registry",text:"abc")
        let provider = ClosureProvider { r in .diagnostics([Diagnostic(range:r.snapshot.fullRange,severity:.error,message:"error")]) }
        let first = try workspace.register(language:"*",features:[.diagnostics],provider:provider)
        _ = try await workspace.request(documentID:d.id,feature:.diagnostics)
        #expect(try d.semantics().diagnostics.count == 1 && d.semantics().diagnosticsFreshness == .current)
        let second = try workspace.register(language:"*",features:[.diagnostics],provider:provider)
        #expect(try d.semantics().diagnostics.isEmpty && d.semantics().diagnosticsFreshness == .unavailable)
        _ = try await workspace.request(documentID:d.id,feature:.diagnostics)
        #expect(try d.semantics().diagnosticsFreshness == .current)
        first.cancel(); second.cancel(); try workspace.dispose()
    }
    @Test func registrationSkipsDirectlyDisposedDocuments() throws {
        let workspace = EditorWorkspace()
        try workspace.createDocument(id:"disposed").dispose()
        let provider = try workspace.register(language:"*",features:[.hover],provider:ClosureProvider { _ in .hover(nil) })
        provider.cancel(); try workspace.dispose()
    }
    @Test func cancellationsFromCallbacksTakeEffectAfterTheNotification() async throws {
        let workspace = EditorWorkspace()
        let d = try workspace.createDocument(id:"deferred",text:"abc")
        let registration = try workspace.register(language:"*",features:[.diagnostics],provider:ClosureProvider { r in
            .diagnostics([Diagnostic(range:r.snapshot.fullRange,severity:.error,message:"provider")])
        })
        _ = try await workspace.request(documentID:d.id,feature:.diagnostics)
        let gate = GateProvider()
        let hover = try workspace.register(language:"*",features:[.hover],provider:gate)
        let pending = Task { try await workspace.request(documentID:d.id,feature:.hover) }
        try await gate.waitFor(1)
        var log: [String] = []
        let first = try d.observe { event in
            log.append("first \(event.kind)")
            guard event.kind == .semantics else { return }
            registration.cancel()
            workspace.cancelRequest(documentID:d.id,feature:.hover)
        }
        let second = try d.observe { event in
            let diagnostics = (try? d.semantics().diagnostics.count) ?? -1
            let hover: String
            switch workspace.status(documentID:d.id,feature:.hover) {
            case .pending: hover = "pending"
            case .cancelled: hover = "cancelled"
            default: hover = "other"
            }
            log.append("second \(event.kind) \(diagnostics) \(hover)")
        }
        try d.trackRange(d.snapshot.fullRange)
        #expect(log == ["first semantics", "second semantics 1 pending",
                        "first language", "second language 0 pending",
                        "first language", "second language 0 cancelled"])
        gate.finish(0,.hover(nil))
        await #expect(throws:EditorError.cancelled) { try await pending.value }
        first.cancel(); second.cancel(); hover.cancel(); try workspace.dispose()
    }
    @Test func immutableSnapshotsCrossConcurrencyDomains() async throws {
        let document = Document(id:"snapshot",text:"abc😀\n")
        let snapshot = document.snapshot
        let read = Task.detached {
            (snapshot.text, try snapshot.position(at:5), snapshot.version)
        }
        try document.apply([TextEdit(TextRange(Position(0,0),Position(0,3)),"changed")])
        let (text,position,version) = try await read.value
        #expect(text == "abc😀\n" && position == Position(0,5) && version == 1)
        #expect(document.snapshot.text == "changed😀\n")
    }

    @Test func nestedRegistrationCancellationKeepsOuterMutationGuard() throws {
        let workspace = EditorWorkspace()
        let document = try workspace.createDocument(id: "nested", text: "a")
        let token = try workspace.register(language: "*", features: [.hover], provider: ClosureProvider { _ in .hover(nil) })
        var notifications = 0
        let observer = try document.observe { event in
            guard event.kind == .edit else { return }
            notifications += 1
            token.cancel()
            #expect(throws: EditorError.reentrantMutation) { try document.apply([]) }
        }
        try document.apply([TextEdit(document.snapshot.fullRange, "b")])
        try document.apply([TextEdit(document.snapshot.fullRange, "c")])
        #expect(notifications == 2 && document.snapshot.text == "c")
        observer.cancel(); try workspace.dispose()
    }
    @Test func providerNotificationsProtectEveryAffectedDocument() throws {
        for unregister in [false, true] {
            let workspace = EditorWorkspace()
            let a = try workspace.createDocument(id: "a", text: "abc")
            let b = try workspace.createDocument(id: "b", text: "xyz")
            let provider = ClosureProvider { _ in LanguageResult.hover(nil) }
            let registration = try workspace.register(language: "*", features: [.hover], provider: provider)
            var notifications = 0
            let observations = try [(a, b), (b, a)].map { document, other in
                try document.observe { event in
                    guard event.kind == .language else { return }
                    notifications += 1
                    #expect(throws: EditorError.reentrantMutation) {
                        try other.apply([TextEdit(other.snapshot.fullRange, "changed")])
                    }
                    #expect(throws: EditorError.reentrantMutation) { try workspace.closeDocument(id: other.id) }
                }
            }
            var replacement: Subscription?
            if unregister { registration.cancel() }
            else { replacement = try workspace.register(language: "*", features: [.hover], provider: provider) }
            #expect(notifications == 2)
            #expect(a.snapshot.text == "abc" && b.snapshot.text == "xyz")
            observations.forEach { $0.cancel() }
            replacement?.cancel(); registration.cancel(); try workspace.dispose()
        }
    }
    @Test func providerChangesInvalidateEveryDocumentBeforeAnyNotification() async throws {
        for cancelRegistration in [false, true] {
            let workspace = EditorWorkspace()
            let a = try workspace.createDocument(id: "a", text: "aaa")
            let b = try workspace.createDocument(id: "b", text: "bbb")
            let provider = ClosureProvider { request in
                if request.feature == .diagnostics {
                    return .diagnostics([Diagnostic(range: request.snapshot.fullRange, severity: .error, message: "old")])
                }
                return .completion([CompletionItem(label: "old", edit: WorkspaceEdit([
                    DocumentEdits(snapshot: request.snapshot, edits: [TextEdit(request.snapshot.fullRange, "old provider")])
                ]))])
            }
            let inactive = try workspace.register(language: "*", features: [.completion, .diagnostics], provider: provider)
            let current = try workspace.register(language: "*", features: [.completion, .diagnostics], provider: provider)
            let responseA = try await workspace.request(documentID: a.id, feature: .completion)
            let responseB = try await workspace.request(documentID: b.id, feature: .completion)
            _ = try await workspace.request(documentID: a.id, feature: .diagnostics)
            _ = try await workspace.request(documentID: b.id, feature: .diagnostics)
            var notifications = 0
            var observations: [Subscription] = []
            for (document, other, response) in [(a, b, responseB), (b, a, responseA)] {
                observations.append(try document.observe { event in
                    if event.kind == .language {
                        notifications += 1
                        if notifications == 1 {
                            if case .invalidated = workspace.status(documentID: other.id, feature: .completion) {} else {
                                Issue.record("Another document's completion was still usable during provider change")
                            }
                            #expect(throws: EditorError.reentrantMutation) { try workspace.apply(response) }
                            do { #expect(try other.semantics().diagnostics.isEmpty) }
                            catch { Issue.record("Semantic read failed: \(error)") }
                        }
                    }
                })
            }
            var replacement: Subscription?
            if cancelRegistration { inactive.cancel() }
            else { replacement = try workspace.register(language: "*", features: [.completion, .diagnostics], provider: provider) }
            #expect(notifications == 2)
            #expect(a.snapshot.text == "aaa" && b.snapshot.text == "bbb")
            observations.forEach { $0.cancel() }
            replacement?.cancel(); current.cancel(); inactive.cancel(); try workspace.dispose()
        }
    }
    @Test func workspaceNotificationsProtectNoOpAndEmptyTargets() throws {
        for noOpEdits in [false, true] {
            let workspace = EditorWorkspace()
            let a = try workspace.createDocument(id: "a", text: "aaa")
            let b = try workspace.createDocument(id: "b", text: "bbb")
            let session = try EditorSession(document: b)
            var notifications = 0
            let observation = try a.observe { event in
                if event.kind == .edit {
                    notifications += 1
                    #expect(b.snapshot.text == "bbb" && b.version == 1 && !b.canUndo)
                    #expect(throws: EditorError.reentrantMutation) { try b.apply([TextEdit(b.snapshot.fullRange, "changed")]) }
                    #expect(throws: EditorError.reentrantMutation) { try session.setSelections([Selection(Position(0, 1))]) }
                    #expect(throws: EditorError.reentrantMutation) { try workspace.closeDocument(id: b.id) }
                }
            }
            var bNotifications = 0
            let otherObservation = try b.observe { _ in bNotifications += 1 }
            try workspace.apply(WorkspaceEdit([
                DocumentEdits(snapshot: a.snapshot, edits: [TextEdit(a.snapshot.fullRange, "AAA")]),
                DocumentEdits(snapshot: b.snapshot, edits: noOpEdits ? [TextEdit(b.snapshot.fullRange, "bbb")] : [])
            ]))
            #expect(notifications == 1 && bNotifications == 0)
            #expect(b.snapshot.text == "bbb" && b.version == 1 && !b.canUndo)
            observation.cancel(); otherObservation.cancel()
            try b.apply([TextEdit(b.snapshot.fullRange, "after")])
            #expect(b.snapshot.text == "after")
            try workspace.dispose()
        }
    }
    @Test func foldingNotificationsAllowReadsAndStillRejectWrites() throws {
        let document = Document(id: "folds", text: "heading\nbody\nend")
        let session = try EditorSession(document: document)
        let fold = FoldingRange(range: TextRange(Position(0, 0), Position(2, 3)))
        try document.setFoldingRanges([fold], version: document.version)
        var notifications = 0
        let observation = try document.observe { event in
            if event.kind == .semantics {
                notifications += 1
                let expected: [Range<Int>] = notifications == 1 ? [1..<3] : []
                do { #expect(try session.hiddenLineRanges() == expected) }
                catch { Issue.record("Folding read failed during notification: \(error)") }
                #expect(throws: EditorError.reentrantMutation) { try session.setCollapsed(false, foldID: fold.id) }
            }
        }
        try session.setCollapsed(true, foldID: fold.id)
        try session.setCollapsed(false, foldID: fold.id)
        #expect(notifications == 2)
        observation.cancel(); try session.dispose()
        #expect(throws: EditorError.disposed) { try session.hiddenLineRanges() }
    }
    @Test func closeRejectsReentryFromDisposalNotification() throws {
        let workspace = EditorWorkspace()
        let document = try workspace.createDocument(id: "reused", text: "old")
        var notified = false
        var replacement: Document?
        let observation = try document.observe { event in
            if event.kind == .disposed {
                notified = true
                #expect(throws: EditorError.reentrantMutation) {
                    try workspace.closeDocument(id: document.id)
                    replacement = try workspace.createDocument(id: document.id, text: "new")
                }
                #expect(workspace.documents[document.id] === document)
            }
        }
        try workspace.closeDocument(id: document.id)
        #expect(notified && replacement == nil)
        #expect(document.isDisposed && workspace.documents[document.id] == nil)
        let reopened = try workspace.createDocument(id: document.id, text: "new")
        #expect(try workspace.document(id: document.id) === reopened)
        #expect(!reopened.isDisposed)
        observation.cancel(); try workspace.dispose()
    }
    @Test func directDocumentDisposalRejectsWorkspaceLifecycleReentry() throws {
        let workspace = EditorWorkspace()
        let document = try workspace.createDocument(id: "document", text: "old")
        var disposedEvents = 0
        let observation = try document.observe { event in
            if event.kind == .disposed {
                disposedEvents += 1
                #expect(throws: EditorError.reentrantMutation) { try workspace.closeDocument(id: document.id) }
                #expect(throws: EditorError.reentrantMutation) { try workspace.dispose() }
                #expect(workspace.documents[document.id] === document)
            }
        }
        try document.dispose()
        #expect(disposedEvents == 1)
        try workspace.closeDocument(id: document.id)
        let replacement = try workspace.createDocument(id: document.id, text: "new")
        #expect(try workspace.document(id: document.id) === replacement)
        observation.cancel(); try workspace.dispose()
    }
}
