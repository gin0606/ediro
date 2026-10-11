# Fixed reference revisions

Monaco: `fdf1ee75a63b85433a591db4e1184022cad8483b`, package version 0.57.0.
Its package.json pins `vscodeRef` to `6a598d4a13031703d483d103c1d934a36ad27971`.
All VS Code references below use that revision. Monaco's editor core is generated
from VS Code; Monaco's language definitions are not the text engine implementation.

Base: https://github.com/microsoft/vscode/tree/6a598d4a13031703d483d103c1d934a36ad27971

| Scope | VS Code source / tests (relative to base) |
| --- | --- |
| Storage, lines, UTF-16 offsets | src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts; src/vs/editor/test/common/model/pieceTreeTextBuffer/pieceTreeTextBuffer.test.ts |
| Validation, EOL, simultaneous edits | src/vs/editor/common/model/textModel.ts; src/vs/editor/test/common/model/textModel.test.ts |
| Undo/redo and cursor state | src/vs/editor/common/model/editStack.ts |
| Cursor typing and movement | src/vs/editor/common/cursor/cursorTypeOperations.ts; cursorMoveOperations.ts |
| Tracked ranges | src/vs/editor/common/model/intervalTree.ts; src/vs/editor/test/common/model/intervalTree.test.ts |
| Search | src/vs/editor/common/model/textModelSearch.ts; src/vs/editor/test/common/model/textModelSearch.test.ts |
| Language results and providers | src/vs/editor/common/languages.ts |
| Completion cancellation and application | src/vs/editor/contrib/suggest/browser/suggest.ts |
| Fold state | src/vs/editor/contrib/folding/browser/foldingModel.ts |

This is a new Swift implementation, not a class-by-class translation.
The VS Code notice is retained for reference-derived material, including fixtures.
See [license and third-party notices](../THIRD_PARTY_NOTICES.md) for the license files
and redistribution guidance.

## Compatibility

The public contracts and intentional differences are defined in the package README:

- [Positions, EOL and search](../README.md#positions-strings-and-boundaries)
- [Transactions and history](../README.md#transactions-history-and-notifications)
- [Marker tracking](../README.md#semantic-data-and-range-tracking)
- [Provider selection and result application](../README.md#providers-async-results-and-concurrency)
- [Application responsibilities](../README.md#responsibilities-and-supported-features)

VS Code permits coincident insertions. The Swift contract rejects edits with the same
starting offset to remove input-order ambiguity. Reference fixtures establish a
behavioral baseline; they do not imply full Monaco API compatibility.

## Executable fixture correspondence

All positions below are translated from one-based VS Code coordinates to zero-based
Swift coordinates. The tests use only the library's public API, except `RopeTests`, which inspects the
internal tree's balance and leaf sizes through `@testable import` (debug builds only).

| Swift test | Pinned VS Code fixture |
| --- | --- |
| `TextTests.pinnedPieceTreeFixtures` | pieceTreeTextBuffer.test.ts, `basic` and `insert` in the position/offset suite |
| `TextTests.unicodeEOLAndStrictBoundaries` | textModel.test.ts, `validatePosition around high-low surrogate pairs 1`; rejection instead of clamping is intentional |
| `RegressionTests.pinnedInlineMultilineAndTouchingEdits` | modelEditOperation.test.ts, `Insert inline`, `Replace inline/inline 3`, `Replace inline/multi line 1/3`, `Replace muli line/multi line`; editableTextModel.test.ts, `touching edits: two touching replaces/deletes` and Unicode quote insertion from issue #47733 |
| `RegressionTests.pinnedMarkerEdgeAffinities` | modelDecorations.test.ts, non-forced insertion at range `start` and `end`, all four stickiness modes |
| `TextTests.regexAnchorsSearchAndReplaceEachLogicalLine` | textModelSearch.test.ts, `/^/ find`, `/$/ find`, `/^$/ find`, `issue #4836 - ^.*$`; adds LF/CRLF replacement, trailing empty line and scoped-fragment checks |

`modelEditOperation.test.ts`, `editableTextModel.test.ts`, `modelDecorations.test.ts`,
`editStack.test.ts` and `textModelSearch.test.ts` reside under
`src/vs/editor/test/common/model/` at the same fixed revision. Inverse edits / undo
are tested against the original fixture text; engine history grouping is separately
verified because the public Swift history contract intentionally differs.
