# Standards for Integrations Panel

No project standards apply.

`agent-os/standards/` exists in this repo (boilerplate copied from the agent-os template), but per the v1 spec's `standards.md` the project has deliberately not adopted them as binding — the v1 build established its own conventions inline as patterns emerged.

The Integrations panel follows the same established rapture-mac conventions:

- **State containers:** `@Observable @MainActor final class …`, constructed in `AppState.init`, mutated only on `@MainActor`.
- **Atomic file writes:** `.tmp` → `rename(2)` for any persisted user-data file (`watch.env`, settings, state).
- **Subprocess invocation:** `Process()` with explicit `executableURL`, argv as separate strings (no shell interpolation), pipes for stdin/stdout/stderr, custom `Error` struct carrying `exitCode` and `stderr`. Pattern established by `AppleScriptSender`.
- **OSLog category:** subsystem `noisemeld.RaptureMac`, one logger per file.
- **Pure-helper test pattern:** decision logic in `nonisolated static` functions on dedicated types, called from `@MainActor` view code; tested directly without needing to instantiate a view.
- **Test layout:** XCTest under `RaptureMacTests/`, fixtures under `RaptureMacTests/Fixtures/`, naming `<TypeName>Tests.swift`.
- **Commit message style:** Conventional Commits (`feat(integrations): …`, `test(integrations): …`, `chore(xcode): …`), past-tense subject. PRs describe *why* before *what*.

PRIVACY.md and SECURITY.md are not "standards" in the agent-os sense, but they are **load-bearing constraints** the panel cannot violate:

- **No outbound network calls.** `grep -RnE "URLSession|URLRequest|NWConnection|NWListener" RaptureMac/RaptureMac/Integrations/` must continue to return zero matches.
- **No new signing entitlements.** The two entitlements (`app-sandbox = false`, `automation.apple-events = true`) listed in PRIVACY.md stay as the only entitlements. The Integrations panel adds zero.
- **No telemetry.** No analytics SDK, no usage pings, no update checks.

These are verified at PR time by running the same `grep` and `codesign -d --entitlements -` invocations PRIVACY.md documents.
