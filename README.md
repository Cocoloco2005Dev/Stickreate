# Stickreate

A native iPhone app to create **static and animated WhatsApp stickers** quickly, with
automatic background removal. Built with SwiftUI and Apple's **Liquid Glass** design
language (iOS 26).

Stickers follow WhatsApp's rules exactly:

- 512 × 512 px, transparent background, **no white border**
- static packs `3–30`, ≤ 100 KB each
- animated packs `3–30`, ≤ 500 KB each, ≤ 10 s total, ≥ 8 ms per frame
- never mixing static and animated stickers in one pack
- tray icon 96 × 96 PNG, ≤ 50 KB

## Install (no Mac required)

The app is built in CI as an **unsigned `.ipa`** and sideloaded with AltStore / SideStore.

1. Install [AltStore](https://altstore.io) or [SideStore](https://sidestore.io) on your iPhone.
2. Open the latest **Release** on this repo and download `Stickreate-unsigned.ipa`
   (or grab it from the `Stickreate-unsigned-ipa` artifact of a workflow run).
3. Open the `.ipa` with AltStore/SideStore — it signs with your own Apple ID and installs.

> Free Apple IDs expire every 7 days; SideStore refreshes wirelessly.

## Build

The Xcode project is **generated**, never committed. `project.yml` is the source of truth.

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Stickreate.xcodeproj -scheme Stickreate \
  -configuration Release -destination "generic/platform=iOS" build
```

Requires **Xcode 26** (iOS 26 SDK) and a deployment target of **iOS 26.0**.

## Layout

```
project.yml                     # XcodeGen spec (source of truth)
Stickreate/
  StickreateApp.swift
  RootView.swift                # Liquid Glass tab bar
  Models/                       # StickerPack, StickerItem, limits
  Services/                     # encoding, Vision, WhatsApp export
  Features/                     # Library, Settings
  Resources/Assets.xcassets
.github/workflows/ios.yml       # CI: unsigned .ipa
```

## Privacy

Everything runs on-device. Background removal uses Apple's Vision framework. The app
makes no network requests and collects nothing.
