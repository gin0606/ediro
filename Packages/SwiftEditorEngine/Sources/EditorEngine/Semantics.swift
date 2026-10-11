import Foundation

public enum Affinity: Sendable { case before, after }
public enum RangeStickiness: Sendable {
    case growBoth, growNeither, growBefore, growAfter
    var startAffinity: Affinity { self == .growBoth || self == .growBefore ? .before : .after }
    var endAffinity: Affinity { self == .growNeither || self == .growBefore ? .before : .after }
}
public struct TrackedRange: Sendable, Equatable {
    public let id: UUID
    public var range: TextRange
    public var stickiness: RangeStickiness
    public init(id: UUID = UUID(), range: TextRange, stickiness: RangeStickiness = .growNeither) {
        self.id = id; self.range = range; self.stickiness = stickiness
    }
}
public struct HighlightToken: Sendable, Equatable {
    public var range: TextRange
    public var kind: String
    public var modifiers: [String]
    public init(range: TextRange, kind: String, modifiers: [String] = []) {
        self.range = range; self.kind = kind; self.modifiers = modifiers
    }
}
public enum Severity: String, Sendable { case error, warning, information, hint }
public struct Diagnostic: Sendable, Equatable {
    public var range: TextRange
    public var severity: Severity
    public var message: String
    public var code: String?
    public init(range: TextRange, severity: Severity, message: String, code: String? = nil) {
        self.range = range; self.severity = severity; self.message = message; self.code = code
    }
}
public struct Decoration: Sendable, Equatable {
    public var tracked: TrackedRange
    public var style: String
    public init(tracked: TrackedRange, style: String) { self.tracked = tracked; self.style = style }
}
public struct FoldingRange: Sendable, Equatable {
    public var tracked: TrackedRange
    public var kind: String?
    public init(id: UUID = UUID(), range: TextRange, kind: String? = nil) {
        // Text typed at either edge belongs to the neighbouring line, such as the next heading.
        tracked = TrackedRange(id: id, range: range, stickiness: .growNeither); self.kind = kind
    }
    public var id: UUID { tracked.id }
    public var range: TextRange { tracked.range }
}
extension FoldingRange {
    /// The last line the fold covers. A fold ending at a line start covers none of that line.
    var lastLine: Int { range.end.column == 0 ? range.end.line - 1 : range.end.line }
}
/// Orders folds by first line, outermost first.
func orderedFolds(_ values: [FoldingRange]) -> [FoldingRange] {
    values.sorted { a, b in
        if a.range.start.line != b.range.start.line { return a.range.start.line < b.range.start.line }
        if a.lastLine != b.lastLine { return a.lastLine > b.lastLine }
        return a.range.start == b.range.start ? a.range.end > b.range.end : a.range.start < b.range.start
    }
}
/// Keeps the ordered folds that cover several lines and nest by line: a fold sharing a
/// line with a fold it is not inside would hide that fold's first line when collapsed.
func nestedFolds(_ ordered: [FoldingRange]) -> [FoldingRange] {
    var stack: [FoldingRange] = []
    return ordered.filter { fold in
        guard fold.range.start.line < fold.lastLine else { return false }
        while let last = stack.last, fold.range.start.line > last.lastLine { stack.removeLast() }
        if let last = stack.last, fold.lastLine > last.lastLine { return false }
        stack.append(fold)
        return true
    }
}
public struct InlayHint: Sendable, Equatable {
    public var position: Position
    public var label: String
    public var edits: [TextEdit]
    public init(position: Position, label: String, edits: [TextEdit] = []) {
        self.position = position; self.label = label; self.edits = edits
    }
}
/// Which document version a kind of semantic data was computed for.
public enum SemanticFreshness: Sendable, Equatable {
    /// There is no data of this kind for the document.
    case unavailable
    /// Computed for the view's version.
    case current
    /// Computed for an earlier version; ranges have been tracked through later edits.
    case stale(version: Int)
}
public struct SemanticView: Sendable {
    public let documentID: String
    public let version: Int
    public let tokens: [HighlightToken]
    public let tokensFreshness: SemanticFreshness
    public let semanticTokens: [HighlightToken]
    public let semanticTokensFreshness: SemanticFreshness
    public let diagnostics: [Diagnostic]
    public let diagnosticsFreshness: SemanticFreshness
    public let decorations: [Decoration]
    public let trackedRanges: [TrackedRange]
    public let foldingRanges: [FoldingRange]
    public let foldingRangesFreshness: SemanticFreshness
    public let inlayHints: [InlayHint]
    public let inlayHintsFreshness: SemanticFreshness
}

extension Document {
    public func semantics(in range: TextRange? = nil) throws -> SemanticView {
        try ensureAlive()
        let range = range ?? snapshot.fullRange
        _ = try snapshot.offsets(in: range)
        func intersects(_ other: TextRange) -> Bool { other.end >= range.start && other.start <= range.end }
        func freshness(_ feature: LanguageFeature) -> SemanticFreshness {
            guard let source = semanticVersions[feature] else { return .unavailable }
            return source == version ? .current : .stale(version: source)
        }
        return SemanticView(documentID: id, version: version,
            tokens: tokens.filter { intersects($0.range) }, tokensFreshness: freshness(.tokens),
            semanticTokens: semanticTokens.filter { intersects($0.range) }, semanticTokensFreshness: freshness(.semanticTokens),
            diagnostics: diagnostics.filter { intersects($0.range) }, diagnosticsFreshness: freshness(.diagnostics),
            decorations: decorations.filter { intersects($0.tracked.range) },
            trackedRanges: trackedRanges.values.filter { intersects($0.range) }.sorted { $0.id.uuidString < $1.id.uuidString },
            foldingRanges: foldingRanges.filter { intersects($0.range) }, foldingRangesFreshness: freshness(.folding),
            inlayHints: inlayHints.filter { $0.position >= range.start && $0.position <= range.end },
            inlayHintsFreshness: freshness(.inlayHints))
    }
    @discardableResult public func trackRange(_ range: TextRange, stickiness: RangeStickiness = .growNeither) throws -> UUID {
        try ensureMutable(); _ = try snapshot.offsets(in: range)
        let tracked = TrackedRange(range: range, stickiness: stickiness)
        trackedRanges[tracked.id] = tracked; emit(.semantics); return tracked.id
    }
    public func trackedRange(id: UUID) throws -> TrackedRange? { try ensureAlive(); return trackedRanges[id] }
    public func removeTrackedRange(id: UUID) throws {
        try ensureMutable(); if trackedRanges.removeValue(forKey: id) != nil { emit(.semantics) }
    }
    public func setTokens(_ values: [HighlightToken], semantic: Bool = false, version: Int) throws {
        try ensureMutable(); try checkVersion(version)
        for value in values { _ = try snapshot.offsets(in: value.range) }
        if semantic { semanticTokens = values } else { tokens = values }
        semanticVersions[semantic ? .semanticTokens : .tokens] = version
        semanticProviders.removeValue(forKey: semantic ? .semanticTokens : .tokens)
        emit(.semantics)
    }
    public func setDiagnostics(_ values: [Diagnostic], version: Int) throws {
        try ensureMutable(); try checkVersion(version)
        for value in values { _ = try snapshot.offsets(in: value.range) }
        diagnostics = values; semanticVersions[.diagnostics] = version
        semanticProviders.removeValue(forKey: .diagnostics); emit(.semantics)
    }
    public func setDecorations(_ values: [Decoration]) throws {
        try ensureMutable()
        guard Set(values.map { $0.tracked.id }).count == values.count else { throw EditorError.invalidRange }
        for value in values { _ = try snapshot.offsets(in: value.tracked.range) }
        decorations = values; emit(.semantics)
    }
    public func setFoldingRanges(_ values: [FoldingRange], version: Int) throws {
        try ensureMutable(); try checkVersion(version)
        guard Set(values.map(\.id)).count == values.count else { throw EditorError.invalidFoldingRanges }
        for fold in values { _ = try snapshot.offsets(in: fold.range) }
        let sorted = orderedFolds(values)
        guard nestedFolds(sorted).count == sorted.count else { throw EditorError.invalidFoldingRanges }
        carryCollapseState(to: sorted)
        foldingRanges = sorted; semanticVersions[.folding] = version
        semanticProviders.removeValue(forKey: .folding)
        emit(.semantics)
    }
    /// Providers usually rebuild folds with fresh IDs, so a collapsed fold passes its state to
    /// the replacement with its ID, else the one covering the same lines, else the outermost
    /// one starting on the same line. Collapsed folds without a replacement open.
    func carryCollapseState(to folds: [FoldingRange]) {
        let current = Dictionary(uniqueKeysWithValues: foldingRanges.map { ($0.id, $0) })
        for editor in liveEditors {
            var collapsed: Set<UUID> = []
            for id in editor.collapsedFolds {
                guard let previous = current[id] else { continue }
                let sameStart = folds.filter { $0.range.start.line == previous.range.start.line }
                guard let fold = folds.first(where: { $0.id == id })
                    ?? sameStart.first(where: { $0.lastLine == previous.lastLine }) ?? sameStart.first else { continue }
                collapsed.insert(fold.id)
            }
            editor.collapsedFolds = collapsed
        }
    }
    public func setInlayHints(_ values: [InlayHint], version: Int) throws {
        try ensureMutable(); try checkVersion(version)
        for hint in values {
            _ = try snapshot.offset(at: hint.position)
            _ = try prepare(hint.edits, expectedVersion: version)
        }
        inlayHints = values; semanticVersions[.inlayHints] = version
        semanticProviders.removeValue(forKey: .inlayHints); emit(.semantics)
    }
    /// No session's caret is ever hidden: before each notification, a collapsed fold that
    /// hides a caret of its session opens, whatever moved the caret or the fold.
    func revealCarets() {
        guard !foldingRanges.isEmpty else { return }
        for editor in liveEditors where !editor.collapsedFolds.isEmpty {
            let hiding = foldingRanges.filter { fold in
                editor.collapsedFolds.contains(fold.id)
                    && editor.selections.contains { $0.head.line > fold.range.start.line && $0.head.line <= fold.lastLine }
            }
            editor.collapsedFolds.subtract(hiding.map(\.id))
        }
    }
    func trackSemantics(from old: TextSnapshot, map: ChangeMap) {
        let changes = map.changes
        guard let first = changes.first, let last = changes.last else { return }
        isTrackingSemantics = true; defer { isTrackingSemantics = false }
        // Data computed for the previous version becomes stale.
        var changed = semanticVersions.values.contains(old.version) || !inlayHints.isEmpty
        defer { semanticsChanged(changed) }
        // Positions strictly outside the changed span keep their surrounding units, so they
        // move by line and column arithmetic alone, without looking anything up in the text.
        let firstStart = try! old.position(at: first.offset)
        let lastEnd = try! old.position(at: last.offset + last.removedLength)
        let delta = changes.reduce(0) { $0 + $1.insertedLength - $1.removedLength }
        let newLastEnd = try! snapshot.position(at: last.offset + last.removedLength + delta)
        func outside(_ p: Position) -> Position? {
            if p < firstStart { return p }
            guard lastEnd < p else { return nil }
            return p.line == lastEnd.line
                ? Position(newLastEnd.line, newLastEnd.column + p.column - lastEnd.column)
                : Position(p.line + newLastEnd.line - lastEnd.line, p.column)
        }
        func mapped(_ range: TextRange, _ stickiness: RangeStickiness) -> TextRange {
            let result: TextRange
            if let start = outside(range.start), let end = outside(range.end) { result = TextRange(start, end) } else {
                let a = map.map(try! old.offset(at: range.start), affinity: stickiness.startAffinity)
                let b = map.map(try! old.offset(at: range.end), affinity: stickiness.endAffinity)
                result = TextRange(safePosition(a, affinity: stickiness.startAffinity), safePosition(max(a,b), affinity: stickiness.endAffinity))
            }
            if result != range { changed = true }
            return result
        }
        diagnostics = diagnostics.map { var d = $0; d.range = mapped(d.range, .growNeither); return d }
        // Keep highlighting visible until a new result arrives; collapsed tokens style nothing.
        func trackTokens(_ values: [HighlightToken]) -> [HighlightToken] {
            values.compactMap { var t = $0; t.range = mapped(t.range, .growNeither); return t.range.isEmpty ? nil : t }
        }
        let tokenCounts = (tokens.count, semanticTokens.count)
        tokens = trackTokens(tokens); semanticTokens = trackTokens(semanticTokens)
        if (tokens.count, semanticTokens.count) != tokenCounts { changed = true }
        decorations = decorations.map { var d = $0; d.tracked.range = mapped(d.tracked.range, d.tracked.stickiness); return d }
        trackedRanges = trackedRanges.mapValues { value in
            var tracked = value; tracked.range = mapped(value.range, value.stickiness); return tracked
        }
        let mappedFolds = foldingRanges.map { var f = $0; f.tracked.range = mapped(f.range, f.tracked.stickiness); return f }
        let foldCount = foldingRanges.count
        foldingRanges = nestedFolds(orderedFolds(mappedFolds))
        if foldingRanges.count != foldCount { changed = true }
        for editor in liveEditors { editor.collapsedFolds.formIntersection(Set(foldingRanges.map(\.id))) }
        // Hint edits are bound to the version they were computed for, so hints cannot be tracked.
        inlayHints = []; semanticVersions.removeValue(forKey: .inlayHints)
    }
}
