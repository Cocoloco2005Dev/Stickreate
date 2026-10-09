# Features

## Sticker creation

- **From photo** — pick a photo, edit it (subject lift, cutout tools, crop), get a 512×512
  static WebP (≤100 KB).
- **From video** — trim the duration, crop spatially, optionally cut the subject, get an
  animated WebP (≤500 KB, ≤10 s).
- **From GIF** — converted automatically to animated WebP (delays preserved where possible).
- **From camera** — take a photo and edit it like any photo.
- **From Files** — import an image/video/GIF from the Files app (works even where the OS
  share/open-in does not route into the app, e.g. LiveContainer).

## Editing

- **Subject lift (Intelligent Cut)** — Apple VisionKit `ImageAnalysisInteraction`; press and
  hold a subject like the Photos app, then drag the lifted subject into a box to use it.
- **Manual cutout** — Restore (bring pixels back), Erase, Rectangle, Lasso, with a
  Keep/Remove mode; live mask preview; undo/redo.
- **Crop** — crop the image in-editor without leaving the editor.
- **Video** — duration trim (filmstrip), spatial crop, background choice.
- **Re-edit** — any sticker with a stored source can be reopened and edited in place.

## Packs

- Create, rename, folder, delete.
- Reorder by drag; choose a cover; duplicate stickers; emojis (≤3 per sticker).
- Single-kind packs (all static OR all animated) — enforced, matching WhatsApp.
- Packs persist locally and survive relaunch.

## Export & sharing

- **Add to WhatsApp** — imports the pack into WhatsApp's sticker tray (pasteboard +
  `whatsapp://stickerPack`), which opens WhatsApp's pack preview with the built-in "Add".
- **Export Pack File** — writes a generic `.wasticker` (ZIP + `contents.json` + assets).
- **Import** — reads `.wasticker` (and the legacy format) from Files or via Open-In.

## Privacy

- Fully on-device. No accounts, no network requests, no analytics. Subject lifting and all
  image processing use Apple frameworks locally.

## Not supported (external limits, see whatsapp.md)

- Sharing a pack directly to **another person** so they get WhatsApp's "Add" — not possible
  from a third-party app on iOS.
- **Updating** an already-imported pack in WhatsApp — re-importing duplicates it.

## Changes in 0.20.0

- **Keep original sources** (Settings) — when off, new stickers don't store the original media and
  therefore can't be re-edited; when on, they can (default).
- **Localization** — English + Spanish String Catalog (249 strings). Some design-system state
  components still show English until they adopt `LocalizedStringKey`.
- **Corruption recovery** — an unreadable library is quarantined and restored from a backup instead
  of silently appearing empty.
- **DEBUG self-test** — launch with `-StickreateSelfTest` (DEBUG builds) to run an on-device
  end-to-end check and write `selftest-report.json`.
