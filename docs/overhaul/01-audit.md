# 01 — Audit & Prioritized Backlog (Phase 2)

Independent audit of all 39 app Swift files + 5 test files + `project.yml` + `ios.yml` + docs.
Sources: `oracle` (audit/backlog) + `explorer` (error-path & edge-case inventory), branch
`overhaul/audit`, baseline `5145998`.

Constraint: no Xcode on this machine (Windows). Compile-level claims (Swift 6 diagnostics) are
derived from source and marked as such; runtime/device claims are isolated in **Device-only unknowns**.

---

## Backlog — P0 (crash / data loss / App-Review rejection)

| ID | area | file:line | cause | fix | verify |
|---|---|---|---|---|---|
| P0-1 | Persistence | `PackStore.swift:176-184` (+ every mutation `:27,34,55,65,93,110,120,140,145,159,171`) | `load()` and `save()` both `try?`. Corrupt `packs.json` silently resets to `[]`; next mutation overwrites the good file → permanent wipe. Storage-full writes invisible. Every mutation re-encodes the whole library incl. base64 blobs on the main actor. | Throwing `load()`/`save()`; quarantine unreadable file to `packs.corrupt-<ts>.json` + try backup + recoverable banner; "Not enough storage" on write failure. Move blobs to per-sticker files (§5). | `PackStorePersistenceTests`: truncated JSON → recover from backup, no overwrite; injected write error → propagated; 30-sticker save < 50 ms. |
| P0-2 | Memory | `StickerEncoder.swift:62,207-213`; `FrameExtractor.swift:110-140` | 10 s @24 fps = 240 frames ≈240 MB (512² RGBA). `prepare()` builds a **second** full set while the source array is alive → ≈480 MB peak before encoding. Jetsam risk on 4 GB devices. | Skip redraw when already 512²/.up; release source frames before the ladder; or stage compressed + decode per attempt; consider capping ~150 frames for >8 s. | Device: 10 s 4K clip, Instruments peak < 600 MB; DEBUG budget assert. |
| P0-3 | App Review | `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` | App icon is copyrighted anime art (Urusei Yatsura — Lum). Guideline 5.2.1: no third-party protected content in icon → rejection/IP risk. | Replace with original or licensed art; keep proof of license. | Visual review of the 1024 icon in a release build. |
| P0-4 | App Review | repo-wide; `project.yml:52-77` | No `PrivacyInfo.xcprivacy` anywhere. App uses required-reason APIs (UserDefaults CA92.1, file timestamp C617.1, disk space E174.1) and ships SDWebImage (required SDK). Submission blocker since 2024. | Add manifest (`NSPrivacyTracking=false`, empty collected types, the three codes); add to app target resources. | CI: `unzip -p …ipa 'Payload/Stickreate.app/PrivacyInfo.xcprivacy'` + `plutil -lint`. |

## Backlog — P1 (functional bugs)

| ID | area | file:line | cause | fix | verify |
|---|---|---|---|---|---|
| P1-1 | Correctness | `FrameExtractor.swift:231-245` | GIF downsampling keeps 1-in-`step` frames but only the **kept** frame's delay. 100-frame/30 fps GIF → 25 frames × 33 ms ≈0.83 s instead of 3.33 s → plays ~4× fast. | Accumulate delays of skipped frames into the kept frame. | `FrameExtractorGIFTests.testDownsampledGIFPreservesTotalDuration`. |
| P1-2 | Correctness | `StickerEditorView.swift:437-453,898-907`; `MaskEditor.swift:285-287,337-342` | `applyLiftedSubject` replaces the whole `MaskEditor` with `base = cutout`; "Original" only swaps the mask → background unrecoverable; prior crop/strokes/undo discarded silently. | Keep pristine base in `MaskEditor` (`originalBase` + `setBase`); `Original` restores it; warn before discarding edits. | UI/manual: lift → Original → background back; lift → crop → lift → warning or preserved. |
| P1-3 | Correctness/progress | `StickerEncoder.swift:124-129`; `StickerFactory.swift:265-272` | Animated failure path calls `onProgress?(1.0)` before returning `nil` → "Optimizing WebP… 100%" then error. Violates no-fake-100% invariant. | Delete the failure-path `1.0`; ceiling at 0.999; let thrown `Failure` drive the error. | `StickerEncoderBudgetTests.testFailureNeverReportsOne`. |
| P1-4 | Correctness | `StickerEncoder.swift:22-27,85-129,257-273` | Ladder stops at q40 with ≥50% frames (floor 24). Motion-heavy 10 s clip exceeding 480 KB at all 9 attempts hard-fails. | Extend ladder (q25; lower frame floor before failing) or return smallest payload. | Unit: 240 noisy frames → non-nil ≤480 KB. Device: 10 s handheld 4K. |
| P1-5 | Settings | `SettingsView.swift:13,21`; stores read by nothing (grep) | "Keep original sources" / "Export to" are decorative; `defaultFPS`/`confirmIntelligentCut` orphaned. View comment claims "no decorative toggles". | Wire them (skip source persistence; default export action) or remove; surface/delete orphans. | Unit tests assert behavior changes; UI test toggle → `source == nil`. |
| P1-6 | Performance | `RootView.swift:82`; `LibraryView.swift:460,364`; `PackEditorView.swift:459`; `SettingsStore.swift:119-125` | Sync main-thread `Data(contentsOf:)` + ZIP build/parse; `storageSummary` enumerates `Sources/` every Settings render. | `Task.detached` + progress for archive I/O; cache storage size. | Device: 30-sticker import/export, Time Profiler shows no main-thread read. |
| P1-7 | Leak | `PackStore.swift:143-146` | `removePack` never deletes `Sources/` files (removeSticker does) → deleted media on disk forever. | Delete each sticker's source before `save()`. | `PackStoreTests.testRemovePackDeletesSources`. |
| P1-8 | Robustness | `PackStore.swift:32-35`; `PackArchive.swift:142-226` | `importPack` stores any decoded pack: no ≤30 cap, no kind-mix check, no byte cap. ZIP bomb / 5000 images → OOM + base64 storage bloat. | Validate count/kind/bytes on import; cap entry (1 MB) + total (20 MB); typed error. | Unit: 31-sticker + 100 MB-declared entry rejected. |
| P1-9 | Concurrency | `PackStore.swift:6,8`; `SettingsStore.swift:21,22`; `StickerFactory.swift:29`; `BackgroundRemover.swift:40`; `MaskEditor.swift:502`; `WebPAnimationEncoder.swift:50`; `VideoTrimView.swift:10-13,454-503` | Swift 6 blockers: non-`@MainActor` `@Observable` singletons; non-Sendable `CIContext`/`vImage_CGImageFormat` statics; `@State` mutated from AVPlayer/KVO/queue callbacks. | `@MainActor` both stores + `PlaybackModel`; Sendable box or per-task contexts; audit observer closures. | CI with `SWIFT_VERSION=6` + strict concurrency, clean compile. |
| P1-10 | Performance/crash | `StickerSourceStore.swift:131-144` used from `AddStickerSheet.swift:658`, `StickerEditorView.swift:973` | Full-res source JPEG read+decode synchronously on main; 48 MP photo can watchdog/spike at commit/open. | Async off-main load; ImageIO downscaled decode for display; full-res only in the editor pipeline. | Device: 48 MP open/commit, hang detector clean. |

## Backlog — P2 (UX polish / robustness)

| ID | area | file:line | cause | fix | verify |
|---|---|---|---|---|---|
| P2-1 | Video preview | `VideoTrimView.swift:581,648,663` | `player.seek` fire-and-forget in loop/scrub/toggle (invariant says `await`). | Await async overload / serialize seeks in one Task. | Device: loop 10 s, no boundary flash. |
| P2-2 | Error UX | `StickerFactory.swift:293-327` | Video Intelligent Cut failure/timeout never surfaced → silent original frames. | Signal "cut skipped" to stage/alert. | Manual with forced Vision failure. |
| P2-3 | Editing | `PackEditorView.swift:289-293` | Imported stickers (`source == nil`) can't be edited; hint only. Requirement wants explain **and** allow replacing source. | "Replace media…" action → new source, re-encode in place. | UI test. |
| P2-4 | Export | `WhatsAppExporter.swift:130-137`; `ExportSheet.swift:162-175,210-215` | `open()` failure undetectable; "Added to WhatsApp" optimistic; auto-dismiss 1.2 s regardless. | Use `open` completion to confirm/alert; claim success only on return. | Device: WhatsApp missing/blocked → guidance alert. |
| P2-5 | Cancellation | `VideoTrimView.swift:134,711-745`; `FrameExtractor.swift:182-203`; `StickerEncoder.swift:85-129` | Back disabled during create; no `Task.isCancelled` in loops → slow encode can't abort. | Cooperative cancellation + Cancel affordance. | Device: cancel 10 s encode within 1 s. |
| P2-6 | Share-in | `ImportMediaSheet.swift:320-328`; `StickerEditorView.swift:867-870` | Share-in photo forces Adjust; Apply disabled until an edit → no "add as-is". | Add "Add without editing" (`encodeStatic`, original kept). | UI test. |
| P2-7 | API | `StickerEditorView.swift:339` | `MagnificationGesture` deprecated (iOS 17+). | `MagnifyGesture`. | Warnings-as-errors clean. |
| P2-8 | Battery | `SubjectLiftView.swift:359-384` | Up to 12 s + 2 min of 0.4 s `highlightedSubjects` polling retained while sheet open. | Delegate/notification-driven; reduce/cancel polling. | Device Energy Log. |
| P2-9 | Progress UX | `AddStickerSheet.swift:685-687,692-700` | GIF default commit passes no `onStage` (stuck "Loading…"); each stage update spawns a Task hop. | Pass stage handler; coalesce updates (~10 Hz). | Manual: unedited GIF stages advance. |
| P2-10 | Edge UX | `AddStickerSheet.swift:76-84,591-606,628-643` | Empty-pack picker accepts photos+videos in one selection; commit adds first kind then errors on rest (partial add). | Filter selection to first item's kind up front with message. | UI test. |
| P2-11 | Performance | `StickerCell.swift:59`; `PackCard.swift:10-12`; `ExportSheet.swift:90`; `StickerPreviewSheet.swift:24` | `UIImage(data:)` decoded on main per cell/render; 30-cell grid re-decodes PNGs while scrolling. | Async downscaled thumbnail cache keyed by sticker id. | Device: scroll 30-sticker pack, hitches gone. |
| P2-12 | Export validation | `ExportSheet.swift:200-219`; `WhatsAppExporter.swift:61-127` | Export path skips `pack.validate()` + byte budgets; pack-level `export(_:)` dead; split-mixed identifier lacks kind suffix (both halves share id). | Call `validate()` + byte checks; implement split export or delete dead path. | Unit: 31-sticker/2 MB pack rejected. |
| P2-13 | Fidelity | `StickerSourceStore.swift:110-124` | Sources saved as JPEG → transparent PNG source loses alpha (black bg on re-edit). | Preserve PNG when alpha; JPEG otherwise. | Unit: transparent PNG round-trip. |
| P2-14 | Settings | `SettingsStore.swift:100-125` | `clearCache` deletes all temp (can nuke in-flight export ZIP); `storageSummary` sync I/O per render; footer says `.stickreatepack` (stale). | Exclude active temp; cache size; fix copy. | Manual: share sheet open → Clear Cache → no breakage. |
| P2-15 | Hardening | `project.yml:60-70`; `PackArchive.swift:31` | No UTType/`CFBundleDocumentTypes` for `.wasticker` → no Open-In/Files association; `fileImporter` falls back to `.data`. | Declare exported/imported UTType; use in `fileImporter`. | Device: Files Open-In offers Stickreate for `.wasticker`. |
| P2-16 | CI | `ios.yml:59-84`; `project.yml:26,83` | No warnings-as-errors/lint; coverage off; no PrivacyInfo check; no self-test job. | `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` on CI, coverage, manifest lint, SwiftLint. | CI: warnings fail build. |
| P2-17 | App Review | `PackEditorView.swift:244-249`; `ExportSheet.swift:168-173`; Settings | 4.2 vulnerability (sticker-only wrapper) + WhatsApp-green prominent buttons/named actions; no in-app privacy-policy link. | Referential wording, neutralize brand-green, lead metadata with creation/editing value; add privacy link. | Review checklist + screenshots. |
| P2-18 | Dead code | `StickerFactory.swift:35-108`; `BackgroundRemover.swift:48-51` | `makeSticker`/`makeStatic`/`loadUprightImage` unused and encode the **old auto-background-removal** behavior — regression trap. | Delete dead path (keep `extractSubject`). | grep no callers; build clean. |
| P2-19 | Performance | `MaskEditor.swift:91-100,122-147,281-300` | `init` seeds/cleans every instance mask on main; `setInstances` unions O(instances×pixels) on main → editor-open hitch on 1024². | Off-main seeding/union or vImage max ops; throttle. | Device: 4 instances, main thread < 100 ms. |
| P2-20 | Observability | repo-wide | No `os.Logger`, no DEBUG self-test mode (only DEBUG prints). Phase 5 requires both. | Privacy-safe log categories + DEBUG self-test screen/launch arg. | Self-test runs in CI simulator. |

## Backlog — P3 (nice-to-have)

| ID | area | file:line | cause | fix | verify |
|---|---|---|---|---|---|
| P3-1 | Localization | repo-wide | 0 `.xcstrings`/`.lproj`; ~213 hard-coded strings. | String Catalog EN + es-AR. | Build both locales, no missing keys. |
| P3-2 | Docs/version | `project.yml:27` vs `docs/status.md:5` | `0.3.0` vs v0.19.0; stale `.stickreatepack` comments (`LibraryView.swift:360`, `SettingsView.swift:29`). | Normalize version source; fix copy. | Tag produces matching version. |
| P3-3 | Safety | `PackArchive.swift:73-79`; `MaskEditor.swift:313` | 6 force unwraps, all safe today. | Non-optional locals. | Lint: no `!` in app target. |
| P3-4 | Dead paths | `WhatsAppExporter.swift:44-59`; `ExportSheet.swift:145-157` | Pack-level export + mixed-pack notice unreachable. | Implement split export (kind-suffixed ids) or delete. | Product decision. |
| P3-5 | Perf | `VideoTrimView.swift:605-625` | Filmstrip makes a new `AVAssetImageGenerator` per thumbnail, sequential. | Reuse one generator; bounded concurrency. | Device: filmstrip < 1 s for 10 s clip. |
| P3-6 | Accessibility | `BackgroundChoiceView.swift:106`; `StickerPreviewSheet.swift:108`; `SubjectLiftView.swift:233` | Fixed `font(.system(size:))`; AX audit untested. | Relative text styles; `performAccessibilityAudit` UI test. | UI test at largest AX sizes. |
| P3-7 | Robustness | `PackStore.swift:42,74,90,98,…` | Silent `return` on missing ids; `add` no-ops if pack vanished (queue item dropped). | Throw/assert on programmer errors. | Unit tests for missing-id paths. |
| P3-8 | Leaks | `StickerSourceStore.swift:146-148,176,183` | `try?` hides delete/copy failures → orphan files. | Log + reconcile orphans on launch. | Launch-time orphan sweep test. |
| P3-9 | Import | `PackArchive.swift:326-329` | `isAnimatedWebP` scans only first 32 bytes for `ANIM`. | Parse RIFF chunks properly. | Unit: static WebP containing `ANIM` stays static. |

---

## Detail — correctness

- **P1-1 GIF duration** is the clearest logic bug: `step` sampling discards time; `prepare` only rescales when total >10 s, so short GIFs keep the wrong total. Fix must sum skipped delays before the +8 ms clamp.
- **P1-2 `Original`**: `applyLiftedSubject` builds `MaskEditor(base: cutout, mask: nil)` (`StickerEditorView.swift:437`); `reset()`/`setInstances([])` only reset `maskData` (`MaskEditor.swift:285-287,337-342`). Base never restorable; prior crop/mask/undo discarded with no confirmation. The `docs/status.md:28-29` caveat is a real defect.
- **P1-3 progress**: success path clean (`StickerEncoder.swift:118`); failure path emits `1.0` at `:128`.
- **P1-4 frame floors**: 240-frame ladder = {180,120,full} × q{80,60,40} = 9 full encodes before failure, no cancel.
- **Import paths**: `PackArchive.importManifest` infers one kind and never validates; `importLegacyJSON` can produce a genuinely mixed pack — the only live way to reach the mixed-export notice. `PackStore.importPack` doesn't validate (P1-8).
- **Verified invariants**: top-left mask coords, top-left RGBA via vImage (+DEBUG assert), integer-ms sums, `await player.seek` in `load()`, `await interaction.subjects`, per-frame autoreleasepool + 512 decode, no `canOpenURL` gating, pasteboard clear→write→open-once@0.7 s.

## Detail — concurrency & Swift 6 cost (predicted; verify with `SWIFT_VERSION=6`, `SWIFT_STRICT_CONCURRENCY=complete`)

- Non-`@MainActor` singletons `PackStore.shared`, `SettingsStore.shared` → "static property not concurrency-safe"; fix `@MainActor`.
- Non-Sendable statics: `CIContext` (`StickerFactory.swift:29`, `BackgroundRemover.swift:40`, `MaskEditor.swift:502`), `vImage_CGImageFormat?` (`WebPAnimationEncoder.swift:50`); fix Sendable box / per-task instances.
- Closures crossing isolation: `FrameExtractor.swift:132-139` (captures non-Sendable `onProgress`, returns `[Frame]`); `StickerFactory.swift:304-326` (`withCheckedContinuation` + `Task.detached` + `ResumeOnce` NSLock); `BackgroundRemover.swift:67-121` (continuation resumed from `DispatchQueue.global`).
- Observer closures mutating `@State`: `VideoTrimView.swift:454-474,480-503,572-575`; `PlaybackModel` not `@MainActor`.
- `asyncAfter` + `assumeIsolated` (`WhatsAppExporter.swift:131-136`) → replace with `Task { @MainActor in try? await Task.sleep(...) }`.
- Cost: mostly mechanical; risky spots are continuation boundaries (need `sending`/region isolation or `@unchecked Sendable` wrappers) and `PlaybackModel` observers. ~1–2 days incl. CI job.

## Detail — memory budget

| Scenario | Estimate |
|---|---|
| 10 s 4K extraction (240×512² RGBA) | ~240 MB |
| `prepare()` redraw (original + prepared) | **~480 MB peak** |
| Encoder | ~5–15 MB |
| 48 MP photo import | ~200–350 MB transient, off-main |
| Editor (1024² base + mask + instances) | ~5–15 MB |
| Undo (20 snapshots, byte-capped 96 MB; excludes shared base) | ≤96 MB |
| Filmstrip (16×≤512²) | ~16 MB |

Cheap first win for P0-2: skip redraw when already 512²/.up; release source array before the ladder.

## Detail — performance

- **packs.json rewrite**: 30 stickers × (~500 KB webp + ~200 KB png) ≈ 21 MB → ~28 MB JSON re-encoded + atomically written on main per rename/emoji/move. Both a hitch and the root of P0-1.
- **Encode (10 s)**: 240 frames; q80 usually succeeds for low-motion (~1–3 s); high-motion may walk 3–9 attempts (tens of seconds), no cancel (P1-4/P2-5). `minimize_size=true` costs speed.
- **Main-thread sync I/O**: archive import/export, source decode, storage summary (P1-6/P1-10).
- **Filmstrip**: 16 sequential generators (P3-5). **Preview decodes**: PNG on main per render (P2-11). **MaskEditor init/union on main** (P2-19).

## Detail — persistence v2 design

```
Documents/
  packs.json            ← metadata only, atomic
  packs.json.bak        ← last known-good
  Stickers/<packID>/<stickerID>.webp
  Stickers/<packID>/<stickerID>.png   (preview)
  Sources/<uuid>.<ext>  (unchanged)
```

- v2: `{ "schemaVersion": 2, "packs": [{ id, name, publisher, folder, stickers: [{ id, kind, emojis, stickerFile, previewFile, source }] }] }`.
- **Migration (idempotent, one launch)**: decode v1 → write blobs atomically → write v2 temp → `packs.json.bak` = old → rename temp → delete backup only after read-back. On failure keep v1 + banner ("Library upgrade failed — retry").
- **Corruption recovery**: v2 → v1 → `.bak` → quarantine to `packs.corrupt-<ts>.json` + message, never silently empty.
- **Saves**: blob writes first, metadata JSON last; both throw. Storage-full → "Not enough storage — changes weren't saved", keep previous JSON.
- `StickerItem` computed accessors load blob on demand; add `schemaVersion` decode default 1.

## Detail — error inventory & silent failures

Typed `LocalizedError`s exist across services (good coverage). Gaps:
- **Silent**: `PackStore.load/save` (P0-1); `StickerSourceStore.delete` (`:147`); `SettingsStore.clearCache` (`:113`); `FrameExtractor.decodeFrames` skips failed frames but errors only if all fail; `PackArchive` optional tray reads; GIF source read (`StickerFactory.swift:61,218`); `cutOut` swallows all Vision failures (P2-2); `SubjectLiftModel.generate` error only shown when no image.
- **Unobservable**: `UIApplication.open` result (P2-4); pasteboard write has no failure signal.
- **Missing recovery actions**: retry for encode failures (queue keeps item but no "Retry"), "Replace source" for missing media (P2-3), storage-full remedy.

## Detail — edge-case matrix

| Case | Verdict | Ref |
|---|---|---|
| 0/1/2 stickers | OK: export gated (<3), counts fine | `PackEditorView.swift:61-66,192-203` |
| 30 stickers | OK: add/duplicate/queue/picker capped | `PackStore.swift:49,128`; `AddStickerSheet.swift:60-66` |
| >30 (import only) | **BUG**: accepted + persisted, header "N of 30" | P1-8 |
| Huge photos | Risk: full-res decode on main | P1-10 |
| HEIC | OK via `Data`→`UIImage`; re-encoded to JPEG source | `StickerSourceStore.swift:54-58` |
| Portrait/landscape | OK aspect-fit letterbox | `StickerEncoder.swift:297-316` |
| Rotated 0/90/180/270 | Handled by `appliesPreferredTrackTransform`; DEBUG assert | `FrameExtractor.swift:54-61`; device |
| VFR video | Nominal CFR sampling (durations forced) | `FrameExtractor.swift:123-128` |
| GIF odd delays | Clamped ≥8 ms; total rescaled ≤10 s | `FrameExtractor.swift:237` |
| GIF 1 frame | Duplicated to 2 | `FrameExtractor.swift:249-252` |
| GIF >30 frames | **BUG**: duration lost | P1-1 |
| Low storage | **BUG**: silent save failure | P0-1 |
| Interrupted import | Orphan `Sources/` file (no reconciliation) | P3-8 |
| Backgrounded mid-encode | No background task; encode lost, sources safe | P2-5 |
| WhatsApp not installed | Silent open no-op; footnote only if `canOpenURL` false | P2-4 |
| Pasteboard failure | Undetectable from code | device-only |
| Missing stored source | Editor recoverable error; Edit disabled; "Nothing was selected." phrasing poor | P2-3 |
| Corrupt/old `.wasticker` | Typed errors surfaced | `PackArchive.swift:92-98,230-241` |
| Malformed legacy pack | `invalid`; mixed kinds possible (then export-blocked) | `PackArchive.swift:230-261` |
| Live Photo in animated pack | Picker allows `.livePhotos`; may land as `.image` → commit incompatibility | `AddStickerSheet.swift:82,595-603`; device |

## Detail — re-verification of documented issues

| Claim | Verdict | Evidence |
|---|---|---|
| Photo editor `Original` restores pre-lift | **Confirmed bug** (worse than documented) | P1-2 |
| VisionKit `highlightedSubjects` timing | Code structure verifiable; behavior device-only | `SubjectLiftView.swift:342-384` |
| Per-pack single-kind enforcement | Enforced at add/UI/exporter; **hole**: imports bypass | `PackStore.swift:45-48`; `PackArchive.swift` |
| `.wasticker` round-trip | Byte/metadata round-trip tested; folder not carried; previews regenerated | `PackArchiveTests.swift:36-60` |
| Video single-static-mask cut | Confirmed; 15 s watchdog; silent fallback | `StickerFactory.swift:293-356` |
| Error 1000 race | Code matches workaround; effect device-only | `WhatsAppExporter.swift:111-137` |
| "Progress 100 % only when saved" | **Partially false**: failure path emits 1.0 | P1-3 |

## Detail — App Review risk

- **5.2.1(c) IP**: copyrighted anime icon → P0-3. No WhatsApp logo embedded; "Add to WhatsApp" referential (acceptable), but green prominent button mimics WhatsApp branding — neutralize/keep only with referential wording (P2-17).
- **4.2 minimum functionality**: real creation/editing value exists (mask tools, crop, VisionKit lift, trim, WebP encode) → defensible but category-vulnerable; lead metadata/screenshots with editing value.
- **2.1 completeness**: decorative Settings rows are the strongest exposure (P1-5). No other dead buttons/placeholders.
- **5.1.1 privacy**: no collection, on-device (verified: no network APIs). Missing `PrivacyInfo.xcprivacy` (P0-4) and no in-app privacy-policy link (P2-17).

## Detail — hardening gaps vs required direction

- Swift 6 mode off (`project.yml:26`); blockers §concurrency (P1-9).
- Warnings-as-errors/lint/coverage absent (P2-16).
- Force unwraps: 6, all safe (P3-3).
- Typed errors: good; recovery actions missing.
- Modern APIs: PhotosPicker, fileImporter, `AVAsset.load`, Observation, Transferable used; missing `MagnifyGesture` (P2-7), `.wasticker` UTType (P2-15), `os.Logger` (P2-20).
- Permissions: only camera, honest string; no photo-library permission needed; manifest missing (P0-4). No unused keys.
- No self-test mode (P2-20).

---

## Appendix A — All error strings & every swallow (from explorer)

**Error types / strings**: `BackgroundRemover.Failure` ("Couldn't find a subject to cut out."), `FrameExtractor.Failure` ("No frames found in this file." / "Couldn't read this GIF."), `StickerFactory.Failure` ("This file type isn't supported." / "Nothing was selected."), `StickerSourceStore.Failure` (same), `PackArchive.Failure` ("This isn't a valid sticker pack file." / "This pack was made with a newer version of Stickreate."), `WhatsAppExporter.Failure` ("WhatsApp isn't installed on this iPhone." — **dead, never thrown**), `StickerPack.ValidationError` ("A pack needs at least 3 stickers." / "A pack can hold at most 30 stickers." / "A pack can't mix static and animated stickers.").

**Swallowed / silent** (site → user sees nothing unless noted):
- `StickerFactory.swift:95-98` photo auto-cut → original background.
- `StickerFactory.swift:337-342` video cut Vision fail → original frames.
- `StickerFactory.swift:61,218` GIF read fail → misleading ".empty".
- `FrameExtractor.swift:42,193` thumbnail/per-frame decode → placeholder / last-frame padding.
- `BackgroundRemover.swift:102-105` per-instance mask fail → instance missing.
- `PackArchive.swift:65,156,169,198-199,212,305` cleanup/tray/entry reads → degraded previews.
- `PackStore.swift:177-184` corrupt/missing/full → empty library / silent loss.
- `StickerSourceStore.swift:99,134,137,147,176,183` → "Nothing was selected." / placeholder / litter.
- `StickerSourceStore.swift:152-168` duplicate copy fail → duplicate without source (Edit then errors).
- `SettingsStore.swift:104,113,144` → over-reported "Freed X".
- `WhatsAppExporter.swift:119-136` → "Added to WhatsApp" regardless.
- `PackStore.swift:90-91` `updateSticker` no-match → edit silently discarded after "success" Apply.
- `PackStore.swift:42,59,74,98,115,126,149,156,168` unmatched-id → silent no-op.

## Appendix B — Main-thread synchronous I/O (path:line → data)

- `PackStore.swift:177-178` decode / `:181-183` encode+write — whole library base64 (up to tens of MB), per mutation.
- `RootView.swift:82`, `LibraryView.swift:460` — whole `.wasticker`/`.stickreatepack` (MBs).
- `PackArchive.swift:82` — whole archive after export.
- `WhatsAppExporter.swift:86-107` — base64 of every sticker (~1.33× bytes) + `JSONSerialization`, on main.
- `StickerSourceStore.swift:134,137` — source JPEG / whole GIF + first-frame decode.
- `StickerFactory.swift:61,218` — whole GIF.
- `SettingsStore.swift:119-125` — recursive enum of `Documents/Sources` per Settings render.
- Body-time `UIImage(data:)` PNG decodes: `StickerCell.swift:59`, `ExportSheet.swift:90`, `AddStickerSheet.swift:238,756,817`, `ImportMediaSheet.swift:261`, `PackCard.swift:10-12`, `StickerPreviewSheet.swift:23-25`.
- `MaskEditor.swift:105-119` init seed/clean O(pixels) on main.
- `PackArchive.swift:298-302` in-memory extract per entry.

## Appendix C — Accessibility gaps (from explorer)

- Only one `.onTapGesture`-only control (`StickerCell.swift:50`) and it is fully covered (label + hint + `.isImage`/`.isButton` traits).
- **`CropOverlay` (video)** `VideoTrimView.swift:818-843`: has a label/value/hint but **no `.accessibilityAdjustableAction`** and no alternative button → VoiceOver can't change the crop.
- **Photo-editor crop rect** `StickerEditorView.swift:169-170`: **no accessibility element at all** for the crop rect (overlays are visual; output is `accessibilityHidden`) → the rect can't be perceived/adjusted by VoiceOver. Reset/Apply are labeled, but the rect is not.
- **Filmstrip adjustable action asymmetric** `VideoTrimView.swift:1014-1025`: increment/decrement only move the upper handle; lower handle / whole window can't be moved via VoiceOver.
- Stage-transition banners don't post an announcement (no `AccessibilityNotification.Announcement`).
- Fixed `font(.system(size:))` at `BackgroundChoiceView.swift:106`, `StickerPreviewSheet.swift:108`, `SubjectLiftView.swift:233`.

---

## Device-only unknowns

1. Peak memory/time for a real 10 s 4K clip (estimate ~480 MB; Instruments).
2. Whether the animated ladder fits 480 KB for motion-heavy clips (P1-4 frequency).
3. VisionKit `highlightedSubjects` timing / empty `ImageAnalyzer.Configuration([])` behavior + drag-landing accuracy.
4. Error 1000 frequency with the 0.7 s window.
5. Rotated 90/180/270 video upright + crop mapping.
6. Live Photo import in an animated pack (which content type wins).
7. Pasteboard write failure behavior (no API to observe).
8. WhatsApp-imported pack duplication (documented WhatsApp bug).
9. 48 MP photo decode at editor open (watchdog).
10. Whether the GIF duration fix changes perceived playback as expected.

## Must-not-regress guardrails

1. Normalized **top-left** 0…1 coords (mask/crop/geometry).
2. Animated WebP via **top-left RGBA** (vImage) + DEBUG self-check.
3. Integer-ms frame durations summing exactly to span.
4. Staged progress, never fake 100% (fix P1-3 without weakening `.saving`/`.done`).
5. Single-kind packs at add/export.
6. `await player.seek(...)` where awaited today; migrate fire-and-forget deliberately.
7. `await interaction.subjects`.
8. Per-frame `autoreleasepool` + ≤512 decode.
9. No `canOpenURL` gating; clear→write→open once after ~0.7 s.
10. Never auto-remove background; delete the dead `makeSticker` path that violates it.

## Top 10 (ranked)

1. **P0-1** Persistence: throwing load/save, corruption quarantine, blob migration.
2. **P0-2** 10 s clip peak memory (~2× frames in `prepare`).
3. **P0-4** `PrivacyInfo.xcprivacy` — submission blocker, cheap.
4. **P0-3** Replace the copyrighted app icon.
5. **P1-3** Remove the failure-path `onProgress(1.0)`.
6. **P1-1** GIF duration loss on downsampling.
7. **P1-2** `Original` must restore the pre-lift image.
8. **P1-5** Wire or remove decorative settings.
9. **P1-6 + P1-10** Move archive I/O and full-res decodes off main.
10. **P1-9** Swift 6 strict-concurrency pass.
Runner-up: **P1-4** animated ladder hard-failure (fix alongside P0-2).
