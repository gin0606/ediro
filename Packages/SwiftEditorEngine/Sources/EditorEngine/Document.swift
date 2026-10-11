import Foundation

public struct ContentChange: Sendable, Equatable {
    public let offset: Int
    public let removedText: String
    public let insertedText: String
    public var removedLength: Int { removedText.utf16.count }
    public var insertedLength: Int { insertedText.utf16.count }
}
public enum ChangeKind: Sendable { case edit, undo, redo, composition, semantics, selection, language, disposed }
/// The state that changed since the document's previous notification.
public struct DocumentChanges: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// The text and its version.
    public static let text = DocumentChanges(rawValue: 1 << 0)
    /// The selections of any session, or a session detaching from the document.
    public static let selection = DocumentChanges(rawValue: 1 << 1)
    /// Provisional input of any session.
    public static let composition = DocumentChanges(rawValue: 1 << 2)
    /// Semantic data, its freshness, or the collapse state of any session.
    public static let semantics = DocumentChanges(rawValue: 1 << 3)
    /// Language request statuses for the document.
    public static let requests = DocumentChanges(rawValue: 1 << 4)
    /// Line tokens from the document's line tokenizer; `DocumentEvent.retokenizedLines` names the lines.
    public static let lineTokens = DocumentChanges(rawValue: 1 << 5)
}
public struct DocumentEvent: Sendable {
    /// The operation that caused the notification.
    public let kind: ChangeKind
    public let version: Int
    /// Each batch uses offsets in the document immediately before that batch.
    public let batches: [[ContentChange]]
    /// Everything the operation changed; one operation can change several kinds of state.
    public let changes: DocumentChanges
    /// The lines whose line tokens were recomputed or removed, numbered in the text after the
    /// operation. Every line an edit touched is included.
    public let retokenizedLines: IndexSet
}
@MainActor public final class Subscription {
    private var cancellation: (() -> Void)?
    init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    public func cancel() { let callback = cancellation; cancellation = nil; callback?() }
}
struct PreparedEdit {
    let root: RopeNode?
    let changes: [ContentChange]
}
struct HistoryEntry {
    var before: RopeNode?
    var after: RopeNode?
    var batches: [[ContentChange]]
    var beforeSelections: [UUID: SelectionState]
    var afterSelections: [UUID: SelectionState]
    var group: String?
}
@MainActor final class WeakEditor {
    weak var value: EditorSession?
    init(_ value: EditorSession) { self.value = value }
}
/// Maps offsets through one batch of sorted changes. The batch is coalesced, so each
/// change ends before the next one starts, and a lookup is a binary search.
struct ChangeMap {
    let changes: [ContentChange]
    /// The length delta of all changes before each index.
    private let deltas: [Int]
    init(_ changes: [ContentChange]) {
        self.changes = changes
        var deltas = [0]; deltas.reserveCapacity(changes.count + 1)
        for c in changes { deltas.append(deltas[deltas.count - 1] + c.insertedLength - c.removedLength) }
        self.deltas = deltas
    }
    func map(_ offset: Int, affinity: Affinity) -> Int {
        var low = 0, high = changes.count
        while low < high { let mid = (low + high) / 2; if changes[mid].offset <= offset { low = mid + 1 } else { high = mid } }
        guard low > 0 else { return offset }
        let c = changes[low - 1], delta = deltas[low - 1], end = c.offset + c.removedLength
        if offset > end || (c.removedLength > 0 && offset == end) { return offset + deltas[low] }
        // The start of replaced text is a boundary, not part of it: an endpoint there stays
        // before the new text. Insertions at an endpoint and replaced interiors use affinity.
        if c.removedLength > 0 && offset == c.offset { return c.offset + delta }
        return c.offset + delta + (affinity == .after ? c.insertedLength : 0)
    }
}
func inverse(_ changes: [ContentChange]) -> [ContentChange] {
    var delta = 0
    return changes.map { c in
        let result = ContentChange(offset: c.offset + delta, removedText: c.insertedText, insertedText: c.removedText)
        delta += c.insertedLength - c.removedLength; return result
    }
}

/// Counts callbacks into the application across all documents, standalone or in a workspace.
/// Work deferred until no callback runs waits for the count to return to zero.
/// Operations that notify and then keep working count too, so deferred work never runs
/// between their steps.
@MainActor enum Callbacks {
    static var depth = 0
    private static var operations = 0
    private static var waiting: [() -> Void] = []
    static var idle: Bool { depth == 0 && operations == 0 }
    static func whenFinished(_ work: @escaping () -> Void) { waiting.append(work) }
    static func finishIfIdle() {
        guard idle else { return }
        let work = waiting; waiting = []; work.forEach { $0() }
    }
    static func beginOperation() { operations += 1 }
    static func endOperation() { operations -= 1; finishIfIdle() }
}
@MainActor public final class Document {
    public let id: String
    let instanceID = UUID()
    public let language: String
    public let endOfLine: EndOfLine
    public private(set) var version = 1 { didSet { pendingChanges.insert(.text) } }
    public private(set) var isDisposed = false
    var root: RopeNode?
    var undoEntries: [HistoryEntry] = []
    var redoEntries: [HistoryEntry] = []
    /// The group opened by `beginHistoryGroup(_:)`, which selection changes do not split.
    public internal(set) var heldGroup: String?
    var editors: [UUID: WeakEditor] = [:]
    var listeners: [(token: UUID, callback: (DocumentEvent) -> Void)] = []
    /// Writes throw `reentrantMutation` while this is positive (during callbacks into the application).
    var lockDepth = 0
    var notificationSuppression = 0
    /// Collected as state changes and reported by the next notification.
    var pendingChanges: DocumentChanges = []
    /// Range tracking reports its own changes instead of comparing whole collections.
    var isTrackingSemantics = false
    var semanticProviders: [LanguageFeature: UUID] = [:]
    var compositionOwner: UUID? { didSet { if compositionOwner != oldValue { pendingChanges.insert(.composition) } } }
    var activeComposition: CompositionState?
    var invalidation: (() -> Void)?
    var tokens: [HighlightToken] = [] { didSet { if !isTrackingSemantics { semanticsChanged(oldValue != tokens) } } }
    var semanticTokens: [HighlightToken] = [] { didSet { if !isTrackingSemantics { semanticsChanged(oldValue != semanticTokens) } } }
    var diagnostics: [Diagnostic] = [] { didSet { if !isTrackingSemantics { semanticsChanged(oldValue != diagnostics) } } }
    /// The version each kind of semantic data was computed for; absent when there is none.
    var semanticVersions: [LanguageFeature: Int] = [:] { didSet { semanticsChanged(oldValue != semanticVersions) } }
    var decorations: [Decoration] = [] { didSet { if !isTrackingSemantics { semanticsChanged(oldValue != decorations) } } }
    var trackedRanges: [UUID: TrackedRange] = [:] { didSet { if !isTrackingSemantics { semanticsChanged(oldValue != trackedRanges) } } }
    var foldingRanges: [FoldingRange] = [] { didSet { if !isTrackingSemantics { semanticsChanged(oldValue != foldingRanges) } } }
    var inlayHints: [InlayHint] = [] { didSet { if !isTrackingSemantics { semanticsChanged(oldValue != inlayHints) } } }
    /// Line tokens are kept apart from `tokens`: they are not tracked through edits, and
    /// provider results never replace or clear them.
    var lineTokenizer: AnyLineTokenizer?
    var lineEntries: [LineEntry] = []
    /// Collected as lines are tokenized and reported by the next notification.
    var retokenizedLines = IndexSet()

    public init(id: String, text: String = "", language: String = "plaintext", endOfLine: EndOfLine = .lf,
                lineTokenizer: (any LineTokenizer)? = nil) {
        self.id = id; self.language = language; self.endOfLine = endOfLine
        root = RopeNode.build(Array(normalized(text, eol: endOfLine).utf16))
        if let lineTokenizer { tokenizeAllLines(with: AnyLineTokenizer(lineTokenizer)) }
        retokenizedLines = []; pendingChanges = []
    }
    public var snapshot: TextSnapshot {
        TextSnapshot(documentID: id, instanceID: instanceID, language: language, version: version, endOfLine: endOfLine, root: root)
    }
    public var canUndo: Bool { !undoEntries.isEmpty && !isDisposed && compositionOwner == nil }
    public var canRedo: Bool { !redoEntries.isEmpty && !isDisposed && compositionOwner == nil }
    var liveEditors: [EditorSession] {
        editors = editors.filter { $0.value.value != nil }
        return editors.values.compactMap(\.value)
    }
    var selectionStates: [UUID: SelectionState] { Dictionary(uniqueKeysWithValues: liveEditors.map { ($0.id, $0.selectionState) }) }
    func semanticsChanged(_ changed: Bool) { if changed { pendingChanges.insert(.semantics) } }
    func ensureAlive() throws { if isDisposed { throw EditorError.disposed } }
    func ensureMutable() throws { try ensureAlive(); if isLocked { throw EditorError.reentrantMutation } }
    var isLocked: Bool { lockDepth > 0 }
    func lock() { lockDepth += 1; Callbacks.depth += 1 }
    func unlock() { lockDepth -= 1; Callbacks.depth -= 1; Callbacks.finishIfIdle() }
    func whileLocked<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
    func checkVersion(_ expected: Int?) throws {
        if let expected, expected != version { throw EditorError.staleVersion(expected: expected, actual: version) }
    }
    public func observe(_ listener: @escaping @MainActor (DocumentEvent) -> Void) throws -> Subscription {
        try ensureAlive(); let token = UUID(); listeners.append((token, listener))
        return Subscription { [weak self] in self?.listeners.removeAll { $0.token == token } }
    }
    func emit(_ kind: ChangeKind, batches: [[ContentChange]] = []) {
        if notificationSuppression > 0 { return }
        revealCarets()
        let event = DocumentEvent(kind: kind, version: version, batches: batches, changes: pendingChanges,
                                  retokenizedLines: retokenizedLines)
        pendingChanges = []; retokenizedLines = []
        whileLocked {
            // Call in registration order, skipping listeners cancelled by an earlier callback.
            for listener in listeners where listeners.contains(where: { $0.token == listener.token }) { listener.callback(event) }
        }
    }
    func prepare(_ edits: [TextEdit], expectedVersion: Int?) throws -> PreparedEdit {
        try ensureMutable(); try checkVersion(expectedVersion)
        let old = snapshot
        let changes = try edits.map { edit -> ContentChange in
            let r = try old.offsets(in: edit.range)
            return ContentChange(offset: r.lowerBound, removedText: old.string(in: r), insertedText: normalized(edit.text, eol: endOfLine))
        }.sorted { $0.offset < $1.offset }
        for (a,b) in zip(changes, changes.dropFirst()) {
            if a.offset + a.removedLength > b.offset || a.offset == b.offset { throw EditorError.overlappingEdits }
        }
        // Merge touching edits before dropping no-ops, so a deletion and a reinsertion of the
        // same text next to it cancel out.
        var merged: [ContentChange] = []
        for c in changes {
            if let last = merged.last, last.offset + last.removedLength == c.offset {
                merged[merged.count - 1] = ContentChange(offset: last.offset,
                    removedText: last.removedText + c.removedText, insertedText: last.insertedText + c.insertedText)
            } else { merged.append(c) }
        }
        let effective = merged.filter { !$0.removedText.utf16.elementsEqual($0.insertedText.utf16) }
        var newRoot = root
        for c in effective.reversed() {
            let (prefix, tail) = newRoot?.split(c.offset) ?? (nil,nil)
            let (_, suffix) = tail?.split(c.removedLength) ?? (nil,nil)
            newRoot = RopeNode.join(RopeNode.join(prefix, RopeNode.build(Array(c.insertedText.utf16))), suffix)
        }
        return PreparedEdit(root: newRoot, changes: effective)
    }
    func safePosition(_ raw: Int, affinity: Affinity) -> Position {
        var offset = min(max(0,raw), snapshot.utf16Count)
        if (try? snapshot.validate(offset: offset)) == nil { offset += affinity == .before ? -1 : 1 }
        return try! snapshot.position(at: offset)
    }
    func install(_ prepared: PreparedEdit) {
        let old = snapshot
        root = prepared.root; version += 1
        let map = ChangeMap(prepared.changes)
        for editor in liveEditors { editor.track(from: old, map: map) }
        trackSemantics(from: old, map: map)
        retokenizeLines(after: prepared.changes, in: old)
        invalidation?()
    }
    func record(before: RopeNode?, selections: [UUID: SelectionState], batches: [[ContentChange]], group: String?) {
        // Selections that changed since the previous edit, such as a caret moved elsewhere,
        // start a new undo step even within a group, unless the group is held open.
        if let group, let last = undoEntries.last, last.group == group,
           last.afterSelections == selections || group == heldGroup {
            undoEntries[undoEntries.count - 1].after = root
            undoEntries[undoEntries.count - 1].batches += batches
            undoEntries[undoEntries.count - 1].afterSelections = selectionStates
        } else {
            undoEntries.append(HistoryEntry(before: before, after: root, batches: batches, beforeSelections: selections,
                afterSelections: selectionStates, group: group))
        }
        redoEntries = []
    }
    @discardableResult public func apply(_ edits: [TextEdit], expectedVersion: Int? = nil, historyGroup: String? = nil) throws -> Int {
        try perform(edits, expectedVersion: expectedVersion, group: historyGroup, owner: nil, selectionsAfter: nil, provisional: false)
    }
    @discardableResult func perform(_ edits: [TextEdit], expectedVersion: Int?, group: String?, owner: UUID?,
                                   selectionsAfter: (([ContentChange]) -> [Selection])?, provisional: Bool) throws -> Int {
        // A write from a notification is reentrant before it is anything else.
        try ensureMutable()
        if let compositionOwner, compositionOwner != owner { throw EditorError.compositionActive }
        let prepared = try prepare(edits, expectedVersion: expectedVersion)
        if prepared.changes.isEmpty {
            if let owner, let selectionsAfter, let editor = editors[owner]?.value {
                try editor.adopt(selectionsAfter([])); editor.preferredAdvances = []; emit(.selection)
            }
            return version
        }
        let before = root, selections = selectionStates
        // Tracking merges the owner's selections and moves its primary index, while
        // selectionsAfter derives one selection from each selection before the edit.
        let ownerPrimary = owner.flatMap { editors[$0]?.value?.primaryIndex }
        install(prepared)
        if let owner, let selectionsAfter, let editor = editors[owner]?.value, let ownerPrimary {
            editor.selectionState = try editor.canonical(selectionsAfter(prepared.changes), primary: ownerPrimary)
        }
        if !provisional { record(before: before, selections: selections, batches: [prepared.changes], group: group) }
        emit(provisional ? .composition : .edit, batches: [prepared.changes])
        return version
    }
    /// Starts a new undo step for `group` and keeps it open across selection changes until
    /// `endHistoryGroup()`, for one operation that edits and selects in several steps.
    public func beginHistoryGroup(_ group: String) throws {
        try markHistoryBoundary()
        heldGroup = group
    }
    /// Sets a boundary after the last undo step. While a group is held, it releases the group
    /// and closes only that group's step, so a step of another group can still continue.
    public func endHistoryGroup() throws {
        try ensureMutable()
        if let last = undoEntries.indices.last, heldGroup == nil || undoEntries[last].group == heldGroup {
            undoEntries[last].group = nil
        }
        heldGroup = nil
    }
    /// Starts a new undo step for the next edit without releasing a held group.
    func markHistoryBoundary() throws {
        try ensureMutable()
        if !undoEntries.isEmpty { undoEntries[undoEntries.count - 1].group = nil }
    }
    public func undo() throws { try travel(undo: true) }
    public func redo() throws { try travel(undo: false) }
    func travel(undo: Bool) throws {
        try ensureMutable(); if compositionOwner != nil { throw EditorError.compositionActive }
        guard let entry = undo ? undoEntries.popLast() : redoEntries.popLast() else { return }
        let batches = undo ? entry.batches.reversed().map(inverse) : entry.batches
        for changes in batches {
            let edits = try changes.map { c in TextEdit(TextRange(try snapshot.position(at: c.offset), try snapshot.position(at: c.offset + c.removedLength)), c.insertedText) }
            install(try prepare(edits, expectedVersion: nil))
        }
        root = undo ? entry.before : entry.after
        let states = undo ? entry.beforeSelections : entry.afterSelections
        for editor in liveEditors { if let state = states[editor.id] { editor.selectionState = state } }
        if undo { redoEntries.append(entry) } else { undoEntries.append(entry) }
        // Edits after history travel start a new undo step.
        if !undoEntries.isEmpty { undoEntries[undoEntries.count - 1].group = nil }
        emit(undo ? .undo : .redo, batches: batches)
    }
    public func replaceAll(_ query: String, with replacement: String, options: SearchOptions = .init(), in range: TextRange? = nil) throws {
        // Reject writes before spending time on the search.
        try ensureMutable(); if compositionOwner != nil { throw EditorError.compositionActive }
        var template = replacement
        if options.regularExpression {
            // Preserve the $$ literal-dollar extension without consuming escaped tokens.
            let tokens = try NSRegularExpression(pattern: #"\\[\s\S]|\$\$"#)
            let source = replacement as NSString
            for token in tokens.matches(in: replacement, range: NSRange(location: 0, length: source.length)).reversed()
                where source.substring(with: token.range) == "$$" {
                template = (template as NSString).replacingCharacters(in: token.range, with: #"\$"#)
            }
        }
        let edits = try snapshot.search(query, options: options, in: range) { match, regex, result, source in
            let text = options.regularExpression
                ? regex.replacementString(for: result, in: source, offset: 0, template: template)
                : replacement
            return TextEdit(match.range, text)
        }
        try apply(edits)
    }
    /// Restore provisional input even if its originating session has been released.
    public func cancelActiveComposition() throws {
        try ensureMutable(); guard let state = activeComposition else { throw EditorError.noComposition }
        let batches = state.batches.reversed().map(inverse)
        for changes in batches {
            let edits = try changes.map { c in TextEdit(TextRange(try snapshot.position(at: c.offset), try snapshot.position(at: c.offset + c.removedLength)), c.insertedText) }
            install(try prepare(edits, expectedVersion: nil))
        }
        root = state.beforeRoot
        // Other sessions keep their own changes and follow the inverse edits.
        for editor in liveEditors where editor.id == compositionOwner {
            if let old = state.beforeSelections[editor.id] { editor.selectionState = old }
            editor.composition = nil
        }
        compositionOwner = nil; activeComposition = nil
        emit(.composition, batches: batches)
    }
    public func dispose() throws {
        try ensureMutable()
        Callbacks.beginOperation(); defer { Callbacks.endOperation() }
        // Cancel provisional input while all attached editors can still observe restoration.
        if activeComposition != nil { try cancelActiveComposition() }
        isDisposed = true; invalidation?()
        let detached = !liveEditors.isEmpty
        for editor in liveEditors { editor.disposeFromDocument() }
        if detached { pendingChanges.insert(.selection) }
        editors = [:]; undoEntries = []; redoEntries = []
        tokens = []; semanticTokens = []; diagnostics = []; decorations = []; trackedRanges = [:]; foldingRanges = []; inlayHints = []
        if lineTokenizer != nil { retokenizedLines = IndexSet(integersIn: 0..<lineEntries.count); pendingChanges.insert(.lineTokens) }
        lineTokenizer = nil; lineEntries = []
        emit(.disposed); listeners = []; invalidation = nil; semanticProviders = [:]; semanticVersions = [:]
    }
}
