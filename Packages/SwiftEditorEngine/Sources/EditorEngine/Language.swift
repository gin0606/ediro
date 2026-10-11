import Foundation

public enum LanguageFeature: String, CaseIterable, Hashable, Sendable {
    case completion, hover, signatureHelp, definition, references, documentSymbols
    case rename, codeActions, formatting, tokens, semanticTokens, diagnostics, folding, inlayHints
}
public struct DocumentEdits: Sendable, Equatable {
    public var documentID: String
    public var expectedVersion: Int
    public var edits: [TextEdit]
    var expectedInstanceID: UUID?
    public init(documentID: String, expectedVersion: Int, edits: [TextEdit]) {
        self.documentID = documentID; self.expectedVersion = expectedVersion; self.edits = edits
    }
    /// Bind delayed edits to both the snapshot's version and its document instance.
    public init(snapshot: TextSnapshot, edits: [TextEdit]) {
        self.init(documentID: snapshot.documentID, expectedVersion: snapshot.version, edits: edits)
        expectedInstanceID = snapshot.instanceID
    }
}
public struct WorkspaceEdit: Sendable, Equatable {
    public var documents: [DocumentEdits]
    public init(_ documents: [DocumentEdits]) { self.documents = documents }
}
public struct CompletionItem: Sendable, Equatable {
    public var label: String
    public var detail: String?
    public var edit: WorkspaceEdit
    public init(label: String, detail: String? = nil, edit: WorkspaceEdit) { self.label = label; self.detail = detail; self.edit = edit }
}
public struct Hover: Sendable, Equatable {
    public var range: TextRange
    public var contents: [String]
    public init(range: TextRange, contents: [String]) { self.range = range; self.contents = contents }
}
public struct Signature: Sendable, Equatable {
    public var label: String
    public var documentation: String?
    public var parameters: [String]
    public init(label: String, documentation: String? = nil, parameters: [String] = []) {
        self.label = label; self.documentation = documentation; self.parameters = parameters
    }
}
public struct SignatureHelp: Sendable, Equatable {
    public var signatures: [Signature]
    public var activeSignature: Int
    public var activeParameter: Int?
    public init(signatures: [Signature], activeSignature: Int = 0, activeParameter: Int? = nil) {
        self.signatures = signatures; self.activeSignature = activeSignature; self.activeParameter = activeParameter
    }
}
public struct DocumentLocation: Sendable, Equatable {
    public var documentID: String
    public var range: TextRange
    public init(documentID: String, range: TextRange) { self.documentID = documentID; self.range = range }
}
public struct DocumentSymbol: Sendable, Equatable {
    public var name: String
    public var kind: String
    public var range: TextRange
    public var selectionRange: TextRange
    public var children: [DocumentSymbol]
    public init(name: String, kind: String, range: TextRange, selectionRange: TextRange, children: [DocumentSymbol] = []) {
        self.name = name; self.kind = kind; self.range = range; self.selectionRange = selectionRange; self.children = children
    }
}
public struct CodeAction: Sendable, Equatable {
    public var title: String
    public var kind: String
    public var edit: WorkspaceEdit
    public init(title: String, kind: String, edit: WorkspaceEdit) { self.title = title; self.kind = kind; self.edit = edit }
}
public enum LanguageResult: Sendable, Equatable {
    case completion([CompletionItem]), hover(Hover?), signatureHelp(SignatureHelp?)
    case definition([DocumentLocation]), references([DocumentLocation]), documentSymbols([DocumentSymbol])
    case rename(WorkspaceEdit), codeActions([CodeAction]), formatting(WorkspaceEdit)
    case tokens([HighlightToken]), semanticTokens([HighlightToken]), diagnostics([Diagnostic])
    case folding([FoldingRange]), inlayHints([InlayHint])
    public var feature: LanguageFeature {
        switch self {
        case .completion: .completion
        case .hover: .hover
        case .signatureHelp: .signatureHelp
        case .definition: .definition
        case .references: .references
        case .documentSymbols: .documentSymbols
        case .rename: .rename
        case .codeActions: .codeActions
        case .formatting: .formatting
        case .tokens: .tokens
        case .semanticTokens: .semanticTokens
        case .diagnostics: .diagnostics
        case .folding: .folding
        case .inlayHints: .inlayHints
        }
    }
}
public struct LanguageRequest: Sendable {
    public let feature: LanguageFeature
    public let snapshot: TextSnapshot
    public let position: Position?
    public let range: TextRange?
    public let newName: String?
}
@MainActor public protocol LanguageProvider {
    func provide(_ request: LanguageRequest) async throws -> LanguageResult
}
@MainActor public struct ClosureProvider: LanguageProvider {
    let body: @MainActor (LanguageRequest) async throws -> LanguageResult
    public init(_ body: @escaping @MainActor (LanguageRequest) async throws -> LanguageResult) { self.body = body }
    public func provide(_ request: LanguageRequest) async throws -> LanguageResult { try await body(request) }
}
public struct LanguageResponse: Sendable {
    public let documentID: String
    public let version: Int
    public let result: LanguageResult
    let requestID: UUID
    let providerID: UUID
}
public enum LanguageStatus: Sendable {
    case idle, pending, ready(LanguageResponse), failed(any Error), cancelled, invalidated
}
struct RequestKey: Hashable { let documentID: String; let feature: LanguageFeature }
@MainActor struct ProviderRegistration {
    let id: UUID
    let language: String
    let features: Set<LanguageFeature>
    let provider: any LanguageProvider
}
/// Why the engine or the caller ended a request before its result was published.
enum RequestEnding {
    case cancelledByCaller, cancelledExplicitly, superseded, invalidated
    var error: any Error {
        switch self {
        case .cancelledByCaller: CancellationError()
        case .cancelledExplicitly: EditorError.cancelled
        case .superseded, .invalidated: EditorError.staleResult
        }
    }
}
/// One request's lifetime. The first recorded ending decides its outcome, and the caller
/// resumes as soon as it is recorded, without waiting for the provider to return.
@MainActor final class PendingRequest {
    enum Outcome { case provider(Result<LanguageResult, any Error>), ended }
    let id = UUID()
    var providerTask: Task<Void, Never>?
    private(set) var ending: RequestEnding?
    var isSettled = false
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?
    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }
    func deliver(_ value: Outcome) {
        guard outcome == nil else { return }
        outcome = value; continuation?.resume(returning: value); continuation = nil
    }
    /// Records why the request ended; returns false when it had already ended or settled.
    func end(_ reason: RequestEnding) -> Bool {
        guard ending == nil, !isSettled else { return false }
        ending = reason; providerTask?.cancel(); deliver(.ended)
        return true
    }
}

@MainActor public final class EditorWorkspace {
    public private(set) var documents: [String: Document] = [:]
    public private(set) var isDisposed = false
    var isDisposing = false
    var providers: [ProviderRegistration] = []
    var active: [RequestKey: PendingRequest] = [:]
    /// Written through `setStatus` so the document's next notification reports the change.
    var statuses: [RequestKey: LanguageStatus] = [:]
    var deferred: [() -> Void] = []
    var isDraining = false
    var awaitsCallbacks = false

    public init() {}
    func ensureAlive() throws { if isDisposed || isDisposing { throw EditorError.disposed } }
    /// Writes during disposal come from its notifications, so they are reentrant.
    func ensureWritable() throws {
        if isDisposing { throw EditorError.reentrantMutation }
        try ensureAlive()
    }
    @discardableResult public func createDocument(id: String, text: String = "", language: String = "plaintext", endOfLine: EndOfLine = .lf) throws -> Document {
        try ensureWritable(); guard documents[id] == nil else { throw EditorError.duplicateDocument }
        let document = Document(id: id, text: text, language: language, endOfLine: endOfLine)
        documents[id] = document
        document.invalidation = { [weak self] in self?.invalidate(documentID: id) }
        return document
    }
    public func document(id: String) throws -> Document {
        try ensureAlive(); guard let d = documents[id] else { throw EditorError.missingDocument(id) }; try d.ensureAlive(); return d
    }
    public func closeDocument(id: String) throws {
        try ensureWritable()
        guard let doc = documents[id] else { throw EditorError.missingDocument(id) }
        if doc.isLocked { throw EditorError.reentrantMutation }
        // Statuses go first, so the disposal notification already sees the document closed.
        if !doc.isDisposed { try doc.ensureMutable() }
        Callbacks.beginOperation(); defer { Callbacks.endOperation() }
        let keys = statuses.keys.filter { $0.documentID == id }
        for key in keys { statuses.removeValue(forKey: key) }
        if !keys.isEmpty { doc.pendingChanges.insert(.requests) }
        if !doc.isDisposed { try doc.dispose() }
        if documents[id] === doc { documents.removeValue(forKey: id) }
    }
    public func register(language: String, features: Set<LanguageFeature>, provider: any LanguageProvider) throws -> Subscription {
        try ensureWritable()
        // Registration notifies documents, so it waits until no notification is running,
        // including those of standalone documents and other workspaces.
        if Callbacks.depth > 0 { throw EditorError.reentrantMutation }
        let registration = ProviderRegistration(id: UUID(), language: language, features: features, provider: provider)
        providers.append(registration)
        let registrationID = registration.id
        invalidateRegistration(language: language, features: features)
        return Subscription { [weak self] in
            self?.whenUnlocked { [weak self] in
                guard let self else { return }
                self.providers.removeAll { $0.id == registrationID }
                self.invalidateRegistration(language: language, features: features)
            }
        }
    }
    /// Runs an operation that cannot throw `reentrantMutation` now, or after every
    /// document's callbacks have finished, so callbacks never observe its effects.
    func whenUnlocked(_ operation: @escaping () -> Void) {
        // After disposal there are no providers or requests left to remove.
        guard !isDisposed else { return }
        deferred.append(operation)
        if Callbacks.idle { drainDeferred() }
        else if !awaitsCallbacks { awaitsCallbacks = true; Callbacks.whenFinished { [weak self] in self?.awaitsCallbacks = false; self?.drainDeferred() } }
    }
    func drainDeferred() {
        guard !isDraining else { return }
        isDraining = true; defer { isDraining = false }
        while !deferred.isEmpty, !isDisposed, !isDisposing, Callbacks.idle {
            deferred.removeFirst()()
        }
    }
    func invalidateRegistration(language: String, features: Set<LanguageFeature>) {
        let targets = documents.values.filter { !$0.isDisposed && (language == "*" || $0.language == language) }.sorted { $0.id < $1.id }
        for doc in targets { doc.lock() }
        defer { for doc in targets { doc.unlock() } }
        for doc in targets {
            invalidate(documentID: doc.id, features: features)
            for feature in features where doc.semanticProviders.removeValue(forKey: feature) != nil {
                doc.semanticVersions.removeValue(forKey: feature)
                switch feature {
                case .tokens: doc.tokens = []
                case .semanticTokens: doc.semanticTokens = []
                case .diagnostics: doc.diagnostics = []
                case .folding: doc.foldingRanges = []; for editor in doc.liveEditors { editor.collapsedFolds = [] }
                case .inlayHints: doc.inlayHints = []
                default: break
                }
            }
        }
        for doc in targets { doc.emit(.language) }
    }
    func invalidate(documentID: String, features: Set<LanguageFeature> = Set(LanguageFeature.allCases)) {
        for feature in features {
            let key = RequestKey(documentID: documentID, feature: feature)
            _ = active.removeValue(forKey: key)?.end(.invalidated)
            switch statuses[key] { case nil, .invalidated: break; default: setStatus(.invalidated, for: key) }
        }
    }
    public func status(documentID: String, feature: LanguageFeature) -> LanguageStatus {
        statuses[RequestKey(documentID: documentID, feature: feature)] ?? .idle
    }
    public func cancelRequest(documentID: String, feature: LanguageFeature) {
        let key = RequestKey(documentID: documentID, feature: feature)
        whenUnlocked { [weak self] in
            guard let self, let pending = self.active[key] else { return }
            self.cancel(pending, key: key, reason: .cancelledExplicitly)
        }
    }
    func setStatus(_ status: LanguageStatus, for key: RequestKey) {
        let changed: Bool
        switch (statuses[key], status) {
        case (.idle?, .idle), (.pending?, .pending), (.cancelled?, .cancelled), (.invalidated?, .invalidated): changed = false
        case (.ready(let a)?, .ready(let b)): changed = a.requestID != b.requestID
        // Errors are compared only when the engine raised both.
        case (.failed(let a)?, .failed(let b)): changed = (a as? EditorError).map { $0 != b as? EditorError } ?? true
        default: changed = true
        }
        statuses[key] = status
        if changed { documents[key.documentID]?.pendingChanges.insert(.requests) }
    }
    func cancel(_ pending: PendingRequest, key: RequestKey, reason: RequestEnding) {
        guard pending.end(reason) else { return }
        guard active[key] === pending else { return }
        active.removeValue(forKey: key); setStatus(.cancelled, for: key)
        documents[key.documentID]?.emit(.language)
    }
    public func request(documentID: String, feature: LanguageFeature, position: Position? = nil,
                        range: TextRange? = nil, newName: String? = nil) async throws -> LanguageResponse {
        let doc = try document(id: documentID); try doc.ensureMutable(); try Task.checkCancellation()
        let snapshot = doc.snapshot
        let requestInstances = documents.mapValues(\.instanceID), requestVersions = documents.mapValues(\.version)
        if let position { _ = try snapshot.offset(at: position) }
        if let range { _ = try snapshot.offsets(in: range) }
        let key = RequestKey(documentID: documentID, feature: feature)
        guard let provider = providers.last(where: { ($0.language == snapshot.language || $0.language == "*") && $0.features.contains(feature) }) else {
            setStatus(.failed(EditorError.noProvider), for: key); doc.emit(.language); throw EditorError.noProvider
        }
        _ = active.removeValue(forKey: key)?.end(.superseded)
        let pending = PendingRequest(), id = pending.id
        let request = LanguageRequest(feature: feature, snapshot: snapshot, position: position, range: range, newName: newName)
        let providerTask = Task { @MainActor in
            let result: Result<LanguageResult, any Error>
            do { try Task.checkCancellation(); result = .success(try await provider.provider.provide(request)) }
            catch { result = .failure(error) }
            pending.deliver(.provider(result))
        }
        pending.providerTask = providerTask
        active[key] = pending; setStatus(.pending, for: key); doc.emit(.language)
        let outcome = await withTaskCancellationHandler {
            await pending.wait()
        } onCancel: { [weak self] in
            providerTask.cancel()
            Task { @MainActor in self?.cancel(pending, key: key, reason: .cancelledByCaller) }
        }
        // The caller's own cancellation counts even when the provider finished first.
        if pending.ending == nil, Task.isCancelled { cancel(pending, key: key, reason: .cancelledByCaller) }
        if let ending = pending.ending { throw Task.isCancelled ? CancellationError() : ending.error }
        // Every path that makes a result obsolete ends the request first; this only guards that.
        guard case .provider(let providerResult) = outcome, active[key] === pending, !doc.isDisposed, !isDisposed,
              documents[documentID] === doc, doc.version == snapshot.version,
              providers.contains(where: { $0.id == provider.id }) else { throw EditorError.staleResult }
        pending.isSettled = true
        active.removeValue(forKey: key)
        do {
            var result = try providerResult.get()
            guard result.feature == feature else { throw EditorError.invalidProviderResult }
            // LSP lets active indices fall outside the signatures; clear them so apps can index safely.
            if case .signatureHelp(var help?) = result {
                if !help.signatures.indices.contains(help.activeSignature) { help.activeSignature = 0 }
                if let p = help.activeParameter, help.signatures.isEmpty || !help.signatures[help.activeSignature].parameters.indices.contains(p) {
                    help.activeParameter = nil
                }
                result = .signatureHelp(help)
            }
            result = try bindEdits(in: result, to: requestInstances, versions: requestVersions)
            let response = LanguageResponse(documentID: documentID, version: snapshot.version, result: result, requestID: id, providerID: provider.id)
            // Past the staleness checks, any engine error is the provider's, not one in the
            // caller's arguments. Semantic output and the ready status publish in one notification.
            do { try validate(result, snapshot: snapshot); try storeSemantic(result, in: doc) }
            catch is EditorError { throw EditorError.invalidProviderResult }
            if [.tokens, .semanticTokens, .diagnostics, .folding, .inlayHints].contains(feature) {
                doc.semanticProviders[feature] = provider.id
            }
            setStatus(.ready(response), for: key); doc.emit(.language)
            return response
        } catch {
            setStatus(.failed(error), for: key); doc.emit(.language)
            throw error
        }
    }
    /// Binds edit targets to the documents open when the request started. A target open at
    /// neither time is an invalid result; one opened, closed, reopened or edited since makes
    /// it stale, because requesting again could succeed.
    func bindEdits(in result: LanguageResult, to instances: [String: UUID], versions: [String: Int]) throws -> LanguageResult {
        func bind(_ edit: WorkspaceEdit) throws -> WorkspaceEdit {
            WorkspaceEdit(try edit.documents.map { target in
                guard let instance = instances[target.documentID] else {
                    throw documents[target.documentID] == nil ? EditorError.invalidProviderResult : EditorError.staleResult
                }
                guard let doc = documents[target.documentID], !doc.isDisposed, doc.instanceID == instance,
                      target.expectedInstanceID == nil || target.expectedInstanceID == doc.instanceID,
                      doc.version == versions[target.documentID] else {
                    throw EditorError.staleResult
                }
                var target = target; target.expectedInstanceID = doc.instanceID
                return target
            })
        }
        switch result {
        case .completion(let items):
            return .completion(try items.map { item in var item = item; item.edit = try bind(item.edit); return item })
        case .codeActions(let actions):
            return .codeActions(try actions.map { action in var action = action; action.edit = try bind(action.edit); return action })
        case .rename(let edit): return .rename(try bind(edit))
        case .formatting(let edit): return .formatting(try bind(edit))
        case .definition(let locations), .references(let locations):
            // Locations in documents that changed since the request started point at old text.
            for location in locations {
                if let instance = instances[location.documentID] {
                    guard let doc = documents[location.documentID], !doc.isDisposed, doc.instanceID == instance,
                          doc.version == versions[location.documentID] else { throw EditorError.staleResult }
                } else if documents[location.documentID] != nil { throw EditorError.staleResult }
            }
            return result
        default: return result
        }
    }
    func validate(_ result: LanguageResult, snapshot: TextSnapshot) throws {
        func check(_ range: TextRange) throws { _ = try snapshot.offsets(in: range) }
        func checkWorkspace(_ edit: WorkspaceEdit) throws {
            guard Set(edit.documents.map(\.documentID)).count == edit.documents.count else { throw EditorError.invalidProviderResult }
            // Validate against current documents now; preflight again at application time.
            for target in edit.documents { _ = try document(id: target.documentID).prepare(target.edits, expectedVersion: target.expectedVersion) }
        }
        func symbol(_ s: DocumentSymbol, parent: TextRange? = nil) throws {
            try check(s.range); try check(s.selectionRange)
            guard s.selectionRange.start >= s.range.start, s.selectionRange.end <= s.range.end else { throw EditorError.invalidProviderResult }
            if let parent, s.range.start < parent.start || s.range.end > parent.end { throw EditorError.invalidProviderResult }
            for child in s.children { try symbol(child, parent: s.range) }
        }
        switch result {
        case .completion(let items): for item in items { try checkWorkspace(item.edit) }
        case .hover(let hover): if let hover { try check(hover.range) }
        case .signatureHelp: break
        case .definition(let locations), .references(let locations):
            for location in locations {
                guard location.range.start.line >= 0, location.range.start.column >= 0,
                      location.range.end.line >= 0, location.range.end.column >= 0,
                      location.range.end >= location.range.start else { throw EditorError.invalidProviderResult }
                if let doc = documents[location.documentID] { _ = try doc.snapshot.offsets(in: location.range) }
            }
        case .documentSymbols(let symbols): for s in symbols { try symbol(s) }
        case .rename(let edit), .formatting(let edit): try checkWorkspace(edit)
        case .codeActions(let actions): for action in actions { try checkWorkspace(action.edit) }
        case .tokens(let tokens), .semanticTokens(let tokens): for token in tokens { try check(token.range) }
        case .diagnostics(let diagnostics): for d in diagnostics { try check(d.range) }
        case .folding(let folds):
            for f in folds { try check(f.range) }
            guard Set(folds.map(\.id)).count == folds.count, nestedFolds(orderedFolds(folds)).count == folds.count else {
                throw EditorError.invalidProviderResult
            }
        case .inlayHints(let hints):
            for h in hints { _ = try snapshot.offset(at: h.position); _ = try document(id: snapshot.documentID).prepare(h.edits, expectedVersion: snapshot.version) }
        }
    }
    func storeSemantic(_ result: LanguageResult, in doc: Document) throws {
        doc.notificationSuppression += 1
        defer { doc.notificationSuppression -= 1 }
        switch result {
        case .tokens(let values): try doc.setTokens(values, version: doc.version)
        case .semanticTokens(let values): try doc.setTokens(values, semantic: true, version: doc.version)
        case .diagnostics(let values): try doc.setDiagnostics(values, version: doc.version)
        case .folding(let values): try doc.setFoldingRanges(values, version: doc.version)
        case .inlayHints(let values): try doc.setInlayHints(values, version: doc.version)
        default: break
        }
    }
    /// Apply an editing result retained by this engine. Completion and code actions
    /// require an item index. Version, registration and request provenance are checked.
    public func apply(_ response: LanguageResponse, item: Int = 0) throws {
        switch response.result {
        case .completion, .codeActions, .rename, .formatting: break
        default: throw EditorError.notApplicable
        }
        let doc = try document(id: response.documentID); try doc.ensureMutable(); try doc.checkVersion(response.version)
        let key = RequestKey(documentID: response.documentID, feature: response.result.feature)
        guard case .ready(let current) = statuses[key], current.requestID == response.requestID,
              providers.contains(where: { $0.id == response.providerID }) else { throw EditorError.staleResult }
        let edit: WorkspaceEdit
        switch response.result {
        case .completion(let items):
            guard items.indices.contains(item) else { throw EditorError.invalidRange }; edit = items[item].edit
        case .codeActions(let items):
            guard items.indices.contains(item) else { throw EditorError.invalidRange }; edit = items[item].edit
        case .rename(let value), .formatting(let value): edit = value
        default: throw EditorError.notApplicable
        }
        try apply(edit)
    }
    /// All target documents must already be open. Every target is preflighted before
    /// any mutation. Versions are mandatory; failure leaves all documents unchanged.
    public func apply(_ edit: WorkspaceEdit, historyGroup: String? = nil) throws {
        try ensureWritable()
        guard Set(edit.documents.map(\.documentID)).count == edit.documents.count else { throw EditorError.overlappingEdits }
        var targets: [Document] = []
        var prepared: [(Document, PreparedEdit, RopeNode?, [UUID: SelectionState])] = []
        for target in edit.documents {
            let doc = try document(id: target.documentID)
            if let expected = target.expectedInstanceID, expected != doc.instanceID { throw EditorError.staleResult }
            try doc.ensureMutable()
            if doc.compositionOwner != nil { throw EditorError.compositionActive }
            let batch = try doc.prepare(target.edits, expectedVersion: target.expectedVersion)
            targets.append(doc)
            if !batch.changes.isEmpty { prepared.append((doc, batch, doc.root, doc.selectionStates)) }
        }
        for (doc,batch,_,_) in prepared { doc.install(batch) }
        for (doc,batch,before,selections) in prepared { doc.record(before: before, selections: selections, batches: [batch.changes], group: historyGroup) }
        // During callbacks, every target is readable and already at its final state.
        // Reject nested writes to any target until all callbacks have finished.
        for doc in targets { doc.lock() }
        defer { for doc in targets { doc.unlock() } }
        // Every target is in its final state, carets included, before the first notification.
        for (doc,_,_,_) in prepared { doc.revealCarets() }
        for (doc,batch,_,_) in prepared { doc.emit(.edit, batches: [batch.changes]) }
    }
    public func dispose() throws {
        try ensureWritable()
        if Callbacks.depth > 0 { throw EditorError.reentrantMutation }
        let remaining = documents.values.filter { !$0.isDisposed }.sorted { $0.id < $1.id }
        for doc in remaining { try doc.ensureMutable() }
        Callbacks.beginOperation(); defer { Callbacks.endOperation() }
        isDisposing = true
        defer { isDisposing = false }
        for doc in remaining where !doc.isDisposed {
            // The others reject writes while this document's disposal notification runs.
            let others = remaining.filter { $0 !== doc && !$0.isDisposed }
            others.forEach { $0.lock() }
            defer { others.forEach { $0.unlock() } }
            try doc.dispose()
        }
        for pending in active.values { _ = pending.end(.invalidated) }
        active = [:]; providers = []; statuses = [:]; documents = [:]; deferred = []; isDisposed = true
    }
}
