# Standards for Output Folder Auto-Relocation

These standards apply to this work. The repo's `agent-os/standards/index.yml` is currently
unindexed (placeholder descriptions), so the relevant files are quoted in full below.

---

## global/error-handling

(Source: `agent-os/standards/global/error-handling.md`)

- **User-Friendly Messages**: Provide clear, actionable error messages to users without exposing technical details or security information
- **Fail Fast and Explicitly**: Validate input and check preconditions early; fail with clear error messages rather than allowing invalid state
- **Specific Exception Types**: Use specific exception/error types rather than generic ones to enable targeted handling
- **Centralized Error Handling**: Handle errors at appropriate boundaries (controllers, API layers) rather than scattering try-catch blocks everywhere
- **Graceful Degradation**: Design systems to degrade gracefully when non-critical services fail rather than breaking entirely
- **Retry Strategies**: Implement exponential backoff for transient failures in external service calls
- **Clean Up Resources**: Always clean up resources (file handles, connections) in finally blocks or equivalent mechanisms

**How it applies:** The relocation's data-safety rules are this standard made concrete. Check
degenerate cases (no-op, nested paths, source missing, unwritable dest, insufficient space)
*before* touching files (fail fast). Surface one user-facing message on failure
("Couldn't move notes: …") without leaking internals. Use a specific migrator error type. On any
failure, leave the source intact and don't switch the active folder (graceful degradation —
capture keeps working against the old folder). Release the `CaptureGate` and clear `isRelocating`
in a `defer` (resource cleanup).

---

## global/coding-style

(Source: `agent-os/standards/global/coding-style.md`)

- **Consistent Naming Conventions**: Establish and follow naming conventions for variables, functions, classes, and files across the codebase
- **Automated Formatting**: Maintain consistent code style (indenting, line breaks, etc.)
- **Meaningful Names**: Choose descriptive names that reveal intent; avoid abbreviations and single-letter variables except in narrow contexts
- **Small, Focused Functions**: Keep functions small and focused on a single task for better readability and testability
- **Consistent Indentation**: Use consistent indentation (spaces or tabs) and configure your editor/linter to enforce it
- **Remove Dead Code**: Delete unused code, commented-out blocks, and imports rather than leaving them as clutter
- **Backward compatibility only when required:** Unless specifically instructed otherwise, assume you do not need to write additional code logic to handle backward compatibility.
- **DRY Principle**: Avoid duplication by extracting common logic into reusable functions or modules

**How it applies:** `OutputFolderMigrator` is a small, single-purpose, dependency-injected
service. Reuse existing helpers instead of duplicating: `FileWriter.uniqueDestination`'s
`<base>-<n>` disambiguation for collisions and `AtomicFile.write` for the sidecar. No
backward-compat scaffolding (plain-URL persistence already exists; no migration of an old format).

---

## testing/test-writing

(Source: `agent-os/standards/testing/test-writing.md`)

- **Write Minimal Tests During Development**: Do NOT write tests for every change or intermediate step. Focus on completing the feature implementation first, then add strategic tests only at logical completion points
- **Test Only Core User Flows**: Write tests exclusively for critical paths and primary user workflows. Skip writing tests for non-critical utilities and secondary workflows until if/when you're instructed to do so.
- **Defer Edge Case Testing**: Do NOT test edge cases, error states, or validation logic unless they are business-critical. These can be addressed in dedicated testing phases, not during feature development.
- **Test Behavior, Not Implementation**: Focus tests on what the code does, not how it does it, to reduce brittleness
- **Clear Test Names**: Use descriptive names that explain what's being tested and the expected outcome
- **Mock External Dependencies**: Isolate units by mocking databases, APIs, file systems, and other external services

**How it applies:** Test behavior through the public `migrate(...)` API against temp dirs, with
clear names. The usual "defer edge cases" guidance is **deliberately overridden here**: because
this moves the user's only copy of their notes, the data-safety edge cases (cross-volume
copy-verify-delete, merge collisions, nested-path guards, failure-leaves-source-intact) *are*
business-critical and must ship with the feature. The `Strategy` enum is the injected seam that
lets the cross-volume path run on a single test volume.

---

## Notes

`agent-os/standards/index.yml` should be re-run through `/index-standards` at some point so these
descriptions are populated; it has no bearing on this feature's implementation.
