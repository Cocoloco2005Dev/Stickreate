# Architecture

## Stack

- **SwiftUI**, deployment target **iOS 26.0** (Liquid Glass), built with **Xcode 26**.
- Project is **generated** by **XcodeGen** from `project.yml` (the `.xcodeproj` is never
  committed — this lets the project be edited on Windows and built in CI).
- Swift Package Manager dependencies:
  - `SDWebImage` + `SDWebImageWebPCoder` — static WebP encode/decode.
  - `libwebp` (SDWebImage/libwebp-Xcode) — used directly for the animated WebP encoder.
  - `ZIPFoundation` — read/write the `.wasticker` pack container.

## Source layout

```
Stickreate/
  StickreateApp.swift        App entry
  RootView.swift             Tab shell (Packs / Settings) + onOpenURL for shared files
  Models/
    StickerPack.swift        Pack: id, name, publisher, stickers, folder
    StickerItem.swift        Sticker: id, kind, emojis, stickerData (WebP), previewData (PNG), source
    StickerSource.swift      Original media reference: .image/.video/.gif(fileName:)
    StickerKind.swift        .static / .animated
    Frame.swift              One animation frame (UIImage + duration)
    VideoDraft.swift         Loaded video (url + duration)
    Limits.swift             WhatsApp numeric limits
    PackStore.swift          @Observable store; owns packs; persists; static shared
    SettingsStore.swift      @Observable settings; UserDefaults; static shared
    StickerCreationStage.swift  Progress model (loading/extracting/cutting/compressing/saving/done)
  Services/
    StickerFactory.swift     Orchestrates pick → frames/image → cut → encode → StickerItem
    StickerEncoder.swift     Static WebP + animated WebP (budget/quality/frames)
    WebPAnimationEncoder.swift  libwebp WebPAnimEncoder wrapper (C interop)
    FrameExtractor.swift     Video/GIF → frames (AVAssetImageGenerator, 512px, oriented)
    BackgroundRemover.swift  Vision subject lift (mask + per-instance masks)
    MaskEditor.swift         Editable keep/remove mask (brush, rect, lasso, crop, undo/redo)
    StickerSourceStore.swift Original media on disk (Documents/Sources)
    PackArchive.swift        Generic `.wasticker` ZIP export/import
    WhatsAppExporter.swift   Pasteboard + whatsapp://stickerPack import
  Features/
    Library/                 LibraryView, PackCard, ImportMediaSheet
    Editor/                  PackEditorView, StickerCell, StickerPreviewSheet,
                             AddStickerSheet, StickerEditorView, SubjectLiftView,
                             VideoTrimView, BackgroundChoiceView, EmojiPickerSheet,
                             FolderPickerSheet, ActivityView, CameraPicker
    Settings/                SettingsView
  Resources/Assets.xcassets  AppIcon (from user image), AccentColor
StickreateTests/             XCTest unit tests (geometry, archive, validation, settings, encoder)
.github/workflows/ios.yml    CI: tests + unsigned IPA
docs/                        This documentation
```

## Data flow (create a sticker)

1. **Pick** — `PhotosPicker` (kind-filtered by the pack) or camera or "Add from Files".
2. **Persist source** — `StickerSourceStore.importPicked(_:)` / `importFile(at:)` copies the
   original into `Documents/Sources/<uuid>.<ext>` and returns a `StickerSource`.
3. **Edit**:
   - Photo → `StickerEditorView` (checkerboard canvas, `MaskEditor`, VisionKit subject lift).
   - Video → `VideoTrimView` (trim → crop → background).
   - GIF → auto (no editor).
4. **Encode** — `StickerFactory.encodeStatic(_:source:)` or
   `makeAnimatedSticker(from:range:fps:removeBackground:cropRect:source:onProgress:onStage:)`
   → a `StickerItem` with `stickerData` (WebP), `previewData` (512 PNG) and the `source`.
5. **Add** — `PackStore.shared.add(_:to:)`.
6. **Export** — `WhatsAppExporter.export(...)` (pasteboard + deep link).

## Persistence

- `Documents/packs.json` — the packs, `Codable` (includes base64 `stickerData`/`previewData`).
- `Documents/Sources/<uuid>.<ext>` — original media for re-editing.
- `UserDefaults` (`stickreate.*`) — `SettingsStore`.

## Concurrency

- Vision, frame extraction, and encoding run off the main actor (`Task.detached`,
  `autoreleasepool` per frame).
- Progress is modeled by `StickerCreationStage` and delivered on the main queue.
- `MaskEditor` is `@MainActor @Observable`; it composites previews off-main and publishes
  with a generation guard against out-of-order updates.

## Key invariants

- Sticker canvas is always exactly **512×512**.
- The mask/selection coordinate convention is **normalized, top-left, 0…1** everywhere
  (`StickerGeometry`, `MaskEditor`, `applyCrop`, `render(croppedTo:)`).
- Animated WebP frame durations are distributed as **integer milliseconds** so the total
  duration equals the trimmed span exactly (no speed-up).
- The animated encoder's RGBA buffer is **top-left row-major** (vImage), because libwebp
  expects row 0 = top row.
