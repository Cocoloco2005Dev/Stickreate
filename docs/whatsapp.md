# WhatsApp constraints and integration

## Hard limits (source: WhatsApp FAQ + `WhatsApp/stickers` repo)

- Each sticker is exactly **512×512 px**.
- Static sticker ≤ **100 KB**; animated sticker ≤ **500 KB** (target ≤ 480 KB for headroom).
- A pack has **3 to 30** stickers.
- A pack is **either all static or all animated — never mixed**. (WhatsApp rejects a mix.)
- Animation total duration ≤ **10 s**; each frame ≥ **8 ms**.
- Tray/cover icon: static **96×96 PNG**, ≤ **50 KB**.
- Emojis: optional, **max 3** per sticker.
- Accessibility text: ≤125 chars static / ≤255 animated.
- No automatic white border/stroke (the app never adds one — explicit user requirement).

## iOS import mechanism (official)

1. Build a JSON payload (single pack): `identifier`, `name`, `publisher`, `tray_image`
   (base64 **PNG**), `animated_sticker_pack` (only when animated), and
   `stickers[]` with `image_data` (base64 **WebP**), `emojis`, `accessibility_text`.
2. Write it to `UIPasteboard.general` under the type
   `net.whatsapp.third-party.sticker-pack`.
3. Open `whatsapp://stickerPack`; WhatsApp reads the pasteboard and shows the pack preview.

Implementation: `WhatsAppExporter.swift`.

### Error 1000

`com.third-party-stickers error 1000` is an undocumented catch-all. The observed "error,
then it works" is a pasteboard/open race. Mitigation in the app: clear the pasteboard, write,
then open after a short delay (~0.7 s), and open **once**. Do **not** gate the export on
`canOpenURL("whatsapp://")` — inside LiveContainer it returns false even though opening works.

## Limitations (important, verified)

- **Sharing a pack to another person is not possible from an app on iOS.** There is no
  third-party API, deep link, or file that triggers WhatsApp's pack share. WhatsApp has its
  own user-driven "share pack" inside the sticker panel (More → Send), which apps cannot
  invoke. Stickreate can only import a pack into the user's own WhatsApp.
- **Updating an imported pack does not work on iOS.** Re-importing with the same identifier
  creates a **duplicate** (a long-standing WhatsApp bug; there is no iOS version field). The
  practical workaround is a new identifier per revision, or deleting the old pack first.
- iOS WhatsApp does **not** open `.wasticker` files; the file is for sticker apps, which
  then push to WhatsApp via the platform API.

## Generic file format: `.wasticker`

Stickreate exports/imports a ZIP (extension `.wasticker`) so other sticker tools can read
it and vice versa:

```
pack.wasticker            (ZIP)
├── contents.json         # WhatsApp Android manifest (single pack)
├── cover.png             # 96×96 tray
├── 1.webp, 2.webp, ...   # stickers (verbatim bytes)
├── title.txt             # pack name (community .wasticker)
└── author.txt            # publisher
```

`contents.json`:
```json
{
  "android_play_store_link": "",
  "ios_app_store_link": "",
  "sticker_packs": [
    {
      "identifier": "...", "name": "...", "publisher": "...",
      "tray_image_file": "cover.png",
      "image_data_version": "1",
      "animated_sticker_pack": true,
      "stickers": [
        { "image_file": "1.webp", "emojis": ["..."], "accessibility_text": "..." }
      ]
    }
  ]
}
```

Implementation: `PackArchive.swift` (ZIPFoundation). It also reads the legacy
`.stickreatepack` JSON for backward compatibility.
