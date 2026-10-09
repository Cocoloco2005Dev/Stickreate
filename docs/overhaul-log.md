# Overhaul log

Living log for the Stickreate overhaul. One entry per phase/step with evidence and open items.
Branch flow: `overhaul/audit` (Phases 1–2) → `overhaul/p0-fixes` (Phase 4a) → …

## Phase 1 — Ground truth

- **Output**: `docs/overhaul/00-ground-truth.md`.
- **Method**: `explorer` code sweep + `librarian` current-source review (parallel).
- **Evidence**: commit `5145998` on `overhaul/audit`.
- **Key findings**: architecture is clean (no `NavigationView`/`foregroundColor`/legacy `onChange`); glass only on controls; all encode/coordinate invariants hold. Real debts: `packs.json` embeds base64 blobs and rewrites the whole library per mutation with `try?`; `removePack` leaks sources; zero localization (213 strings); CI lacks warnings-as-errors.
- **Discrepancies flagged**: `project.yml` `MARKETING_VERSION=0.3.0` vs docs v0.19.0; `.wasticker` is our ZIP but WhatsApp's official `.wasticker` is JSON.

## Phase 2 — Audit & backlog

- **Output**: `docs/overhaul/01-audit.md`.
- **Method**: `oracle` audit + `explorer` error/edge inventory (parallel).
- **Evidence**: commit `844ba48` on `overhaul/audit`.
- **Top P0**: persistence data-loss; 10 s clip ~480 MB peak; missing privacy manifest; copyrighted app icon.
- **Checkpoint**: user chose **P0 first, then design**; keep current icon for now; user hosts legal texts (we draft).

## Phase 4a — P0 fixes

- **Branch**: `overhaul/p0-fixes` (from `overhaul/audit`). Commit `b6f8b1a`. PR: draft → `main`.
- **Done**:
  - **P0-1** persistence safety: `PackStore.load()`/`persist()` no longer swallow errors; corrupt file quarantined + backup recovery; atomic writes; observable `persistenceError` surfaced in `RootView`; `removePack` deletes sources. Tests: `StickreateTests/PackStorePersistenceTests.swift` (5).
  - **P1-3** progress invariant: removed failure-path `onProgress?(1.0)`. Test: `testFailureNeverReportsOne`.
  - **P0-4** `Stickreate/PrivacyInfo.xcprivacy` (UserDefaults CA92.1, FileTimestamp C617.1; no tracking/collection).
- **Partial / open**:
  - **P0-2** encoder memory: pass-through for already-512×512 `.up` frames + capture preview before encode (Release ARC can drop the source set at the encode call). **Full single-resident fix requires an ownership refactor across `StickerFactory` + callers and a real device measurement** → Phase 4b/6. Video frames are non-square so the pass-through rarely applies; the win here is the early release.
  - **P0-3** app icon: copyrighted art; **deferred by user** — must be replaced before submission (App Review 5.2.1).
- **Verification**: no local Xcode (Windows). **CI green** on `macos-15` — run [`37886270297`](https://github.com/Cocoloco2005Dev/Stickreate/actions/runs/37886270297): Generate project ✓, Resolve packages ✓, **Run tests ✓**, Archive ✓, Package IPA ✓, Upload artifact ✓. (The first run `37886257310` was cancelled by the concurrency group when the log commit was pushed — not a failure.)

### Open items introduced/left

- RootView now has two `.alert` modifiers on the same view (persistence + import). Needs a simulator check that both present correctly; if not, merge into one alert.
- `PackStorePersistenceTests.testRemovePackDeletesStickerSources` writes a temp file under the sandbox `Documents/Sources` (cleaned up with `defer`).
