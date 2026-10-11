import Foundation

public enum Movement: Sendable { case backward, forward, lineStart, lineEnd, documentStart, documentEnd, up, down }
public enum VerticalDirection: Sendable { case up, down }
public struct DisplayPosition: Sendable {
    public var row: Int
    /// The application defines this unit (for example, a measured horizontal advance).
    public var advance: Double
    public init(row: Int, advance: Double) { self.row = row; self.advance = advance }
}
public struct LayoutMovement: Sendable {
    public var position: Position
    public var preferredAdvance: Double
    public init(position: Position, preferredAdvance: Double) { self.position = position; self.preferredAdvance = preferredAdvance }
}
@MainActor public protocol LayoutAdapter {
    func moveVertically(from position: Position, direction: VerticalDirection, preferredAdvance: Double?, snapshot: TextSnapshot) throws -> LayoutMovement
    func position(at display: DisplayPosition, snapshot: TextSnapshot) throws -> Position
    func displayPosition(at position: Position, snapshot: TextSnapshot) throws -> DisplayPosition
}
/// A session's selections and which of them is primary.
struct SelectionState: Equatable {
    var selections: [Selection]
    var primary: Int
}
struct CompositionState: Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.beforeRoot === b.beforeRoot && a.beforeSelections == b.beforeSelections && a.replacedTexts == b.replacedTexts
            && a.ranges == b.ranges && a.batches == b.batches
    }
    let beforeRoot: RopeNode?
    /// Taken just before the first provisional change, as edits take theirs just before they apply.
    var beforeSelections: [UUID: SelectionState]
    /// The text each marked range covered when the composition began, so restoring it adds no history.
    var replacedTexts: [String]
    /// One marked range per selection, in selection order.
    var ranges: [TextRange]
    var batches: [[ContentChange]]
}
/// Where each of the sorted, disjoint ranges starts once every range is replaced by text of
/// the given length. Unlike mapping through the coalesced changes, touching ranges stay apart.
func replacedStarts(_ ranges: [Range<Int>], lengths: [Int]) -> [Int] {
    var delta = 0
    return zip(ranges, lengths).map { range, length in
        defer { delta += length - range.count }
        return range.lowerBound + delta
    }
}

@MainActor public final class EditorSession {
    public let id = UUID()
    public let document: Document
    public internal(set) var selections: [Selection] = [Selection(Position(0,0))] {
        didSet { if selections != oldValue { document.pendingChanges.insert(.selection) } }
    }
    /// The index in `selections` of the primary selection, which input methods and scrolling follow.
    /// It moves with its selection through sorting and merging.
    public internal(set) var primaryIndex = 0 {
        didSet { if primaryIndex != oldValue { document.pendingChanges.insert(.selection) } }
    }
    public var primarySelection: Selection { selections[primaryIndex] }
    public private(set) var isDisposed = false
    public internal(set) var collapsedFolds: Set<UUID> = [] { didSet { document.semanticsChanged(collapsedFolds != oldValue) } }
    public private(set) var layout: (any LayoutAdapter)?
    var preferredAdvances: [Double?] = []
    var composition: CompositionState? {
        didSet { if composition != oldValue { document.pendingChanges.insert(.composition) } }
    }
    /// The provisional text of every selection, in selection order.
    public var markedRanges: [TextRange] { composition?.ranges ?? [] }
    /// The primary selection's provisional text.
    public var markedRange: TextRange? { composition.map { $0.ranges[primaryIndex] } }

    public init(document: Document) throws {
        try document.ensureMutable(); self.document = document; document.editors[id] = WeakEditor(self)
    }
    func ensureAlive() throws {
        if isDisposed { throw EditorError.disposed }
        try document.ensureAlive()
    }
    func ensureMutable() throws {
        try ensureAlive()
        try document.ensureMutable()
    }
    /// Sorts and merges selections, following the primary one to the selection it ends up in.
    /// Overlapping selections and carets touching a selection merge; touching non-empty
    /// selections stay apart, so adjacent occurrences can be selected separately.
    func canonical(_ values: [Selection], primary: Int) throws -> SelectionState {
        guard values.indices.contains(primary) else { throw EditorError.invalidRange }
        for s in values { _ = try document.snapshot.offsets(in: s.range) }
        let order = values.indices.sorted { i, j in
            let a = values[i].range, b = values[j].range
            return a.start != b.start ? a.start < b.start : a.end != b.end ? a.end < b.end : i < j
        }
        var result: [Selection] = [], resultPrimary = 0
        for i in order {
            let s = values[i]
            if let last = result.last, s.range.start < last.range.end || s.range.start == last.range.end && (s.isEmpty || last.isEmpty) {
                let r = TextRange(last.range.start, max(last.range.end, s.range.end))
                result[result.count - 1] = last.anchor <= last.head ? Selection(anchor: r.start, head: r.end) : Selection(anchor: r.end, head: r.start)
            } else { result.append(s) }
            if i == primary { resultPrimary = result.count - 1 }
        }
        return SelectionState(selections: result, primary: resultPrimary)
    }
    var selectionState: SelectionState {
        get { SelectionState(selections: selections, primary: primaryIndex) }
        set { selections = newValue.selections; primaryIndex = newValue.primary }
    }
    /// Installs selections derived one-to-one from the current ones, keeping the primary.
    func adopt(_ values: [Selection]) throws { selectionState = try canonical(values, primary: primaryIndex) }
    public func setSelections(_ values: [Selection], primary: Int = 0) throws {
        try ensureMutable(); if composition != nil { throw EditorError.compositionActive }
        selectionState = try canonical(values, primary: primary); preferredAdvances = []; document.emit(.selection)
    }
    public func setLayout(_ adapter: (any LayoutAdapter)?) throws { try ensureMutable(); layout = adapter; preferredAdvances = [] }
    /// Layout callbacks run with the document locked, and the lock is held until the result is
    /// installed and announced. Operations an adapter defers, such as unregistering a provider,
    /// run only afterwards, so their notifications cannot edit the document mid-operation.
    func withLayout<T>(_ body: (any LayoutAdapter) throws -> T) throws -> T {
        guard let layout else { throw EditorError.invalidPosition }
        return try document.whileLocked { try body(layout) }
    }
    func track(from old: TextSnapshot, map: ChangeMap) {
        let values = selections.map { s in
            Selection(anchor: document.safePosition(map.map(try! old.offset(at: s.anchor), affinity: .after), affinity: .after),
                head: document.safePosition(map.map(try! old.offset(at: s.head), affinity: .after), affinity: .after))
        }
        try! adopt(values); preferredAdvances = []
    }
    public func type(_ text: String, historyGroup: String? = nil) throws {
        try type(Array(repeating: text, count: selections.count), historyGroup: historyGroup)
    }
    /// Replaces `selections[i]` with `texts[i]`, for input that differs per selection, such as
    /// a newline followed by each line's indentation or one line of a pasted block per caret.
    /// Each caret ends after its own text.
    public func type(_ texts: [String], historyGroup: String? = nil) throws {
        try ensureMutable(); if document.compositionOwner != nil { throw EditorError.compositionActive }
        guard texts.count == selections.count else { throw EditorError.invalidRange }
        let snapshot = document.snapshot
        let ranges = try selections.map { try snapshot.offsets(in: $0.range) }
        let lengths = texts.map { normalized($0, eol: document.endOfLine).utf16.count }
        let ends = zip(replacedStarts(ranges, lengths: lengths), lengths).map { $0 + $1 }
        let edits = zip(selections, texts).map { TextEdit($0.range, $1) }
        try document.perform(edits, expectedVersion: nil, group: historyGroup, owner: id, selectionsAfter: { [document] _ in
            ends.map { Selection(document.safePosition($0, affinity: .after)) }
        }, provisional: false)
    }
    /// Applies `edits` as one change and replaces `selections[i]` with `selecting[i]`, given as
    /// UTF-16 offsets in the edited text, for commands that place each caret themselves, such
    /// as swapping the characters around it. Undo restores the selections from before the
    /// change and redo restores these. Inserted text is normalized to the document's line
    /// ending, so compute the offsets for the normalized text. As with `type(_:)`, edits that
    /// change nothing only move the selections and add no undo step, and an offset outside the
    /// text or inside a surrogate pair moves to the nearest valid position.
    public func replace(_ edits: [TextEdit], selecting: [(anchor: Int, head: Int)], historyGroup: String? = nil) throws {
        try ensureMutable(); if document.compositionOwner != nil { throw EditorError.compositionActive }
        guard selecting.count == selections.count else { throw EditorError.invalidRange }
        try document.perform(edits, expectedVersion: nil, group: historyGroup, owner: id, selectionsAfter: { [document] _ in
            selecting.map { Selection(anchor: document.safePosition($0.anchor, affinity: .after),
                head: document.safePosition($0.head, affinity: .after)) }
        }, provisional: false)
    }
    func graphemeOffset(_ offset: Int, forward: Bool) throws -> Int {
        let snapshot = document.snapshot
        let position = try snapshot.position(at: offset)
        let start = try snapshot.lineStart(position.line), end = try snapshot.lineEnd(position.line)
        if forward && offset == end {
            return position.line + 1 < snapshot.lineCount ? try snapshot.lineStart(position.line + 1) : offset
        }
        if !forward && offset == start {
            return position.line > 0 ? try snapshot.lineEnd(position.line - 1) : offset
        }
        let text = try snapshot.line(position.line)
        var boundaries = [start], cursor = start
        for character in text { cursor += String(character).utf16.count; boundaries.append(cursor) }
        return forward ? boundaries.first(where: { $0 > offset }) ?? end : boundaries.last(where: { $0 < offset }) ?? start
    }
    public func deleteBackward(historyGroup: String? = nil) throws { try delete(forward: false, group: historyGroup) }
    public func deleteForward(historyGroup: String? = nil) throws { try delete(forward: true, group: historyGroup) }
    func delete(forward: Bool, group: String?) throws {
        try ensureMutable(); if document.compositionOwner != nil { throw EditorError.compositionActive }
        let snapshot = document.snapshot
        let ranges = try selections.map { s -> Selection in
            if !s.isEmpty { return s }
            let offset = try snapshot.offset(at: s.head), next = try graphemeOffset(offset, forward: forward)
            var boundary = try snapshot.lineStart(s.head.line)
            for character in try snapshot.line(s.head.line) {
                let end = boundary + String(character).utf16.count
                if boundary < offset && offset < end {
                    return Selection(anchor: try snapshot.position(at: boundary), head: try snapshot.position(at: end))
                }
                boundary = end
                if boundary >= offset { break }
            }
            return Selection(anchor: try snapshot.position(at: min(offset,next)), head: try snapshot.position(at: max(offset,next)))
        }
        let edits = try canonical(ranges, primary: 0).selections.filter { !$0.isEmpty }.map { TextEdit($0.range, "") }
        try document.perform(edits, expectedVersion: nil, group: group, owner: id, selectionsAfter: nil, provisional: false)
    }
    public func move(_ movement: Movement, extendingSelection: Bool = false) throws {
        try ensureMutable(); if composition != nil { throw EditorError.compositionActive }
        if movement == .up || movement == .down {
            try withLayout { layout in try move(movement, extendingSelection: extendingSelection, layout: layout) }
        } else {
            try move(movement, extendingSelection: extendingSelection, layout: nil)
        }
    }
    private func move(_ movement: Movement, extendingSelection: Bool, layout: (any LayoutAdapter)?) throws {
        let snapshot = document.snapshot
        var goals: [Double?] = [], moved: [Selection] = []
        for (i,s) in selections.enumerated() {
            let p: Position
            var goal: Double?
            if !extendingSelection && !s.isEmpty && (movement == .backward || movement == .forward) {
                p = movement == .backward ? s.range.start : s.range.end
            } else {
                switch movement {
                case .backward, .forward:
                    p = try snapshot.position(at: graphemeOffset(snapshot.offset(at: s.head), forward: movement == .forward))
                case .lineStart: p = Position(s.head.line,0)
                case .lineEnd: p = try snapshot.position(at: snapshot.lineEnd(s.head.line))
                case .documentStart: p = Position(0,0)
                case .documentEnd: p = snapshot.fullRange.end
                case .up, .down:
                    guard let layout else { throw EditorError.invalidPosition }
                    // Without extending, a selection moves from its edge in the direction of travel.
                    let origin = extendingSelection || s.isEmpty ? s.head : movement == .up ? s.range.start : s.range.end
                    let result = try layout.moveVertically(from: origin, direction: movement == .up ? .up : .down,
                        preferredAdvance: i < preferredAdvances.count ? preferredAdvances[i] : nil, snapshot: snapshot)
                    p = result.position; goal = result.preferredAdvance
                }
            }
            _ = try snapshot.offset(at: p)
            moved.append(Selection(anchor: extendingSelection ? s.anchor : p, head: p)); goals.append(goal)
        }
        try adopt(moved)
        preferredAdvances = selections == moved ? goals : []
        document.emit(.selection)
    }
    /// Moves each selection's head to the position `target` returns for it, for movements the
    /// application's layout defines, such as by word or to a visual line boundary. `target`
    /// runs with the document locked, as layout callbacks do.
    public func move(extendingSelection: Bool = false, to target: (Selection) throws -> Position) throws {
        try ensureMutable(); if composition != nil { throw EditorError.compositionActive }
        let snapshot = document.snapshot
        let moved = try document.whileLocked {
            try selections.map { s in
                let p = try target(s); _ = try snapshot.offset(at: p)
                return Selection(anchor: extendingSelection ? s.anchor : p, head: p)
            }
        }
        try adopt(moved); preferredAdvances = []
        document.emit(.selection)
    }
    /// Deletes from each caret to the position `target` returns for it, such as the start of the
    /// previous word; non-empty selections are deleted as they are. `target` runs with the
    /// document locked.
    public func delete(to target: (Position) throws -> Position, historyGroup: String? = nil) throws {
        try ensureMutable(); if document.compositionOwner != nil { throw EditorError.compositionActive }
        let snapshot = document.snapshot
        let ranges = try document.whileLocked {
            try selections.map { s -> Selection in
                guard s.isEmpty else { return s }
                let p = try target(s.head); _ = try snapshot.offset(at: p)
                return Selection(anchor: s.head, head: p)
            }
        }
        let edits = try canonical(ranges, primary: 0).selections.filter { !$0.isEmpty }.map { TextEdit($0.range, "") }
        try document.perform(edits, expectedVersion: nil, group: historyGroup, owner: id, selectionsAfter: nil, provisional: false)
    }
    public func select(at display: DisplayPosition, extendingSelection: Bool = false) throws {
        try ensureMutable(); if composition != nil { throw EditorError.compositionActive }
        try withLayout { layout in
            let p = try layout.position(at: display, snapshot: document.snapshot)
            selectionState = try canonical([Selection(anchor: extendingSelection ? primarySelection.anchor : p, head: p)], primary: 0)
            preferredAdvances = []; document.emit(.selection)
        }
    }
    public func setCollapsed(_ collapsed: Bool, foldID: UUID) throws {
        try ensureMutable()
        guard let fold = document.foldingRanges.first(where: { $0.id == foldID }) else { throw EditorError.invalidRange }
        if collapsed {
            // Carets inside move to the end of the fold's first line, which stays visible.
            let hidden = (fold.range.start.line + 1)...fold.lastLine
            if selections.contains(where: { hidden.contains($0.head.line) }) {
                // Provisional input cannot move, and a fold may not hide it.
                guard composition == nil else { throw EditorError.compositionActive }
                let visible = try document.snapshot.position(at: document.snapshot.lineEnd(fold.range.start.line))
                try adopt(selections.map { hidden.contains($0.head.line) ? Selection(visible) : $0 })
                preferredAdvances = []
            }
            collapsedFolds.insert(foldID)
        } else { collapsedFolds.remove(foldID) }
        document.emit(.semantics)
    }
    public func hiddenLineRanges() throws -> [Range<Int>] {
        try ensureAlive()
        let ranges = document.foldingRanges.filter { collapsedFolds.contains($0.id) }.map { ($0.range.start.line + 1)..<($0.lastLine + 1) }.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<Int>] = []
        for r in ranges {
            if let last = result.last, r.lowerBound <= last.upperBound { result[result.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound) }
            else { result.append(r) }
        }
        return result
    }
    /// Every selection receives the same provisional text, as input methods drive the primary one.
    public func beginComposition() throws {
        try ensureMutable()
        guard document.compositionOwner == nil else { throw EditorError.compositionActive }
        let snapshot = document.snapshot
        composition = CompositionState(beforeRoot: document.root, beforeSelections: document.selectionStates,
            replacedTexts: try selections.map { try snapshot.text(in: $0.range) }, ranges: selections.map(\.range), batches: [])
        document.activeComposition = composition
        document.compositionOwner = id
        // A held step continues after a composition that records nothing.
        if document.heldGroup == nil || document.undoEntries.last?.group != document.heldGroup {
            try document.markHistoryBoundary()
        }
        document.emit(.composition)
    }
    /// Replaces every marked range with `text`. markedSelection uses UTF-16 offsets within the new
    /// provisional text. `replacingBefore` and `replacingAfter` widen each marked range by that
    /// many UTF-16 units first, for an input method that also replaces text beside its marked
    /// text; the application measures them against the primary marked range.
    public func updateComposition(_ text: String, markedSelection: Range<Int>? = nil,
                                  replacingBefore: Int = 0, replacingAfter: Int = 0) throws {
        try ensureMutable(); guard var state = composition else { throw EditorError.noComposition }
        let text = normalized(text, eol: document.endOfLine)
        let length = text.utf16.count, selected = markedSelection ?? length..<length
        let probe = Document(id: "composition", text: text, endOfLine: document.endOfLine).snapshot
        guard selected.lowerBound >= 0 && selected.upperBound <= length else { throw EditorError.invalidRange }
        try probe.validate(offset: selected.lowerBound); try probe.validate(offset: selected.upperBound)
        guard replacingBefore >= 0 && replacingAfter >= 0 else { throw EditorError.invalidRange }
        let snapshot = document.snapshot
        let marked = try state.ranges.map { try snapshot.offsets(in: $0) }
        let ranges = marked.map { ($0.lowerBound - replacingBefore)..<($0.upperBound + replacingAfter) }
        for r in ranges { try snapshot.validate(offset: r.lowerBound); try snapshot.validate(offset: r.upperBound) }
        for (a, b) in zip(ranges, ranges.dropFirst()) where a.upperBound > b.lowerBound { throw EditorError.overlappingEdits }
        let edits = try ranges.map { TextEdit(TextRange(try snapshot.position(at: $0.lowerBound), try snapshot.position(at: $0.upperBound)), text) }
        let prepared = try document.prepare(edits, expectedVersion: nil)
        // Other edits are blocked during a composition, so the widened text is still as it was
        // when the composition began.
        var replacedTexts = zip(zip(ranges, marked), state.replacedTexts).map { pair, replaced in
            let (range, marked) = pair
            return snapshot.string(in: range.lowerBound..<marked.lowerBound) + replaced + snapshot.string(in: marked.upperBound..<range.upperBound)
        }
        if !prepared.changes.isEmpty {
            if state.batches.isEmpty { state.beforeSelections = document.selectionStates }
            document.install(prepared); state.batches.append(prepared.changes)
        }
        var starts = replacedStarts(ranges, lengths: Array(repeating: length, count: ranges.count)), primary = primaryIndex
        // Emptied ranges that meet can no longer be told apart, so they become one.
        if length == 0 {
            var index = 1
            while index < starts.count {
                if starts[index] == starts[index - 1] {
                    replacedTexts[index - 1] += replacedTexts.remove(at: index); starts.remove(at: index)
                    if primary >= index { primary -= 1 }
                } else { index += 1 }
            }
        }
        state.ranges = starts.map { TextRange(document.safePosition($0, affinity: .before), document.safePosition($0 + length, affinity: .after)) }
        state.replacedTexts = replacedTexts
        composition = state
        document.activeComposition = state
        selectionState = SelectionState(selections: starts.map {
            Selection(anchor: document.safePosition($0 + selected.lowerBound, affinity: .before), head: document.safePosition($0 + selected.upperBound, affinity: .after))
        }, primary: primary)
        document.emit(.composition, batches: prepared.changes.isEmpty ? [] : [prepared.changes])
    }
    public func commitComposition(_ text: String? = nil) throws {
        try ensureMutable(); guard composition != nil else { throw EditorError.noComposition }
        Callbacks.beginOperation(); defer { Callbacks.endOperation() }
        if let text { try updateComposition(text) }
        guard let state = composition else { throw EditorError.noComposition }
        composition = nil; document.compositionOwner = nil; document.activeComposition = nil
        selections = state.ranges.map { Selection($0.end) }
        // A composition that restores the replaced text is a no-op and adds no history.
        let snapshot = document.snapshot
        let restored = try zip(state.ranges, state.replacedTexts).allSatisfy { try snapshot.text(in: $0).utf16.elementsEqual($1.utf16) }
        if !state.batches.isEmpty, !restored { document.record(before: state.beforeRoot, selections: state.beforeSelections, batches: state.batches, group: nil) }
        document.emit(.composition)
    }
    public func cancelComposition() throws {
        try ensureMutable(); guard composition != nil else { throw EditorError.noComposition }
        try document.cancelActiveComposition()
    }
    public func dispose() throws {
        try ensureMutable()
        Callbacks.beginOperation(); defer { Callbacks.endOperation() }
        if composition != nil { try cancelComposition() }
        document.editors.removeValue(forKey: id); disposeFromDocument()
        document.pendingChanges.insert(.selection); document.emit(.selection)
    }
    func disposeFromDocument() { isDisposed = true; composition = nil; layout = nil; collapsedFolds = [] }
}
