# Status

## Current

- **Version: 0.20.2** (overhaul branch merged to `main`).
- CI (`.github/workflows/ios.yml`) builds, runs unit tests, archives an unsigned IPA, and uploads
  artifacts: `.xcresult` (with screenshots), `selftest-report.json`, the IPA; it also runs the DEBUG
  self-test on the simulator, verifies the Privacy Manifest is bundled, and writes a job summary.
- Fully on-device. No network, no accounts, no analytics.

## What works

- Create static stickers from photos (VisionKit subject lift, manual cutout, crop).
- Create animated stickers from videos (trim, spatial crop, optional subject cut) and GIFs (delays preserved).
- Packs: create/rename/folder/reorder/cover/duplicate/emoji/delete; persisted locally with corruption recovery.
- Re-edit saved stickers; "Keep original sources" setting controls whether sources are kept.
- Add to WhatsApp (pasteboard + deep link) and Export/Import a generic `.wasticker`.
- Camera capture; Import from Files; share/open-in on a normal install.
- DEBUG self-test (launch arg `-StickreateSelfTest`) + hidden debug screen; `os.Logger` categories.
- Localization: String Catalog `en` + `es` (249 strings). Design-system state components still take
  `String` (they localize once switched to `LocalizedStringKey`).

## Fixed in this overhaul

- **Persistence (P0-1)**: corrupt `packs.json` is quarantined and recovered from `packs.json.bak`;
  atomic writes; errors surfaced (no silent library wipe / silent save loss); `removePack` deletes sources.
- **Encoder progress (P1-3)**: never reports 100% on failure.
- **Privacy Manifest (P0-4)**: `PrivacyInfo.xcprivacy` added and CI-verified in the IPA.
- **GIF duration (P1-1)**: downsampling preserves total duration.
- **Animated ladder (P1-4)**: extended so motion-heavy clips encode instead of failing.
- **`Original` semantics (P1-2)**: after a subject lift, `Original` restores the pre-lift photo (with confirmation).
- **Import validation (P1-8)**: count/kind/byte caps (ZIP-bomb guard); orphaned sources reconciled on launch.
- **Settings (P1-5)**: dead toggles removed; "Keep original sources" is real and wired at commit.
- **Design (Phase 3)**: DesignSystem tokens + Liquid Glass used on the control layer only; accessible
  accent `#E0264F`; shared empty/loading/success states; crop/filmstrip are VoiceOver-adjustable;
  `MagnifyGesture`; awaited `player.seek`; Reduce Motion respected.
- **Tests**: geometry, encoder budget, frame timing, `.wasticker` round-trip, import validation,
  persistence recovery, GIF duration, MaskEditor restore.
- **Perf**: archive I/O moved off the main actor; `storageSummary` cached; safer `clearCache`.

## Known issues / caveats

- **P0-2 peak memory is only partially mitigated.** Frames already 512×512 are passed through and the
  preview source is released before encoding, but a full single-resident fix needs an ownership
  refactor (`StickerFactory` → `StickerEncoder` `inout`/`consume`) plus device measurement. A 10 s clip
  can still peak high.
- **App icon is third-party copyrighted art** (user decision: kept for now) — must be replaced before submission (App Review 5.2.1).
- **Swift 6 language mode / warnings-as-errors are NOT enabled** (deferred — needs iterative CI).
- **Video subject cut is a single static mask** (applied to all frames); fast and cannot fail, but the cutout doesn't follow motion.
- **Sharing a pack to another person** is impossible from an app on iOS.
- **Updating an imported pack duplicates it** (WhatsApp bug, no iOS version field).
- **`error 1000`** is a pasteboard/open race; mitigated by clear → write → open once after ~0.7 s.
- **`.wasticker` naming risk**: our format is a ZIP; WhatsApp's official `.wasticker` is JSON. An own
  UTType is still to be declared.
- **LiveContainer**: share/open-in doesn't route in; use in-app Import from Files.
- **Free Apple ID** sideloads expire every 7 days.

## Needs device verification (see `docs/overhaul/03-device-verification.md`)

10 s 4K encode time + peak memory; VisionKit lift feel + landing; animated preview loop; WhatsApp
import (error 1000 frequency); `.wasticker` Files round-trip; mid-encode kill; rotation/Dark/Light/
Dynamic Type max/VoiceOver.

## Roadmap

- P0-2 ownership refactor + device measurement.
- Declare a `.wasticker` UTType; `fileImporter` uses it.
- Switch design-system components to `LocalizedStringKey` so their Spanish translations resolve.
- Enable Swift 6 mode + warnings-as-errors once CI can iterate.
- Replace the app icon with owned art.
- Optional: `minimize_size = false` for ~2× encode speed at some size cost.

## Recent history (high level)

- **0.20.2** — cut-out stickers **auto-fit to fill the canvas** (crop to the subject's alpha bounds, contain — never cropped), uniform across video frames (no jitter). Intelligent Cut runs **per frame** (stride 1, was 3). **One continuous, monotonic progress bar** across extraction → cut → compression (no more 3%→100% jumps) and **Cancel** that actually stops the pipeline. Standardized navigation/action placement (one prominent action per screen, consistent Back/Cancel) and added density in Library/Pack editor/Export.
- **0.20.1** — video Intelligent Cut follows motion; multi-subject Lift Subject with preview + Original toggle; GIFs editable (trim/crop/background).
- **0.20.0** — design overhaul (DesignSystem + Liquid Glass + accessibility), persistence safety,
  privacy manifest, P1 fixes, self-test mode, CI hardening, localization.
- 0.19.0 — reliable animated preview; subject lift uses the cut-out directly; generic `.wasticker`.
- 0.18.0 — animated preview playback; subject-lift cut-out; `.wasticker` format.
- Earlier — Liquid Glass shell, editors, CI, AltStore releases, app icon, settings, tests.
