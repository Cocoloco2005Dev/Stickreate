# Design

## Language

- **Apple Liquid Glass (iOS 26)**, following the HIG.
- **Glass belongs to the control layer only**: tab bar, toolbars, sheets, and at most one
  floating/prominent control per screen.
- **Content stays opaque**: sticker grids, cards, thumbnails, and the editor canvas are
  never glass.
- Never glass-on-glass; never mix `.regular`/`.clear`; do not tint every control; remove
  custom bar/sheet backgrounds so the system material shows.
- **Exactly one prominent action per screen** (`.glassProminent`); secondary actions are
  `.glass` or plain.
- Semantic colors/fonts, Dynamic Type, dark mode, accessibility labels on icon-only
  controls, touch targets ≥44pt.
- **Design system:** `Stickreate/DesignSystem/` (`DS.Space`, `DS.Radius`,
  `DS.TextRole`, `DS.ColorRole`, `Haptic`, `EmptyState`/`LoadingState`). Screens use
  these tokens instead of magic numbers. See `docs/overhaul/02-design-spec.md`.
- Accent color: a coral/pink (`AccentColor` asset), tuned to `#E0264F` so it clears
  ≥4.5:1 for label text and ≥3:1 as a UI tint in both appearances (the previous
  `#FF375F` was 3.52:1). Accent is reserved for the single primary action and for
  selection — never body text, never a content surface. Editor screens (trim/crop/lift)
  use a dark scheme.

## Screens

### Library (root tab)
- Pack grid grouped by folder, `.searchable`, a folder filter.
- One-time onboarding card (3 steps) on first launch.
- Long-press a pack → context menu: **Add to WhatsApp…**, **Export Pack File…**,
  Rename, Folder…, Delete.
- Toolbar is minimal: **Filter** + **Add** (New Pack / Import…).

### Pack editor
- Numbered sticker grid; each tile shows the preview, an animated badge, a Cover badge on
  the first sticker, and the emoji badges.
- Per-tile context menu: Edit, Emojis…, Set as Cover, Duplicate, Delete (confirmed).
- Tap a tile → **large preview** sheet (`StickerPreviewSheet`) that plays animated stickers.
- Drag to reorder; header shows kind + count.
- A prominent **Add to WhatsApp** button under the header when the pack is exportable
  (accent tint, no brand-green).

### Add Stickers (queue)
- Pick media (PhotosPicker filtered by pack kind, camera, "Add from Files").
- A queue of items with thumbnails; tapping an item opens its editor. The thumbnail shows
  the **edited** result once processed. One consistent label: **"Tap to edit"**. Processed
  items have an eye button to open the large preview.

### Photo editor — "Adjust"
- Grey checkerboard canvas with pinch-zoom and drag-pan.
- Tool grid: **Intelligent Cut · Rectangle · Lasso · Crop** / **Original · Restore · Erase**.
- **Intelligent Cut** opens the VisionKit subject-lift step.
- A **Keep/Remove** equal-weight segmented mode applies to Rectangle/Lasso; Restore brings
  pixels back, Erase removes.
- **Original** restores the whole image. **Crop** applies in-editor (does not exit).
- Undo/redo; the single commit action is **Apply**; Cancel is secondary (accent color).

### Subject lift (VisionKit, Photos-like)
- `ImageAnalysisInteraction` with `preferredInteractionTypes = .imageSubject`: press and
  hold a subject exactly like the Photos app; the system shows its native highlight/lift.
- The lifted cut-out appears as a draggable thumbnail; drag it into a **"Use this subject"**
  box (or tap the button) to adopt it. The adopted cut-out becomes the editor's working
  image (transparent background), so Restore/Erase/Rectangle/Lasso/Crop refine it directly.

### Video editor
- Step 1 **Trim**: full-bleed preview (AVKit `VideoPlayer`, looping inside the selection),
  a filmstrip with a white selection window (drag the center to move, edges to resize) and
  a vertical playhead. No frame-rate control.
- Step 2 **Crop**: spatial crop rectangle over the preview (normalized, applied to all
  frames).
- Step 3 **Background**: explicit **Original** vs **Intelligent Cut** choice (default
  Original). Intelligent Cut is a single fast mask applied to all frames and can never fail
  (falls back to the original frames).
- Creation shows a staged progress card (never a fake 100%).

### Export sheet — "Add to WhatsApp"
- Shows ALL stickers in a scrollable grid; tapping one opens the large preview.
- Pack name + counts + the single **Add to WhatsApp** action (accent, not green).
- Mixed/undersized packs are blocked with a clear reason (WhatsApp requires single-kind);
  an empty pack shows a dedicated empty state.

### Settings
- Real, persisted options only: Keep original sources, Export mode, Clear cache (with freed
  size), storage summary, privacy note, app version + build.

## Editor flows (summary)

```
Photo:  pick → Adjust (Intelligent Cut / manual tools / Crop) → Apply → queue
Video:  pick → Trim → Crop → Background → create → queue
GIF:    pick → auto convert → queue
Queue:  edit each / preview / remove / Add from Files → Add N → pack
Pack:   reorder / cover / emojis / edit / duplicate / delete → Add to WhatsApp / Export file
```
