# Decisions

Short record of the main technical/product choices and why.

1. **XcodeGen, no committed `.xcodeproj`.** The developer works on Windows; `project.yml`
   is the source of truth and CI generates the project. Avoids unmaintainable pbxproj edits.

2. **`libwebp WebPAnimEncoder` for animated stickers** (via a small C wrapper), instead of
   `SDWebImageWebPCoder`'s per-frame static encode + mux. The latter has no inter-frame
   compression and was very slow/large. The native encoder is much faster and smaller and
   gives real per-frame progress.

3. **VisionKit `ImageAnalysisInteraction` for subject lift**, not a hand-rolled gesture.
   It is the exact Photos "press and hold to lift" interaction. The lifted cut-out is used
   **directly as the working image** (not mapped into a mask) — the alpha→mask bridge kept
   producing misaligned cuts.

4. **Video subject cut = a single shared mask** from the middle frame, applied to all
   frames. Per-frame Vision was slow and failed; the single mask is fast and **can never
   fail** (falls back to original frames). Trade-off: the cut is static across the clip.

5. **No frame-rate control.** The user does not want to manage frames. Extraction targets
   24 fps up to 240 frames; the encoder lowers quality (80/60/40) before dropping any frames.

6. **Single-kind packs (no mixing).** WhatsApp rejects a mixed pack. The app enforces one
   kind per pack and blocks adding the other kind.

7. **Generic `.wasticker` format** (ZIP + WhatsApp-compatible `contents.json` + assets)
   instead of a proprietary file, so other sticker tools can read it and we can read theirs.
   Legacy `.stickreatepack` JSON is still read.

8. **Stable pack identifier on export** (derived from `pack.id`), so re-exporting reuses the
   same identifier — acknowledging WhatsApp may still duplicate (their bug).

9. **`MaskEditor` normalized top-left coordinate convention** shared by every tool
   (`StickerGeometry`, brush, rect, lasso, crop), to eliminate the Y-offset bugs.

10. **Integer-millisecond frame durations** in the animated encoder, so the total animation
    equals the trimmed span exactly (fixes the "plays at 2×" bug).

11. **Top-left RGBA buffer** for `WebPPictureImportRGBA` (built via vImage), fixing the
    upside-down animated WebP.

12. **Staged progress** (`StickerCreationStage`) — "100%" only when the sticker is actually
    saved; the WebP step shows a real percentage.

13. **No accounts / no network.** Everything is on-device; nothing is collected.
