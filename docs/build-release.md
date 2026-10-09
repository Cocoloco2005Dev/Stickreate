# Build and release

## Requirements

- macOS with **Xcode 26** (iOS 26 SDK) to build locally. Not required: the project is built
  in CI and sideloaded, so the developer machine can be Windows.

## Project generation (XcodeGen)

The Xcode project is generated from `project.yml`; it is **not** committed.

```bash
brew install xcodegen
xcodegen generate
```

## Local build / archive (unsigned)

```bash
xcodebuild archive \
  -project Stickreate.xcodeproj \
  -scheme Stickreate \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath build/Stickreate.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
```

Package the `.ipa`:
```bash
mkdir -p build/ipa/Payload
cp -R build/Stickreate.xcarchive/Products/Applications/Stickreate.app build/ipa/Payload/
(cd build/ipa && zip -qry Stickreate-unsigned.ipa Payload)
```

## CI — `.github/workflows/ios.yml`

- Runs on `macos-15`, selects the newest installed Xcode.
- Installs XcodeGen, generates the project, resolves packages.
- **Runs tests** on an iPhone simulator chosen dynamically from the newest iOS runtime.
- Archives unsigned and packages `Stickreate-unsigned.ipa`.
- Uploads the IPA as an artifact; on a `release` event, attaches it to the GitHub Release.
- Version: on a tag `vX.Y.Z`, CI injects `MARKETING_VERSION` from the tag and
  `CURRENT_PROJECT_VERSION` from the run number.

## Install (no Mac required)

Sideload with **AltStore / SideStore**:

1. Install AltStore/SideStore on the iPhone.
2. Download the latest release `.ipa` (e.g. from the GitHub Releases page).
3. Open it with AltStore/SideStore — it signs with the user's Apple ID.

Notes:
- Free Apple IDs expire every 7 days (SideStore refreshes wirelessly).
- **LiveContainer**: the app runs, but OS share/open-in does not route into it, and
  `canOpenURL("whatsapp://")` returns false. Use the in-app **Import from Files** instead.

## Versioning

- `project.yml` sets a default `MARKETING_VERSION`; releases override it from the git tag.
- Current: **v0.19.0**.
