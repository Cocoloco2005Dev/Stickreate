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

## Phase 3 (chunk 1) + Phase 4b (part 1) — design system + library/pack reskin + P1 fixes

- **Branch**: `overhaul/p0-fixes`. Commits `203e1e2`…(see git log). CI **green** (run `37888536590`).
- **Design chunk 1** (`des-1`): new `Stickreate/DesignSystem/` (tokens, typography, color roles, haptics, shared state views); reskinned `RootView`, `Library`, `PackCard`, `ImportMediaSheet`, `PackEditorView`, `StickerCell`, `ExportSheet`, `FolderPickerSheet`, `EmojiPickerSheet`; accessible accent `#E0264F`; previews. Spec: `docs/overhaul/02-design-spec.md`; `docs/design.md` updated.
- **Phase 4b (part 1)**:
  - `FrameExtractor`: GIF downsampling now sums the skipped frames' delays → total duration preserved (`downsampledDelays`, unit-tested).
  - `StickerEncoder`: extended quality (q25) + frame-drop ladder so motion-heavy clips encode instead of failing.
  - `PackArchive`/`PackStore`: import validation (≤30, no mixed kinds, per-entry 1 MB + total 20 MB caps), launch-time orphan-source reconcile, removed `archive!` force unwraps.
- **CI fixes**: removed uncompilable `#Preview` bodies (`return` inside ViewBuilder; `accessibilityReduceTransparency` is a get-only environment key — cannot be injected).
- **Open / deferred**:
  - **P0-2 full** single-resident frame fix needs an ownership refactor (`StickerFactory` → `StickerEncoder` `inout`/`consume`) + device measurement. Not done (no compiler available to validate).
  - **P1-2** `Original` semantics (restore pre-lift base) → Phase 3 chunk 2/3.
  - Swift 6 mode / warnings-as-errors → Phase 5.
  - Localization (EN + es-AR) → after design freezes strings.
  - **P0-3** app icon still copyrighted art (user decision: keep for now).

## Phase 3 (chunk 2) + Phase 4b (part 2) — editors, Settings, hardening

- **Branch**: `overhaul/p0-fixes`. CI **green** (run `37890619218`).
- **Design chunk 2** (`des-1`): editors reskinned (Adjust/Trim/Lift/queue/preview/Background/Settings);
  `MagnifyGesture`; crop + filmstrip are VoiceOver-adjustable; awaited `player.seek`; `PlaybackModel`
  `@MainActor`; stage announcements; GIF stage progress; mixed-selection trimmed to one kind.
- **Phase 4b part 2** (`fix-2`): `storageSummary` cached + `clearCache` safer; WhatsApp open-delay via a
  main-actor `Task`; dead auto-background path deleted; archive I/O moved off the main actor.
- **CI fix**: `StateViews` take `String` (dynamic error messages can't be `LocalizedStringKey`).

## Phase 3 (chunk 3) + Phase 5 + 6/7 — restore, self-test, tests, CI, docs

- **P1-2** (`fix-1`): `MaskEditor` keeps a pristine `originalBase`; `Original` restores the pre-lift
  photo behind a confirmation; undoable. New `MaskEditorTests`.
- **Self-test** (`fix-3`): `#if DEBUG` `SelfTest`/`DebugView`/`SelfTestReport` + `os.Logger`; launch arg
  `-StickreateSelfTest`; synthetic checks; `selftest-report.json`.
- **Tests** (`fix-6`): geometry edge cases, encoder budget, frame-timing sums, `.wasticker` round-trip,
  ZIP-bomb rejection, WhatsApp payload validation.
- **Settings** (`fix-4`): dead toggles removed; `keepOriginalSources` wired at the AddStickerSheet commit
  choke point; `shouldPersistOriginalSources` accessor.
- **CI** (`fix-7`): `.xcresult` + `selftest-report.json` artifacts, Privacy-Manifest check, job summary.
- **Localization** (`fix-8`): `Localizable.xcstrings` (en + es, 249 strings), JSON-validated.
- **Docs**: `03-device-verification.md`, `04-app-store-readiness.md`, `docs/legal/{privacy-policy,support}.md`;
  README/status/decisions/troubleshooting/build-release/architecture/features updated; version → 0.20.0.
- **Not done / deferred**: P0-2 full ownership refactor (needs device), Swift 6 mode + warnings-as-errors,
  `.wasticker` UTType, app icon replacement, final merge + CI build.

## Post-0.20.0 — reported bugs (video cut / lift / GIF)

User-reported, device-visible:
- **Video Intelligent Cut was a frozen single-frame mask** (`StickerFactory.computeCutout`). Rewritten to
  per-frame Vision (stride 3, 256 px input, `maskAssignments` nearest-mask reuse, leading-frame backfill,
  proportional watchdog, per-frame autoreleasepool). Pure mapping unit-tested (`StickerCutTests`).
- **Lift Subject**: only one subject, no preview, drag unreliable, re-lift compounded cuts. `SubjectLiftView`
  rewritten: enumerate subjects, select via chips/tap/`subject(at:)`, preview box shows the cut-out,
  Cut-out/Original toggle, confirm the selected subject; `StickerEditorView.subjectLiftCover` now uses
  `originalBase` when lifted.
- **GIFs weren't editable**: new `GIFTrimView` (trim/crop/background, timer-based preview since AVPlayer
  can't decode GIF) + `StickerFactory.makeAnimatedSticker(fromGIF:range:cropRect:removeBackground:)` with a
  pure delay-aware `frameRange`; routed from `AddStickerSheet` (queue), `PackEditorView` (re-edit), and
  `ImportMediaSheet` (Library/share-in). Tests: `GIFEditTests`.
- **`oracle` pre-build review**: no blockers; applied R1 (single anchor still cuts), R2 (no leading flash),
  R4 (degenerate GIF range), N3 (autoreleasepool). Version bumped to **0.20.1**.

## Post-0.20.1 — cut fill, per-frame, progress, UI consistency (0.20.2)

- **Auto-fit**: cut-out stickers crop to the subject's alpha bounds and scale to fill (contain) — static in
  `StickerEncoder.alphaFitted`, video/GIF via one union box applied to all frames (uniform, no jitter).
- **Per-frame cut**: `maskStride` 3 → 1 (Vision every frame, 224–256 px input), previous-mask reuse kept.
- **One continuous progress bar**: `ProgressAccumulator` composed across extraction(0→.30) → cut(.30→.65)
  → compression(.65→.95) → done(1.0), strictly monotonic; per-frame/per-attempt reporting.
- **Real Cancel**: `withTaskCancellationHandler` for the cut; `Task.checkCancellation()` before encode and
  at each ladder iteration; `FrameExtractor` throws on cancel.
- **UI consistency** (`des-1`): `NavigationActions` (one prominent `.glassProminent` per screen, consistent
  Back/Cancel), `CreationProgressCard` (live % + Cancel), density in Library/Pack editor/Export.
- `oracle` review of the whole diff: no blockers; applied R1–R4 (early cancel, continuous bar, alpha-fit
  early-out, in-place crop). Version → **0.20.2**.

## Post-0.20.2 — perf, cut quality, error 1000, lift, diagnostics, drag-drop (0.20.3)

User-reported:
- **Speed**: `minimize_size` off by default (was the slowest libwebp mode) with a single last-resort slow
  encode; frames preserved (gentle floor 120, last-resort ≥8; qualities down to 15); GIF cap 80.
- **Cut quality**: `cleanedMask` + alpha threshold ≥16 + robust `alphaUnion` (speck filter, bad-mask guard,
  opaque early-out) so the subject fills instead of shrinking; ghost frame bounded (`maxMaskReuseAge=3`).
- **UI**: preview play/pause to a corner + auto-hide; `PrimaryActionItem` icon-only for the pack export so
  the title isn't truncated; swipe-to-remove in the add queue.
- **WhatsApp**: single `setItems`, size-adaptive delay (≤1 s), retry-once, serialized `open` task.
- **Lift**: transparent touch shield disables VisionKit's native (fused) lift; chips/tap select one subject.
- **Diagnostics**: `DebugLog` ring buffer + `Log` timing/info/error (release-safe) + Settings Copy/Share/Clear.
- **Feature**: drag an external image/video onto Library / a pack / the add queue → sticker (`StickerDrop`).
- `oracle` review: no blockers; applied R1–R5/N1/N4 (CI-safe self-test check, union clip guard, opaque
  early-out, delay cap, orphan-source cleanup, GIF preview cap). Version → **0.20.3**.
