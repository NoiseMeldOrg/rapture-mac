# Standards for the Triage Engine

> Created: 2026-07-13

The house patterns this feature applied and reinforced. Each is now load-bearing across
five milestones of shipped code; future work in these areas should follow them by default.

## `isRunningXCTests` front-guards on every TCC/network entry point

The test bundle is hosted in the app, so any launch-time or call-time side effect that hits
the network or a TCC-protected resource destabilizes the headless test host. Every entry
point that could is front-guarded on `ProcessInfo.processInfo.isRunningXCTests`:
`SystemEventKitClient` (every method), `AppleFoundationEngine`, `AnthropicEngine`,
`URLSessionLinkFetcher`, and `Pipeline.startTriage()` inside the existing guard. The full
suite runs with zero TCC prompts, zero network, zero host restarts.

## Protocol seams + fakes

Every external dependency sits behind a small protocol with a test fake: `EventKitClient`
(EventKit), `AITriageEngine` (both model engines), `HandoffProcessing` (the manager),
`SpoolFiling` (the flusher), `FileWriting` (the writer), `CredentialStore` (Keychain),
`LinkFetcher` (the web). The one file per framework rule holds: only
`SystemEventKitClient` imports EventKit, only `AppleFoundationEngine` imports
FoundationModels, only `AnthropicEngine`/`AnthropicWire` + `URLSessionLinkFetcher` touch
`URLSession`.

## Pure, `nonisolated` helpers with golden tests

Decision logic is extracted into pure functions/types testable without I/O or actors:
`TriageClassifier`, `TitleDeriver`, `CaptureContract`, `TriageWatcher.plan`,
`DestinationGuard` (probe-injectable), `HandoffDateParser`, `HandoffDetector`,
`AITriageValidator`, `AIEngineResolver`, `AnthropicWire`, `YouTubeTranscript`,
`ArticleExtractor`, `LinkFingerprint`, `EnrichmentArtifact`, and every ledger's statics.
The project defaults to MainActor isolation, so helpers that run in detached tasks are
explicitly `nonisolated` (`DestinationGuard`, `OutputFolderMigrator`). Byte-level
invariants get golden tests (spool flush byte-equals a live write; the raw path is
byte-identical to v1.0.88).

## Lenient decoding: `decodeIfPresent ?? default`

Every field added to `Settings` or `PersistedState` decodes leniently so older files load
unchanged — this is what let updaters default into full triage safely (`triageMode ??
.full`) while every opt-in defaulted off. Unknown enum raw values also decode to the
default rather than throwing (a throwing decode silently resets *every* setting — the M1
review caught exactly that). Versioned sidecar formats (`SpoolMetadata.version`) bump +
lenient-decode rather than break.

## The ledger shape: TTL + cap + pure statics, persisted in `state.json`

Dedup/crash-safety state is a bounded array of fingerprint entries with a TTL (90d house
default) and a capacity cap (500), maintained by pure static helpers and persisted via
`StateStore`. Filing follows file → ledger-record → delete-source ordering so every crash
window is double-covered. Ledgers that store destination-relative paths must be remapped
when relocation renames notes (`TriageLedger.remap`, `EnrichedLinkLedger` remap).

## Capture-gate discipline

`CaptureGate` remains the single serialization point around the output folder; all four
filing seams and the folder relocation acquire it, and triage/spool work defers under pause
and relocation exactly like the original processors. **Never hold the gate across network
I/O:** enrichment fetches entirely outside the gate and takes one short gated mutation
pass. The one recorded exception is M4's in-composer AI call (bounded by the 10s timeout +
cooldown, accepted so the note lands in one atomic write) — don't add another without the
same bounds.

## Atomic writes and guarded deletion

Everything durable commits atomically: `.tmp` → `rename(2)` for files (`AtomicFile`),
dot-prefixed staging directory → rename for spool items (scanners ignore dot-prefixed
names). Sources are deleted only after the output is durably written and recorded;
cross-item operations that can partially fail carry compensating rollback (attachment
move+rename+rewrite) or delete-after-verify (`OutputFolderMigrator`). Directory removal
goes through `FileSafety.removeIfEmpty` only.

## DEBUG container isolation

Development never shares state with the installed app: the Application Support container,
default output folder, and relay folder are `#if DEBUG`-suffixed, which made the spool
DEBUG-isolated for free, and the pattern was extended to the Keychain service name
(`noisemeld.RaptureMac.debug`). DEBUG-only escape hatches for live verification are env
vars (`RAPTURE_AI_FORCE_ENGINE`), never settings.

## Quiet failure for opt-in tiers

Established by handoff and now the rule for every layer above filing: failures of an
optional tier surface in Settings (`handoffLastError`, `aiLastError`,
`enrichmentLastError`) and OSLog — never the menu-bar error surface, never a blocked or
delayed filing. The menu bar is reserved for capture-pipeline problems (FDA, Automation,
destination offline, write errors).
