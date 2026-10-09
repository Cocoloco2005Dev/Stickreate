# 02 — Design Spec (Phase 3)

Reskin + HIG correction for the **library/pack surfaces** of Stickreate, and the
introduction of a small design system. This is a visual and correctness pass —
the information architecture (Library → Pack editor → Add queue → Photo/Video
editors → Export) is unchanged.

Sources: `docs/overhaul/00-ground-truth.md`, `docs/overhaul/01-audit.md`, Apple
HIG / Liquid Glass (iOS 26). No Xcode on this machine: everything below is
source-level and must be confirmed by CI/device.

---

## 1. Design system

New module `Stickreate/DesignSystem/` (auto-included by `project.yml`'s
`sources: - path: Stickreate`). Deliberately thin: it standardizes *choices*,
it does not re-implement SwiftUI.

| File | Contents |
|---|---|
| `Tokens.swift` | `DS.Space`, `DS.Radius`, `DS.Motion`, `DS.minTapTarget` |
| `Typography.swift` | `DS.TextRole` — semantic `Font` roles |
| `ColorRoles.swift` | `DS.ColorRole` — accent + the few surfaces we own |
| `Haptics.swift` | `Haptic` + `.haptic(_:trigger:)` over `.sensoryFeedback` |
| `StateViews.swift` | `EmptyState`, `LoadingState`, `SuccessLabel`, `StatusBanner` |

### Spacing — `DS.Space`

| Token | pt | Used for |
|---|---|---|
| `xxs` | 2 | badge insets |
| `xs` | 4 | tight vertical gaps, thumbnail padding |
| `sm` | 8 | inline gaps, grid item spacing |
| `md` | 12 | row gaps, section header→content |
| `lg` | 16 | screen edge padding, grid spacing |
| `xl` | 20 | sheet inner padding |
| `xxl` | 24 | sheet section spacing |
| `section` | 24 | between stacked groups in a scroll view |

The scale keeps the 4/8/12/16/20/24 rhythm the app already used, so the reskin
stays visually continuous.

### Radii — `DS.Radius`

`badge` 10 · `thumb` 12 · `tile` 16 · `card` 20 · `pill` 999. All shapes use
`.continuous`.

### Type — `DS.TextRole` (Dynamic Type safe)

`screen` (title2 semibold) · `section` / `cardTitle` (headline) · `body` ·
`supporting` (subheadline) · `footnote` · `caption` · `badge` (caption2 bold).

Every role is a **system text style** — never `.system(size:)` — so Dynamic Type
including the largest accessibility sizes keeps working. Owned screens no longer
contain a single fixed point size.

### Color — `DS.ColorRole`

Rule: **accent is reserved for the single primary action and for selection.** It
is never body text and never a content surface. iOS semantic colors cover
everything else (backgrounds, labels, separators); we do **not** ship a parallel
palette for those.

| Role | Value | Use |
|---|---|---|
| `accent` | `AccentColor` | primary action tint, selection |
| `contentSurface` | `.secondarySystemBackground` | opaque cards / tiles (never glass) |
| `contentSurfaceRaised` | `.systemBackground` | small overlays on media |
| `mediaScrim` | black @ 55% | text/badges drawn over thumbnails |
| `positive` | `accent` | transient success; deliberately **not** a brand-green |

### Motion — `DS.Motion`

`quick` (.snappy 0.22) · `standard` (.snappy 0.32) · `gentle` (.smooth 0.35) ·
`confirmationHold` 2 s. Springy and interruptible. Every animation site checks
`accessibilityReduceMotion` and passes `nil` when it is on.

### Haptics

`Haptic.selection | .success | .warning | .error | .impact` mapped to
`.sensoryFeedback`, attached with `.haptic(_:trigger:)`. Used for selection,
import success, export success, delete errors and drag-reorder.

---

## 2. Accent color — justified change

Current asset was coral/pink `#FF375F` (light) / `#FF4F73` (dark). Measured
against WCAG:

| Color | vs white | white label on it | verdict |
|---|---|---|---|
| `#FF375F` (old light) | 3.52:1 | 3.52:1 | **fails 4.5:1** |
| `#FF4F73` (old dark) | — | 3.17:1 | **fails 4.5:1** |

Because the accent is used as a fill behind white label text (prominent buttons,
onboarding numerals, the Cover badge) and as a tint for selection, it must clear
4.5:1 for label text and 3:1 as a UI tint. The old coral did not.

The accent is kept in the same coral/pink family (hue ≈ 347°, was ≈ 348°) but
tuned darker to a single value:

**`#E0264F` = sRGB(0.878, 0.149, 0.310)** — universal (light + dark).

| Pairing | Ratio | Bar |
|---|---|---|
| white label **on** accent | **4.61:1** | ≥4.5 text ✓ |
| accent text **on** white | **4.61:1** | ≥4.5 text ✓ |
| accent **on** light surface `#F2F2F7` | 4.12:1 | ≥3 UI ✓ |
| accent **on** dark surface `#1C1C1E` | 3.70:1 | ≥3 UI ✓ |
| white label on accent, both appearances | 4.61:1 | ≥4.5 ✓ |

One value is used in both appearances on purpose: any brighter dark-mode value
would drop white-label contrast below 4.5:1, and a second value would break the
"prove it in both appearances" requirement. Accent is **never** rendered as
small text on a dark surface (that pairing is 3.70:1), which is why the rule
above matters.

---

## 3. Liquid Glass, done right

- Glass stays in the **control layer only**: the system tab bar (`RootView`),
  navigation bars, toolbars, sheets, menus. Content (grids, cards, tiles,
  thumbnails, palette) is opaque.
- **No custom bar/sheet backgrounds.** The only custom material in the owned
  screens was the library's full-screen `.ultraThinMaterial` import scrim — it is
  gone, replaced by the shared `LoadingState` rendered as content.
- **Exactly one `.glassProminent` per screen state.** Verified:

  | Screen | prominent | secondary |
  |---|---|---|
  | Library | empty: *New Pack*; filtered-empty: *Show All Packs* | *Import…* plain, toolbar menus |
  | Pack editor | empty: *Add Sticker*; ready: *Add to WhatsApp* | options menu |
  | Import sheet | empty: *New Pack*; list: *Add to \<pack\>* | Cancel |
  | Export sheet | *Add to WhatsApp* | Done |
  | Folder picker | *Save* | Cancel |
  | Emoji picker | *Save* | *Add* (`.glass`) |

- **No tint overrides.** `.tint(.green)` (WhatsApp mimicry) and
  `.tint(Color.accentColor)` on secondary controls were removed; prominent
  buttons use the app accent implicitly. This is also the "don't tint every
  control" fix.
- **No `.glassEffect` / `GlassEffectContainer` added.** No owned screen has a
  custom floating control that needs a hand-built glass surface; the system
  materials already cover every control. Adding one would be sprinkling, not
  design.

---

## 4. Per-screen redesign

### RootView (shell)
Tab bar is the system floating glass element; kept
`.tabBarMinimizeBehavior(.onScrollDown)`. Added success/error haptics on
incoming-file import. Two alerts kept (library problem, could-not-open).

### Library
- Grid regrouped by folder with `DS` spacing; section headers use
  `DS.TextRole.section`.
- Onboarding card is an opaque content surface (`DS.Radius.card`); numerals are
  accent-filled with white text (4.61:1).
- **States:** loading = `LoadingState("Importing…")` (replaces the material
  scrim); empty = `EmptyState` with one prominent CTA + plain Import; error =
  alert (single funnel `presentError`); success = transient `StatusBanner`
  ("Pack imported") + haptic after a `.stickreatepack` lands.
- Filtered-empty now has a CTA ("Show All Packs") when a folder filter hides
  everything — no dead end. Search-empty keeps `ContentUnavailableView.search`.
- Dead affordance removed: the disabled "why can't I export" menu row stays but
  is clearly informational (kept intentionally as explanation).

### Pack editor
- Empty → `EmptyState` with prominent *Add Sticker*; ready → prominent
  *Add to WhatsApp* (no green).
- Deleted-pack fallback is now a real `EmptyState` ("Pack Not Found" + Back)
  instead of a blank view.
- Selection/impact/error haptics on cover, duplicate, reorder and export error.
- Header, footer, tiles and placeholder all use `DS` tokens.

### Sticker cell (shared tile)
- Opaque tile (`DS.Radius.tile`), scrim badges for number/animated (robust over
  any thumbnail), accent Cover capsule (white label 4.61:1), emoji badge on a
  raised surface. Placeholder keeps a ≥44 pt target with a label + hint.

### Import media sheet
- Loading → `LoadingState`; empty → `EmptyState` + prominent *New Pack*.
- Secondary Cancel no longer tinted. Row/thumb radii tokenized; rows get a
  44 pt minimum height. Selection and success haptics added.
- Fixed a label mismatch: the "New Pack" list button had
  `accessibilityLabel("Create a new pack")` — now one label per concept.

### Export sheet
- Prominent *Add to WhatsApp* no longer green; success uses the shared
  `SuccessLabel` ("Added to WhatsApp") in accent.
- New explicit empty state ("No Stickers to Add") instead of a disabled button.
- Success/error haptics; success transition respects Reduce Motion.

### Folder picker / Emoji picker
- One prominent *Save* each; Emoji's *Add* is `.glass`. Selection traits added
  to folder rows and emoji cells; Save fires a success haptic. Emoji palette is
  content (emoji are data, not UI icons).

---

## 5. Component inventory

| Component | Kind | Notes |
|---|---|---|
| `EmptyState` | shared | wraps `ContentUnavailableView`, one CTA |
| `LoadingState` | shared | replaces ad-hoc material scrims |
| `SuccessLabel` | shared | inline success, accent not green |
| `StatusBanner` | shared | transient confirmation, opaque capsule |
| `PackCard` | screen | opaque content card |
| `StickerCell` | screen | opaque numbered tile + placeholder |

---

## 6. Accessibility

- Kept every existing label; added missing hints/labels; marked decoration
  `accessibilityHidden(true)` (badges, thumbnails, checkmark glyphs).
- 44 pt minimum on placeholder tile, emoji cells, folder rows, pack rows.
- Traits: `.isSelected` on selected pack/folder/emoji; `.isImage`+`.isButton` on
  the sticker tile (kept).
- No custom-drag control exists in the owned screens, so no
  `.accessibilityAdjustableAction` was needed here; the video crop/filmstrip
  adjustable actions live in `VideoTrimView` (next chunk).

## 7. Motion

Purposeful and interruptible: `DS.Motion` springs for the import banner and the
export success transition, system-driven transitions elsewhere. Every owned
animation checks `accessibilityReduceMotion`.

## 8. Copy

Short and neutral. "Add to WhatsApp" is used only as a descriptive action label;
no WhatsApp logo, no brand-green. No emoji used as UI icons. New user-facing
strings remain plain `Text("…")` literals so a later String Catalog pass can
extract them (no extraction attempted here).

---

## 9. Previews added

Each edited screen and shared component ships `#Preview` blocks for **light,
dark, largest Dynamic Type (`.accessibility5`), small iPhone (SE width 375) and
large iPhone (Pro Max width 430)**; screens where glass matters
(Library, Pack editor, Export) also add a **Reduce Transparency** preview.

## 10. Not verifiable without a build

- Actual compile (Swift 5 mode / Xcode 26) and CI green.
- Real contrast of the glass prominent button label over live materials — the
  accent math above is on flat colors.
- `.glassProminent` label auto-contrast behaviour on device.
- Visual result of previews, Dynamic Type reflow, and Reduce Transparency on a
  device/simulator.
