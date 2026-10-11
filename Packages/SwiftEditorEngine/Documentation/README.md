# Design and reference documentation

The [package README](../README.md) is the source of truth for public behavior,
application responsibilities and build commands. These documents preserve the
reference provenance and measurement evidence behind the implementation.

| Document | Read when |
| --- | --- |
| [References](References.md) | Comparing behavior with the pinned Monaco / VS Code sources or tracing adapted test fixtures and licenses |
| [Performance](Performance.md) | Evaluating the storage tradeoff, reproducing recorded measurements or interpreting their limits |

Performance uses the upstream storage reference identified in References to explain
the Swift storage tradeoff, and reports a measured comparison with a flat-buffer model.
Executable checks live in [the test suite](../Tests/EditorEngineTests/),
with upstream fixture correspondence recorded only in References.

## Verification boundary

CLI verification has been performed on arm64 macOS with Swift 6.4. Actual OS input
integration and application-supplied providers have not been exercised by those checks. See the package README for
[build and test commands](../README.md#build-and-use).
