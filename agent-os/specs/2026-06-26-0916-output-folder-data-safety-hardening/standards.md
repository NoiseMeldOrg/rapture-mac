# Standards for Output Folder Data-Safety Hardening

The following standards apply to this work.

---

## testing/test-writing

Tasks 4 & 5 are test-heavy; new tests mirror `OutputFolderMigratorTests` (temp-dir fixtures, injected `FileManager`, behavior-focused names). Here the "core user flow" being protected is the integrity of the user's only copy of their notes, so the edge/failure cases (failed relocate, non-empty deletion refusal, create-if-absent over existing content) are business-critical and warrant explicit tests.

- **Write Minimal Tests During Development**: Do NOT write tests for every change or intermediate step. Focus on completing the feature implementation first, then add strategic tests only at logical completion points
- **Test Only Core User Flows**: Write tests exclusively for critical paths and primary user workflows. Skip writing tests for non-critical utilities and secondary workflows until if/when you're instructed to do so.
- **Defer Edge Case Testing**: Do NOT test edge cases, error states, or validation logic unless they are business-critical. These can be addressed in dedicated testing phases, not during feature development.
- **Test Behavior, Not Implementation**: Focus tests on what the code does, not how it does it, to reduce brittleness
- **Clear Test Names**: Use descriptive names that explain what's being tested and the expected outcome
- **Mock External Dependencies**: Isolate units by mocking databases, APIs, file systems, and other external services

---

## global/error-handling

Failure paths stay fail-safe and user-legible (the existing `MigrationError` pattern). The new guard (`FileSafety.removeIfEmpty`) and scaffold (`OutputFolderScaffold.seedIfEligible`) **log and no-op** rather than throw on their non-eligible cases, because "nothing to do" is not an error.

- **User-Friendly Messages**: Provide clear, actionable error messages to users without exposing technical details or security information
- **Fail Fast and Explicitly**: Validate input and check preconditions early; fail with clear error messages rather than allowing invalid state
- **Specific Exception Types**: Use specific exception/error types rather than generic ones to enable targeted handling
- **Centralized Error Handling**: Handle errors at appropriate boundaries (controllers, API layers) rather than scattering try-catch blocks everywhere
- **Graceful Degradation**: Design systems to degrade gracefully when non-critical services fail rather than breaking entirely
- **Retry Strategies**: Implement exponential backoff for transient failures in external service calls

---

## backend/migrations

The file-move discipline (verify-before-delete, idempotent, recoverable, leaves source intact on failure) is the governing analog for the migrator touch-ups. The DB-schema-specific bullets (indexes, schema/data split) don't apply to a filesystem move; the reversibility/safety spirit does.

- **Reversible Migrations**: Always implement rollback/down methods to enable safe migration reversals
- **Small, Focused Changes**: Keep each migration focused on a single logical change for clarity and easier troubleshooting
- **Zero-Downtime Deployments**: Consider deployment order and backwards compatibility for high-availability systems
- **Separate Schema and Data**: Keep schema changes separate from data migrations for better rollback safety
- **Index Management**: Create indexes on large tables carefully, using concurrent options when available to avoid locks
- **Naming Conventions**: Use clear, descriptive names that indicate what the migration does
