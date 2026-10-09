# Troubleshooting / pitfalls

Hard-won issues and their fixes. Useful when something breaks again.

## Video/animated orientation (upside down)

- **Symptom:** exported animated sticker (and its preview) is flipped.
- **Cause:** the RGBA buffer fed to `WebPPictureImportRGBA` was bottom-left (Core Graphics
  origin) while libwebp expects **top-left row-major**.
- **Fix:** build the buffer with `vImageBuffer_InitWithCGImage` (top-left by contract) in
  `WebPAnimationEncoder`. A `#if DEBUG` self-check asserts row 0 is the top.
- **Also:** extraction uses `AVAssetImageGenerator.appliesPreferredTrackTransform = true`.
  A custom `AVAssetReaderVideoCompositionOutput` path previously flipped frames and was
  removed.

## Animation plays too fast (2×)

- **Cause 1:** frame duration was `1/fps` while the frame count was capped → total shorter.
  Fix: `frameDuration = span / count`.
- **Cause 2:** libwebp truncates `duration * 1000` to an integer. Fix: distribute integer
  milliseconds across frames so the sum equals the requested span exactly.

## Progress stuck at 100% / no percentage for WebP

- Progress is staged (`StickerCreationStage`). "100%" is only emitted after the sticker is
  saved. The WebP compression reports a real percentage across its attempts.

## WhatsApp `error 1000`

- Undocumented catch-all; the "error then works" is a pasteboard/open race.
- Fix: clear the pasteboard, write, then open `whatsapp://stickerPack` after ~0.7 s, once.
- Do **not** gate on `canOpenURL("whatsapp://")` (false in LiveContainer).

## `PhotosPickerItem` "cannot find type in scope"

- It needs `import SwiftUI` in the file (not just `PhotosUI`).

## `AVPlayer` "expression is 'async' but is not marked with 'await'"

- On iOS 26 `AVPlayer.seek(to:toleranceBefore:toleranceAfter:)` resolves to the async
  overload; use `_ = await player.seek(...)`.

## VisionKit `subjects` access errors

- `ImageAnalysisInteraction.subjects` is **async** and main-actor isolated: read it with
  `await interaction.subjects` (not inside a synchronous `MainActor.run`).
- `highlightedSubjects` is synchronous but main-actor; access it on the main actor.

## Selection offset (rectangle/lasso off by ~20 px)

- Root cause: `MaskEditor` must use one convention. Everything is **top-left normalized**;
  do not apply an extra Y flip in the view. (A double-flip once mirrored the selection.)

## Video frames out of memory / crash

- Never hold full-resolution video frames. Decode at `maximumSize = 512` and scale to the
  sticker canvas; use `autoreleasepool` per frame.

## LiveContainer specifics

- OS share/open-in does not route into the app; `canOpenURL("whatsapp://")` is false.
- Use the in-app **Import from Files** and attempt the WhatsApp open unconditionally.

## `.wasticker` import/export

- Export: ZIP with `contents.json` (WhatsApp manifest) + `cover.png` + `N.webp` + txt files.
- Import accepts `.wasticker` (new) and `.stickreatepack` (legacy JSON). `RootView` and
  `LibraryView` must both route those extensions to `PackArchive.importPack`.
