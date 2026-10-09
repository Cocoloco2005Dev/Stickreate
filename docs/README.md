# Stickreate — Documentation

Native iOS app (iOS 26, SwiftUI, Liquid Glass) to create, edit, and export **static and
animated WhatsApp stickers** from photos, videos, and GIFs.

Repository: `C:\Users\cocol\source\Stickreate`
Latest release: **v0.19.0**

## Index

| File | Contents |
|---|---|
| [architecture.md](architecture.md) | Code structure, models, services, data flow, persistence |
| [design.md](design.md) | UI/UX design language, screens, editor flows, HIG rules |
| [features.md](features.md) | Feature-by-feature description and behavior |
| [whatsapp.md](whatsapp.md) | WhatsApp constraints, import mechanism, limitations, generic format |
| [build-release.md](build-release.md) | XcodeGen, CI, unsigned IPA, AltStore/SideStore, versioning |
| [decisions.md](decisions.md) | Key technical decisions and rationale |
| [troubleshooting.md](troubleshooting.md) | Known pitfalls and how they were solved |
| [status.md](status.md) | Current state, known issues, open questions, roadmap |

## Quick summary

- **Creation**: pick photo / video / GIF → edit → the app produces a 512×512 WebP
  (static ≤100 KB, animated ≤500 KB) and keeps the original media so it can be re-edited.
- **Editing**: photo editor with Apple VisionKit subject lift ("press and hold", like
  Photos), manual cutout tools (Restore / Erase / Rectangle / Lasso), crop, and undo/redo.
  Video editor with duration trim (filmstrip), spatial crop, and optional subject cut.
- **Packs**: named, foldered, reorderable, with cover selection, emojis (≤3), duplicate,
  delete. Packs are single-kind (all static or all animated) because WhatsApp requires it.
- **Export**: imports a pack into WhatsApp via the pasteboard + `whatsapp://stickerPack`
  handshake. Also exports a generic `.wasticker` file (ZIP + `contents.json` + assets).
- **Everything on-device**: no accounts, no network, no analytics.

## Audience

This documentation is written so a different chat/model can continue the project: it
describes the intended behavior, the current implementation, the hard external
constraints (Apple/WhatsApp), and the known issues — without needing to rediscover them.
