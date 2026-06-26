# Standards for Sparkle Auto-Update

The following standards apply to this work.

---

## testing/test-writing

Sparkle is mostly framework wiring + Info.plist config, which has a thin unit-test surface. Test the pure logic we add (e.g. an appcast-entry generator, if extracted to a script/function), and validate the update flow end-to-end (build against a staging appcast, confirm prompt + install). Mirror the existing test style (`OutputFolderMigratorTests`: temp-dir fixtures, injected `FileManager`, behavior-focused names).

- **Write Minimal Tests During Development**: Do NOT write tests for every change or intermediate step. Focus on completing the feature implementation first, then add strategic tests only at logical completion points
- **Test Only Core User Flows**: Write tests exclusively for critical paths and primary user workflows. Skip writing tests for non-critical utilities and secondary workflows until if/when you're instructed to do so.
- **Defer Edge Case Testing**: Do NOT test edge cases, error states, or validation logic unless they are business-critical. These can be addressed in dedicated testing phases, not during feature development.
- **Test Behavior, Not Implementation**: Focus tests on what the code does, not how it does it, to reduce brittleness
- **Clear Test Names**: Use descriptive names that explain what's being tested and the expected outcome
- **Mock External Dependencies**: Isolate units by mocking databases, APIs, file systems, and other external services

---

## global/error-handling

Update failures (no network, bad EdDSA signature, failed download, malformed appcast) must surface a clear, non-alarming message through Sparkle's standard UI, and must **never** crash the app or block the capture pipeline. Auto-update is strictly additive to the core flow.

- **User-Friendly Messages**: Provide clear, actionable error messages to users without exposing technical details or security information
- **Fail Fast and Explicitly**: Validate input and check preconditions early; fail with clear error messages rather than allowing invalid state
- **Specific Exception Types**: Use specific exception/error types rather than generic ones to enable targeted handling
- **Centralized Error Handling**: Handle errors at appropriate boundaries (controllers, API layers) rather than scattering try-catch blocks everywhere
- **Graceful Degradation**: Design systems to degrade gracefully when non-critical services fail rather than breaking entirely
- **Retry Strategies**: Implement exponential backoff for transient failures in external service calls

---

## global/coding-style

The `UpdaterController` and any helpers match the app's conventions: `@Observable`/`@MainActor` where state is observed, small focused types, descriptive names, no dead code, DRY (the appcast/notarize logic in `release.sh` reuses the shared `notarize_and_check` helper pattern rather than duplicating).

- **Consistent Naming Conventions**: Establish and follow naming conventions for variables, functions, classes, and files across the codebase
- **Automated Formatting**: Maintain consistent code style (indenting, line breaks, etc.)
- **Meaningful Names**: Choose descriptive names that reveal intent; avoid abbreviations and single-letter variables except in narrow contexts
- **Small, Focused Functions**: Keep functions small and focused on a single task for better readability and testability
- **Consistent Indentation**: Use consistent indentation (spaces or tabs) and configure your editor/linter to enforce it
- **Remove Dead Code**: Delete unused code, commented-out blocks, and imports rather than leaving them as clutter
- **Backward compatibility only when required:** Unless specifically instructed otherwise, assume you do not need to write additional code logic to handle backward compatibility.
- **DRY Principle**: Avoid duplication by extracting common logic into reusable functions or modules
