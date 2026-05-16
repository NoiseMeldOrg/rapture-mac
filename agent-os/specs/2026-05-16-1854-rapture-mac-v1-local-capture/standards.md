# Standards for Rapture for Mac v1

No project standards apply.

`rapture-ios/agent-os/standards/` does not exist as a structured set — the rapture-ios repo's conventions are documented inline in CLAUDE.md and DEVELOPMENT-WORKFLOW.md, not as discrete standards files.

The new `rapture-mac` repo will establish its own standards as patterns emerge from v1 implementation (likely under `rapture-mac/agent-os/standards/` once there's enough Swift code to extract repeatable patterns from).

For now, follow the rapture-ios conventions where they translate to macOS:

- **Code style:** SwiftUI + async/await + `@Observable` (iOS 17+ equivalent on macOS is macOS 14+).
- **MVVM separation:** Views own state, ViewModels own business logic, Services own I/O.
- **Atomic file writes:** `.tmp` → `rename(2)` for any user-data file (settings, state, output).
- **Keychain for secrets:** Not needed in v1 (no API keys), but the pattern is established in rapture-ios's `KeychainManager.swift` if cloud mode lands later.
- **Auto-versioning:** Mirror rapture-ios's git-commit-count scheme via a Run Script build phase if/when the app reaches distribution.
