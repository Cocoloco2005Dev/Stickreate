# Status

## Current

- **Latest release: v0.19.0.** Builds and tests pass in CI (`.github/workflows/ios.yml`).
- Fully on-device. No network, no accounts.

## What works

- Create static stickers from photos (with VisionKit subject lift, manual cutout, crop).
- Create animated stickers from videos (duration trim, spatial crop, optional subject cut)
  and GIFs.
- Packs: create/rename/folder/reorder/cover/duplicate/emoji/delete; persisted locally.
- Re-edit saved stickers (source stored).
- Add to WhatsApp (pasteboard + deep link) and Export/Import a generic `.wasticker`.
- Camera capture; Add from Files; share/open-in on a normal install.

## Known issues / caveats

- **Video subject cut is a single static mask** (applied to all frames). Fast and cannot
  fail, but the cutout does not follow motion. (Per-frame was too slow/unreliable.)
- **Sharing a pack to another person is not possible** on iOS from an app (see whatsapp.md).
- **Updating an already-imported pack duplicates it** (WhatsApp bug, no iOS version field).
- **VisionKit subject-lift timing** (`highlightedSubjects` populating after press-and-hold)
  has not been verified on a physical device; a fallback ("use all subjects") exists.
- **LiveContainer**: share/open-in does not route in; use in-app Import from Files.
- **Free Apple ID** sideloads expire every 7 days.
- The photo editor's `Original` restores the current working image (which may already be a
  cutout), not necessarily the original pre-lift photo — revisit if that matters.

## Needs device verification

- Video: upright orientation and correct duration on real clips (multiple rotations).
- Animated sticker preview: plays/pauses and loops.
- Subject lift: feels like Photos; the dragged cut-out lands correctly.
- Add to WhatsApp: pack preview appears; error 1000 is rare.
- Performance: WebP encode time for a 10 s clip.

## Roadmap / open questions

- Decide whether to auto-use a new identifier per export (avoids stale/duplicate packs but
  creates duplicates in WhatsApp).
- Consider `minimize_size = false` in the WebP encoder for ~2× speed at some size cost.
- Expand unit tests (mask cleanup, encoder budget edge cases, `.wasticker` round-trip).
- Optional: move binary sticker blobs out of `packs.json` into per-sticker files.

## Recent history (high level)

- v0.18.0 — reliable animated preview playback; subject lift uses the cut-out directly;
  generic `.wasticker` format.
- v0.17.0 — keep more video frames; AVKit preview; export shows all stickers; share via
  WhatsApp import.
- v0.16.0 — animated WebP orientation (vImage top-left); per-frame video cut; re-ban mixing;
  VisionKit subject lift.
- Earlier — Liquid Glass shell, editors, CI, AltStore releases, app icon, settings, tests.
