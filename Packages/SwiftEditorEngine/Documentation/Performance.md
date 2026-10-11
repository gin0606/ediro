# Reproducible performance measurement

Recorded on arm64 macOS 27.0.1 with Apple Swift 6.4, release optimization.
One sequential invocation; no concurrent benchmark workers. Compilation uses at most
two jobs. Build time is excluded from the measurements. These are individual observed
samples, not statistical latency bounds or a cross-machine performance guarantee.

Run the benchmark using the [package commands](../README.md#build-and-use).
The [benchmark source](../Sources/EditorBenchmark/main.swift) defines the workload.

The corpus repeats `let value = 12345 // benchmark 😀\n`. Sizes below are the initial
UTF-16 count and the number of non-empty input lines; a trailing empty line is also
present. Each size runs:

- Load and normalize the complete LF document into the augmented rope.
- 200 insertions of `x` at columns `i % 10` of the middle logical line, retaining history.
- 1,000 position → UTF-16 offset → position roundtrips at column 5 on different lines.
- Five literal searches for `value`, including regex creation, text materialization
  and public match-result construction.
- The same 200 insertions on a separate document holding six highlight tokens per
  line, each insertion tracking every token.
- One `replaceAll` of `value` with `amount` on that document: one edit per line in a
  single batch, tracking every token through all of them.
- A separate matched 20-insertion comparison: persistent rope with history versus a
  flat UTF-16 array retaining a pre-edit snapshot for every insertion. Offsets and
  inserted code units are the same. The flat baseline is not a complete editor.

The largest flat comparison retains approximately 68 MB of UTF-16 payload temporarily;
all documents and comparison arrays are released before the next size.

| Non-empty lines | Initial UTF-16 units | Load, ms | 200 local edits, ms | 1,000 roundtrips, ms | Five searches, ms | Rope 20 edits, ms | Flat 20 edits, ms |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 34,000 | 0.541 | 1.343 | 0.843 | 9.584 | 0.060 | 0.055 |
| 10,000 | 340,000 | 1.901 | 0.457 | 0.506 | 55.738 | 0.105 | 0.714 |
| 50,000 | 1,700,000 | 10.749 | 0.691 | 0.642 | 288.285 | 0.068 | 3.405 |

| Non-empty lines | Tracked tokens | 200 local edits with tokens, ms | Per edit, ms | Replace all with tokens, ms |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 6,000 | 40.333 | 0.202 | 10.551 |
| 10,000 | 60,000 | 316.353 | 1.582 | 131.476 |
| 50,000 | 300,000 | 1,531.943 | 7.660 | 611.259 |

Tracking cost is linear in the number of tracked items, also for batches with many
edits. Endpoints outside the edited span move by line and column arithmetic; endpoints
inside it consult the text and find their edit by binary search, so a batch adds a
logarithmic factor in its number of edits rather than a linear one. The replace-all
column includes the search.

These measurements do not cover replacement-template expansion, layout callbacks or
provider-registry notifications.

## Data structure decision

The [fixed VS Code reference](References.md) uses an augmented piece tree. The Swift
implementation chooses a persistent tree to share storage between the current text,
snapshots and undo history, avoiding a full-buffer copy on each edit. This trades
simple contiguous storage for tree traversal and retention of shared nodes.

In these samples local-edit and conversion totals remain roughly flat as size grows,
whereas retained flat-buffer editing grows with document size. This supports choosing
the persistent tree over a full-buffer copy per edit. It does not prove a latency bound
for arbitrary documents, selection sizes or numbers of tracked ranges.

Load and search scale with document size. Apart from the token workload, the benchmark
isolates text storage; it does not measure session tracking costs. See the package
README for [operation costs and memory limits](../README.md#storage-verification-and-limits).
