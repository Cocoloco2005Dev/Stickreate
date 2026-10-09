# 04 — App Store readiness (Phase 7)

Legend: ✅ done · ❌ must fix before submission · 🙋 needs the user (account, hosting, decision).

Sources: current App Review Guidelines, Apple HIG, Privacy Manifest docs, WhatsApp sticker spec
(see `docs/overhaul/00-ground-truth.md` §11).

## Privacy

| Item | Status | Notes |
|---|---|---|
| `PrivacyInfo.xcprivacy` in the app | ✅ | Declares `NSPrivacyTracking=false`, no collected data, and only the required-reason APIs actually used: UserDefaults `CA92.1`, FileTimestamp `C617.1`. A CI step now fails the build if the manifest is missing/invalid in the IPA. |
| Third-party SDK manifests | ✅ | SDWebImage ships its own manifest (Apple-required SDK). ZIPFoundation ships one (`0A2A.1`). `libwebp-Xcode` is a source package using no required-reason APIs → none needed. |
| App Privacy "nutrition label" answer | ✅ (draft) | **Data Not Collected**; no tracking; on-device only (no network APIs in code). |
| Privacy Policy text | 🙋 | Drafted in `docs/legal/privacy-policy.md`; user hosts it and pastes the URL into App Store Connect. |
| Privacy Policy link in-app | ❌ | Add a Settings row linking to the hosted policy (blocked on the URL). |
| Support URL page | 🙋 | Drafted in `docs/legal/support.md`; user hosts it. |

## Info.plist

| Item | Status | Notes |
|---|---|---|
| `CFBundleDisplayName` | ✅ | Stickreate. |
| Orientations / devices | ✅ | Portrait only, `TARGETED_DEVICE_FAMILY=1`, `UIRequiresFullScreen` — consistent. |
| `NSCameraUsageDescription` | ✅ | Specific, honest: "Take a photo to turn it into a sticker." |
| Unused permission keys | ✅ | No photo-library / mic keys (PhotosPicker + stills-only camera). |
| `.wasticker` document type / UTType | ❌ | Not declared (`CFBundleDocumentTypes` currently only `public.image`/`public.movie`); add an exported UTType so Files/Open-In associates `.wasticker`. Also reconciles the naming risk (our `.wasticker` is a ZIP; WhatsApp's official `.wasticker` is JSON) — own the UTI. |
| `ITSAppUsesNonExemptEncryption` | ✅ | `NO` — ZIP = compression, WebP = encoding; no non-exempt encryption. |
| `LSApplicationQueriesSchemes` | ✅ | `whatsapp` only, for an informational check (export is never gated on it). |
| Launch screen | ✅ | Storyboard-less `UILaunchScreen`. |

## Review guidelines

| Guideline | Status | Notes |
|---|---|---|
| **4.2 Minimum Functionality** | ✅ (defensible) | Real creation/editing value (Vision subject lift, manual cutout, crop, video trim, animated WebP encode). WhatsApp itself warns a bare "export" app is vulnerable — so lead the App Store metadata + screenshots with the **editor**, not with "add to WhatsApp". |
| **5.2.1 IP / trademarks** | ❌ + 🙋 | **App icon is third-party copyrighted art (Urusei Yatsura / Lum) — must be replaced with owned/licensed art (user decision: currently kept).** No WhatsApp logo is embedded and "Add to WhatsApp" is referential wording only; brand-green was removed from prominent buttons. Add the user-content disclaimer below. |
| **1.2 User-Generated Content** | ✅ | Not applicable: content is local-only; no server, no sharing service → no moderation/reporting required. |
| **2.1 App Completeness** | ✅ | Decorative toggles removed; no placeholders/dead buttons; export blocks with reasons. |
| **5.1.1 Privacy / permissions in context** | ✅ + ❌ | Camera rationale shown before requesting; permission requested in context. The in-app privacy-policy link is still missing (see above). |
| **4.0 / accessibility** | ✅ | Labels/hints/traits, 44pt targets, Dynamic Type to AX sizes, adjustable crop/filmstrip; `performAccessibilityAudit` in UI tests (Phase 5). |

## App icon, launch, screenshots, metadata

- App icon: 🙋 replace the artwork; then confirm the 1024 asset is opaque (no alpha) and un-rounded.
- Screenshots: 🟡 generate from UI tests (6.9" + required sizes) — planned in Phase 5.
- Metadata (name/subtitle/keywords/description EN + ES), age rating, category, and **review notes**
  (how to test without WhatsApp installed, no login required): 🙋 drafts needed — see below.

## Signing & submission

- 🙋 A **free Apple ID cannot submit to the App Store.** Needs: Apple Developer Program membership,
  an App Store Connect record, certificates/profiles (or Xcode Cloud / fastlane + an App Store Connect
  API key in GitHub Secrets).
- Optional: a fastlane / Actions TestFlight upload job, disabled until the secrets exist.

## Pre-flight (final pass)

- [ ] Crash-free cold launch on a clean install.
- [ ] Works offline / in airplane mode.
- [ ] Works with permissions denied.
- [ ] Works after a data wipe.
- [ ] No private APIs (`otool`/symbol check) — none used (public Vision/VisionKit/libwebp/SDWebImage only).
- [ ] No debug/self-test code in Release (self-test is `#if DEBUG`; verify the IPA).
- [ ] `PrivacyInfo.xcprivacy` present in the IPA (CI-enforced).

## Draft metadata (EN / ES)

- Name: Stickreate. Subtitle: "Sticker maker for WhatsApp" / "Creador de stickers para WhatsApp".
- Category: Graphics & Design (primary). Age rating: 4+ (no objectionable content; user-supplied media).
- Keywords: sticker maker, sticker, WhatsApp, animated, cutout, pack.
- Review notes: on-device only, no login, no network; to test, create a sticker from a photo and use
  "Add to WhatsApp"; the `.wasticker` export works without WhatsApp installed.

## Review notes for the reviewer (draft)

> Stickreate creates WhatsApp sticker packs fully on-device. No account, no network. To test:
> create a pack (Library → +), add a photo (edit it with Intelligent Cut / crop), then add another
> so the pack has ≥3, and tap "Add to WhatsApp" to see the pack preview. The app also exports a
> `.wasticker` file (share sheet) which works even without WhatsApp installed. Camera is optional.
