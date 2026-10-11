# SwiftEditorEngine

A UI-independent Swift editor engine inspired by a fixed revision of Monaco / VS Code.
The `EditorEngine` library uses Swift and Foundation only. It has no JavaScript,
Monaco, WebView, SwiftUI, AppKit or UIKit runtime dependency.

## Build and use

Requires Swift 6 or newer and macOS 13 or later. Tests run on macOS; other platforms
are not supported or verified.
The package has no third-party dependencies. macOS CLI verification is recorded in
[the documentation index](Documentation/README.md#verification-boundary).

From this directory:

```sh
swift build -j 2
swift test -j 2
swift run -j 2 editor-example
swift run -c release -j 2 editor-benchmark
```

Add the directory as a local Swift package in Xcode, or from another package:

```swift
.package(path: "../SwiftEditorEngine")
// In the target dependencies:
.product(name: "EditorEngine", package: "SwiftEditorEngine")
```

The runnable [example](Sources/EditorExample/main.swift) uses only public APIs. It
creates a document and session, requests and accepts completion, types text, receives
provider diagnostics, collapses a fold and executes undo/redo, then disposes resources.

```swift
import EditorEngine

@MainActor func editExample() throws {
    let workspace = EditorWorkspace()
    let document = try workspace.createDocument(id: "notes", text: "Hello 😀\n")
    let editor = try EditorSession(document: document)
    let observation = try document.observe { event in
        // Snapshot, selections and semantic ranges are consistent here.
        if event.changes.contains(.text) { print(event.version, document.snapshot.text) }
    }
    try editor.move(.lineEnd)
    try editor.type("!")
    try document.undo()
    observation.cancel()
    try workspace.dispose()
}
```

If imported platform frameworks also define `TextRange`, qualify it as
`EditorEngine.TextRange` (or use a local typealias).

## Responsibilities and supported features

The application owns rendering, font measurement, wrapping, input events, OS IME
connection, clipboard, windows, parsing, type analysis, language servers and transport.
The engine owns text, editing, history, sessions, tracked ranges and provider requests.
It neither measures glyphs nor assumes monospaced text.

| Area | Public API and behavior |
| --- | --- |
| Text | `Document`, immutable `TextSnapshot`, lines, ranges, normalized EOL, version, UTF-16 offsets |
| Editing | Simultaneous `TextEdit` transactions, preflight validation, grouped undo/redo, literal/regex search and replacement |
| Sessions | Directed multiple selections with a primary selection, grapheme movement and deletion, typing the same or per-selection text, independently shared sessions, selections restored by undo/redo |
| Input and layout | Begin/update/commit/cancel composition; `LayoutAdapter` for visual rows, preferred advances and display-position resolution |
| Semantics | Lexical and semantic tokens, diagnostics, decorations, generic tracked ranges, nested folds and per-session collapse state, inlay hints |
| Language features | Completion, hover, signature help, definition, references, document symbols, rename, code actions, formatting; also providers for tokens, diagnostics, folds and hints |
| Lifecycle | Request status/results and notifications, explicit cancellation, version/provenance validation, provider registration/unregistration, disposal |
| Workspace editing | Resolve open documents by ID, mandatory target versions, preflight all targets before any change, route provider edits into normal history |

## Positions, strings and boundaries

`Position(line, column)` is **zero-based**. Columns and document offsets count UTF-16
code units, not bytes, Unicode scalars, Swift `Character`s or visual advances.
`TextRange` is ordered and half-open; a collapsed range is an insertion point.
Selections preserve anchor/head direction. The first selection is the leftmost after
canonicalization; overlapping selections, duplicate carets and carets touching a selection
merge, retaining the direction of the first range in sorted order. Touching non-empty
selections stay apart, so adjacent occurrences can be selected separately.
`primaryIndex` names the primary selection, which `setSelections(_:primary:)` chooses and
which follows its selection through sorting, merging, edits and undo/redo. Input methods
and scrolling should follow `primarySelection`.

`type(_:)` inserts the same text at every selection; `type(_ texts:)` inserts `texts[i]`
at `selections[i]`, for input that differs per caret such as a newline with each line's
indentation or one line of a pasted block per caret. Each caret ends after its own text.
For movements the application's layout defines, such as by word or to a visual line
boundary, `move(extendingSelection:to:)` moves each selection's head to the position a
closure returns for it, and `delete(to:historyGroup:)` deletes from each caret to such a
position, deleting non-empty selections as they are. The closures run with the document
locked, as layout callbacks do.

`TextSnapshot.offset(at:)` and `position(at:)` are exact conversions. Bounds errors,
reversed ranges, surrogate-pair interiors and CRLF interiors throw; they are never
silently clamped. Scalar boundaries inside a combining sequence or emoji grapheme are
legal programmatic positions. Movement chooses extended grapheme boundaries. Deletion
from a boundary deletes the adjacent grapheme or a complete line separator; deletion
from an interior scalar boundary expands to the containing grapheme. Selected ranges
are explicit programmatic ranges and can intentionally edit individual scalars.

There is no implicit conversion to Swift `String.Index`. To work with returned line
strings, use their `utf16` view and convert to `String.Index` only when that conversion
is valid for the operation. The snapshot functions avoid dependence on Swift string
index identity. Visual positions are separate: `DisplayPosition` and its `advance`
unit are defined by the application. A `LayoutAdapter` receives the current immutable
snapshot; it must compute positions for that version and return valid logical positions.
During engine calls to the adapter, mutations to that document and its sessions throw
`reentrantMutation`. Adapter errors propagate; the mutation guard is released on failure.
Install it with `session.setLayout(adapter)`. The engine preserves the adapter's
preferred horizontal advance across vertical moves. Without extending, a non-empty
selection moves up from its start and down from its end, as backward and forward
movement collapse to those edges. Operations an adapter defers, such as unregistering
a provider, run after the new selection is installed and announced.
Without an adapter, vertical movement and display selection throw.

`EndOfLine` is explicit and immutable per document. Loading and inserted text normalize
CRLF and lone CR to LF or CRLF as selected. Empty documents have one empty line;
trailing newlines add an empty final line. Exact UTF-16 equality determines no-op edits,
so canonically equivalent but differently encoded Unicode text can be replaced.
Normalization matches CR and LF code units exactly and preserves all other units,
including combining marks immediately after a newline.

Regex search follows the fixed reference's line-local/multiline distinction. Patterns
containing a newline or a regex escape `\n`, `\r` or `\W` search across lines; other
patterns search each logical line separately, including empty lines. Cross-line searches
run on a view whose line breaks are LF, as the reference does: `\n` matches every line
break in CRLF documents too, `\r` never matches one, and captures contain LF line breaks.
`^` and `$` match
line boundaries, and `^` also matches at the end of a document that ends with a line
break, as in the reference. A search scope only limits where matches may lie: `^`, `$`, whole-word
boundaries, `\b` and lookaround still see the text around the scope, so a scope that
starts or ends inside a line or word does not create a line start, line end or word
boundary there. This intentionally differs from the reference, which searches the
scoped text alone.
Capture groups and replacements use Foundation regex syntax, with `$$` retained as an
additional spelling for a literal dollar. Backslash escaping and capture-number parsing
are handled by Foundation; for example, `\$1` is literal `$1`, and `$12` means capture 1
followed by `2` when the expression has only one capture group. Search and replacement
reject matches whose boundaries fall inside a surrogate pair or CRLF. When the regex
engine gives up, for example by exhausting its backtracking stack on a long subject,
search and `replaceAll` throw `searchFailed` instead of returning the matches found so
far; `replaceAll` then leaves the document unchanged. A query that is not a valid regular
expression throws `invalidPattern`. The scope is checked even for an empty query.

## Transactions, history and notifications

`Document.apply(_:expectedVersion:historyGroup:)` interprets every range against the
same pre-edit snapshot. Unordered inputs are sorted. Out-of-bounds ranges, overlapping
edits and edits with identical starting offsets are rejected as a whole. Touching edits
with distinct starts are coalesced into one replacement, including for marker tracking.
An optional expected version rejects stale edits. No-op batches do not advance version
or history; typing unchanged text still collapses selections.

One effective batch is one history entry. Consecutive entries with the same non-nil
group string form one undo step, unless any session's selections changed between them,
as when a caret moves elsewhere; `endHistoryGroup()` sets an explicit boundary. A new
edit after undo clears redo. Versions are monotonically increasing, including undo,
redo and provisional input. Undo/redo restores session selections saved in the entry
for sessions still attached; later-created sessions track the inverse/forward edits.
Semantic data follows range tracking and invalidation, rather than restoring an old
provider result on undo.

Notifications are synchronous on the main actor, after all affected text, selections,
ranges and request statuses have changed. Undo/redo and workspace transactions emit
only after the final consistent state is installed. `DocumentEvent.batches` contains
sequential edit batches; offsets within each batch refer to that batch's pre-edit text.
`DocumentEvent.kind` names the operation that caused the notification, while
`DocumentEvent.changes` lists every kind of state it changed, because one operation can
change several: an edit can move selections, track or stale semantic data and invalidate
request statuses, and a provider result changes both a request status and semantic data.
React to `changes` rather than `kind`. `text` covers the text and version, `selection`
the selections of any session or a session's disposal, `composition` provisional input,
`semantics` semantic data, its freshness or any session's collapse state, and `requests`
the document's request statuses. A flag is set only when that state changed during the
operation, so a notification can carry an empty set. Operations that replay several
steps, such as undoing a grouped entry or cancelling a composition, report a state that
changed along the way even if it ends where it started.
Callbacks can read state and cancel subscriptions. Reentrant document edits, session
changes, disposal and provider registration (for any language, while any document's
notification runs, including standalone documents' and other workspaces') throw
`reentrantMutation`; schedule a later
main-actor task to edit in response to an event. Unregistering a provider and
`cancelRequest` cannot throw, so when called from a notification or a layout-adapter
call they take effect after every document's callbacks have finished, including those
of standalone documents outside the workspace, and after any operation that notifies
before finishing its work (committing a composition with text, or disposing or closing a
document, session or workspace), with their own
notifications; listeners of the current notification never observe their effects.
Cancelling an observation takes effect immediately.

Workspace transactions require **already-open** targets. Missing documents, duplicate
target IDs, stale versions, active compositions or invalid edits fail before any target
changes. During notifications all targets have their final state, and writes to all
targets are blocked, including targets with empty or no-op edit arrays. Only documents
with effective changes advance version, receive a history entry and emit an edit event.
Workspace-wide undo coordination is the application's responsibility; no file creation or filesystem edit
is implied by a document ID. Use `DocumentEdits(snapshot:edits:)` for edits retained
across asynchronous work: it binds the target to the snapshot's document instance as
well as its version. Closing and reopening the same ID therefore rejects old edits
even if the version number repeats. The ID/version initializer addresses whichever
document currently owns that ID and is suitable for immediate application-directed
edits; it does not identify a particular document lifetime.

A composition is a provisional document transaction: begin it on the session's
selections, update the marked text and UTF-16 marked selection, then commit one undo
step or cancel without adding history. Every selection receives the same marked text,
as an input method drives the primary one; `markedRanges` holds one range per selection
and `markedRange` the primary's. When an input method also replaces text beside its marked
text, pass `replacingBefore`/`replacingAfter` UTF-16 counts measured against the primary
marked range; every marked range widens by them. Widened ranges that would overlap are
rejected. Emptied marked ranges that meet merge into one, together with their selections. Other text edits and undo/redo are blocked while it
is active. Beginning and every update/end emit composition events. The document
retains rollback information independently of the originating session; use
`document.cancelActiveComposition()` if that session has been released. Document
shutdown always cancels provisional input before releasing resources.

## Semantic data and range tracking

`semantics(in:)` returns a versioned `SemanticView` containing only items intersecting
the requested logical range (boundary-touching items are included). Setters validate
complete result arrays before replacing them. Provide the source version for tokens,
diagnostics, folds and hints. Register arbitrary markers with `trackRange`, look them
up by ID with `trackedRange`, and explicitly remove them when no longer needed.

For insertion at a range's start/end, `RangeStickiness` controls inclusion:

| Stickiness | Start affinity | End affinity |
| --- | --- | --- |
| growBoth | before | after |
| growNeither | after | before |
| growBefore | before | before |
| growAfter | after | after |

Endpoints inside replaced text collapse to the replacement's start or end according
to affinity. An endpoint at the start of replaced text is a boundary rather than part
of it and stays before the new text, so a range that contained the replaced text keeps
the replacement and a range that ended there does not grow. Endpoints at the old
replacement end follow its new end; positions after
an edit shift by the UTF-16 delta. Inverted ranges collapse. Endpoints that become
surrogate or CRLF interiors through newly joined text snap in their affinity direction.
This intentionally differs from VS Code's legacy common-prefix marker rules.
Session endpoints use after affinity. Tracking is not an exact semantic undo mechanism:
a collapsed diagnostic or marker need not regain its former span when text is restored.

`SemanticView` reports a `SemanticFreshness` for tokens, semantic tokens, diagnostics,
folds and inlay hints: `unavailable` when the document has no data of that kind,
`current` when it was computed for the view's version, and `stale(version:)` when it
was computed for an earlier version and its ranges have been tracked since. Documents
start with every kind unavailable. Setting a result, including an empty one, makes it
current. Text edits, undo and redo track tokens, semantic tokens, diagnostics and folds
(`growNeither` for tokens and diagnostics), making them stale, so highlighting stays in
place until the next result arrives; tokens that collapse are dropped. Inlay hints are
removed and become unavailable, because their edits are bound to the version they were
computed for. Whether a newer result is coming is a request status, not a freshness.
Folds are line-based: a fold covers the lines from its start line to its end line, or
to the line before when it ends at column 0, so a heading fold that ends where the next
heading starts does not cover that heading. Collapsing a fold hides every covered line
after its first. Folds must cover several lines and nest by line: a fold that shares a
line with a fold it is not inside is rejected, because collapsing either would hide
part of the other. Folds track their ranges, and tracked folds that stop meeting these
rules disappear. Folds track with `growNeither`, so text inserted at a fold's start or
end stays outside it: pressing Enter at the start of a heading moves the heading's fold
with it, and typing at the start of the next heading does not extend the fold before it.
Folds are ordered by start line, outermost first.
Collapse state is per session. Providers usually rebuild folds with fresh IDs, so when
new folds are set, each collapsed fold passes its state to the new fold with the same ID,
else to the one covering the same lines, else to the outermost one starting on the same
line, comparing the collapsed fold's tracked position. A collapsed fold without a new
counterpart opens. A caret is never hidden: before every notification, a collapsed fold
that hides a caret of its session opens, whether an edit, a move, undo or new folds put
the caret there. Collapsing a fold moves that session's carets inside it to the end of
the fold's first line; during that session's composition, a collapse that would hide its
caret throws `compositionActive`. Provider registry changes
invalidate affected retained responses and remove semantic data produced by providers,
leaving those kinds unavailable, from every affected document before notifying any document;
all affected documents reject edits and disposal until these notifications finish.
Explicitly supplied application data has independent ownership.

To accept an inlay hint's edits, use the view's version:

```swift
let view = try document.semantics()
if let hint = view.inlayHints.first {
    try document.apply(hint.edits, expectedVersion: view.version)
}
```

## Providers, async results and concurrency

Mutable workspaces, documents, sessions, registrations and subscriptions are
`@MainActor` isolated. Immutable snapshots and result models are `Sendable`. A provider
receives a snapshot, feature, optional position/range and optional rename text. It can
send the snapshot to a detached analysis task; CPU-heavy parsing should not run on the
main actor. The package does not include any parser or LSP client.

Register a `LanguageProvider` or `ClosureProvider` with a language and feature set;
`"*"` matches every language. The last matching registration is selected. The app can
aggregate providers inside that boundary. Keep the returned `Subscription` and call
`cancel()` to unregister. The [integration tests](Tests/EditorEngineTests/LanguageTests.swift)
show deterministic providers for every feature, including result-edit application.

`request` retains `pending`, then `ready`, `failed`, `cancelled` or `invalidated` status
for each document/feature; query it with `status(documentID:feature:)`. Different
features can be requested independently. A new request for the same key supersedes
and cancels its predecessor. The package checks document object identity, version,
request identity and registration when a result returns. Editing, closing/replacing
the document, unregistering/replacing providers or disposal prevents obsolete results
from being published. Even providers that ignore cancellation cannot publish old data.
Every registry change for a matching feature invalidates its request cache.

Provider failures are thrown and retained as `failed(Error)`, never converted to empty
results. Invalid result kinds, ranges, symbol containment and target edits also fail,
with `invalidProviderResult`, so they cannot be mistaken for errors in the request's
own arguments. This covers fold sets that do not nest or repeat IDs, and edit targets
that were open neither when the request started nor now. A result that only the
intervening changes broke fails with `staleResult` instead, because requesting again
can succeed: an edit target opened, closed or reopened during the request, or edited
since the version it had when the request started, and likewise a navigation location
in such a document, whose range would point at changed text.
An empty successful result remains `ready`. `cancelRequest` cancels a particular
document/feature.

A request that ends before publishing records why at that moment, and both its status
and what `request` throws follow from that reason alone, whether or not the provider
honors cancellation:

| Reason | Status | `request` throws |
| --- | --- | --- |
| The caller's task is cancelled | `cancelled` | `CancellationError` |
| `cancelRequest` | `cancelled` | `EditorError.cancelled` |
| A newer request for the same document/feature | the newer request's status | `EditorError.staleResult` |
| Edit, undo/redo, provider registry change, close or disposal | `invalidated` (close removes it) | `EditorError.staleResult` |
| The provider throws, with none of the above | `failed(error)` | the provider's error, unchanged |

The first recorded reason wins. A caller whose task is cancelled always receives
`CancellationError`. `request` returns as soon as the reason is recorded; it does not
wait for the provider. Each ending cancels the provider task, but cancellation is
cooperative: a provider that ignores it may keep computing, and its result is discarded.
A `CancellationError` thrown by the provider itself, without any of these reasons, is a
provider failure.

Use `workspace.apply(response, item:)` to accept completion, code-action, rename or
formatting results; other responses throw `notApplicable`. This validates retained
request provenance, including that no newer request replaced it, as well as source and
target versions, then routes edits through workspace transactions and normal history.
Provider result edits are bound to target instances open when the request started.
Reopening a target during a request rejects the result; reopening it after the result
arrives rejects its application before any document changes. This target binding also
survives extracting a `WorkspaceEdit` from the returned result. Targets must already
be open when the request starts.
Navigation locations may name unopened documents; the app resolves/opens those before
moving a session. Actual workspace-edit targets must be open. Formatting is represented
by versioned workspace edits, allowing document or range formatting through request
arguments. Completion items supply their complete edits; snippets and arbitrary
provider commands are not interpreted by this package. As the Language Server Protocol
allows, signature help may name an active signature or parameter outside its lists; the
engine resets such an `activeSignature` to 0 and such an `activeParameter` to `nil`, so
apps can index with them whenever `signatures` is not empty.

## Ownership and shutdown

A workspace strongly owns open documents and registered providers. A session strongly
owns its document; the document references sessions weakly, so multiple sessions share
text without a retain cycle. A standalone `Document` can be used without a workspace;
provider requests and cross-document edits require a workspace.

A document retains observation closures; cancel observations explicitly, especially
when a closure captures an application owner. Registration tokens and observation
tokens are explicitly cancelled, rather than relying on deinitialization timing.
`Subscription.cancel()` is idempotent. Dispose sessions to detach them and release
layout adapters. `closeDocument` disposes a document and attached sessions, cancels
requests and removes it from the workspace; its request statuses are already gone
during its disposal notification. Closing a document or disposing its
workspace from that document's notification throws `reentrantMutation`, including
within its disposal event. `hiddenLineRanges()` is a read operation and can be called
from notifications while the session and document remain alive.
`Document.dispose` releases histories,
semantic data and subscribers. `workspace.dispose` disposes all owned documents in ID
order, providers and requests; while one document's disposal notification runs, the
others still reject writes. Registry changes also notify documents in ID order. Previously obtained snapshots remain readable across shutdown.
Disposed mutable objects reject subsequent operations; reading the last text snapshot
is allowed. The app must cancel/finish its provider-side analysis resources too.

## Storage, verification and limits

A persistent balanced UTF-16 rope uses leaves of at most 1,024 code units, augmented
with subtree UTF-16 length and newline counts. Local edits copy bounded leaves and
paths, not the entire document. Snapshots share immutable nodes. Position lookup is
logarithmic in tree size plus a bounded leaf scan. Tracking cost also depends on attached
sessions and semantic-range count. Whole-word search treats letters, combining marks, numbers and underscore as word
characters. As in the reference, a match edge is a word boundary when the character
beyond it or the match's own character at that edge is not a word character, so `#`
matches in `#heading`. Regex matches that end inside a surrogate pair or CRLF are omitted because
they cannot be safely edited. Public text export and Foundation regex search
materialize the document; search cost includes line traversal and regex matching. Regex complexity
also depends on the pattern. Grapheme operations materialize the current logical line.
Semantic queries currently filter arrays; there is no interval index or viewport cache.
History and explicitly retained snapshots can grow memory until released/disposed.

[Benchmarks](Documentation/Performance.md) record load, local edit, position conversion
and search for explicit document sizes, plus a matched flat-buffer snapshot comparison.
They support the persistent-tree choice; they are not a real-time latency guarantee.
The [documentation index](Documentation/README.md) links the reference provenance,
fixture correspondence, licenses and verification boundary.

Diff editors, minimaps, VS Code extensions, Monaco API compatibility, syntax/type
analysis, LSP transport, OS input integration, snippet expansion and pixel rendering
are outside the scope. The engine includes the feature models and behavior above;
concrete language intelligence is supplied by application providers.

## License

MIT. See [LICENSE.txt](LICENSE.txt) and
[third-party notices](THIRD_PARTY_NOTICES.md) for copyright notices and upstream licenses.
