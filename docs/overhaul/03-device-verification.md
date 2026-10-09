# 03 — Real-device verification (Phase 6)

There is no way for GitHub CI to install on the physical iPhone by itself. The loop is:
CI publishes the unsigned IPA → the user sideloads via AltStore/SideStore → we drive the
device (SideTap) or the user follows the manual steps below.

## Status

- **Not performed automatically.** No signed build was installed on the iPhone during this
  overhaul, so SideTap had nothing to drive. This document is the executable checklist to run
  once the IPA from the final CI run is sideloaded.
- The DEBUG self-test can run on the simulator in CI (workflow step) and on the device via the
  launch argument `-StickreateSelfTest` (DEBUG builds only).

## Install (shortest path)

1. Get the IPA: the CI artifact `Stickreate-unsigned-ipa` on the latest run, or the GitHub Release asset on a tag.
2. Sideload with **AltStore/SideStore** (free Apple ID refreshes every 7 days).
3. Optional (recommended for one-tap updates): publish an AltStore source JSON via GitHub Pages and a
   `docs/apps.json` pointing at the release IPA. Fields required: source `name`/`identifier`/`sourceURL`;
   app `name`/`bundleIdentifier`/`developerName`/`subtitle`/`localizedDescription`/`iconURL`/`tintColor`;
   per version `version`/`buildVersion`/`date`/`downloadURL`/`size`/`minOSVersion`.
   (See `docs/build-release.md`.)

## Checklist (record a screenshot per item)

Use the same procedure whether driven by SideTap or by hand. Tick each with evidence.

- [ ] **Launch clean install** — first-run onboarding shows, no crash; offline/airplane mode still works.
- [ ] **Subject lift** — press-and-hold feels like Photos; native highlight appears; the dragged cut-out lands correctly; the fallback ("use all subjects") works when normal subjects don't populate.
- [ ] **Video orientation + duration** — test clips at 0/90/180/270, portrait and landscape: frames are upright and the exported animation duration matches the trim.
- [ ] **Animated preview** — plays, pauses, loops without a flash at the boundary.
- [ ] **Encode time** — record seconds for a 10 s clip (watch the `os.Logger` `encode` category and the DEBUG prepared-budget line).
- [ ] **Add to WhatsApp** (WhatsApp installed) — pack preview appears, no `error 1000`; note if it appears then still works.
- [ ] **WhatsApp not installed** — the export shows a clear guidance message instead of a silent no-op.
- [ ] **Export `.wasticker` → Files → re-import** — round-trips; order/bytes/emojis preserved.
- [ ] **Kill app mid-encode** — relaunch shows no corruption; a corrupt `packs.json` is quarantined + recovered (the RootView "Library problem" alert).
- [ ] **Interruptions** — backgrounding mid-encode, low storage, denied camera permission each give a clear, recoverable state.
- [ ] **Rotation, Dark/Light, Dynamic Type max, VoiceOver, Increase Contrast, Reduce Transparency, Reduce Motion, Bold Text, low-power mode.**
- [ ] **Self-test** — launch with `-StickreateSelfTest` (DEBUG build), confirm `selftest-report.json` is all-pass and read the summary.

## Device-only unknowns to resolve here

1. Peak memory + time for a real 10 s 4K clip (P0-2).
2. Whether the extended animated ladder fits ≤480 KB for motion-heavy clips (P1-4 frequency).
3. VisionKit `highlightedSubjects` timing + dragged cut-out landing (docs/status caveat).
4. `error 1000` frequency with the ~0.7 s pasteboard→open window.
5. Rotated-video upright + crop mapping.
6. Live Photo import into an animated pack (which content type wins).
7. Pasteboard write failure behavior (no API to observe).
8. WhatsApp re-import duplication (documented WhatsApp bug).

## If SideTap is unavailable or the build isn't installed

Do not fake results. Mark every item "not run — requires a sideloaded build", and hand this
checklist to the user.
