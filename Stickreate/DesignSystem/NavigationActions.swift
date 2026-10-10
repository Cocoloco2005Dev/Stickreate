import SwiftUI

// MARK: - Standard navigation actions
//
// One rule for every screen with a navigation bar:
//   • Leading  = Back (plain chevron, only when the screen steps back) OR Cancel.
//     Never both, and never a hidden/custom back button (swipe-back keeps working).
//   • Trailing = the single primary action, styled `.glassProminent`.
//   • Bottom bars carry only secondary tools; empty-state CTAs are the one
//     prominent action only when the content is empty.
//
// These three `ToolbarContent` values keep that rule identical everywhere.

/// Leading back affordance: a plain chevron. Use only for screens that step
/// back within a flow (the first step dismisses). `label` is the VoiceOver name.
struct BackActionItem: ToolbarContent {
    let label: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(action: action) {
                Image(systemName: "chevron.left")
                    .fontWeight(.semibold)
            }
            .disabled(isDisabled)
            .accessibilityLabel(label)
        }
    }
}

/// Leading dismiss for modal screens without internal steps.
struct CancelActionItem: ToolbarContent {
    var title: String = "Cancel"
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(title, action: action)
                .disabled(isDisabled)
        }
    }
}

/// Trailing primary action. Exactly one per screen, always `.glassProminent`.
///
/// `systemImage` adds an icon so the action is recognizable. `iconOnly` collapses
/// it to just that icon (with `title` kept as the accessibility label) so a
/// crowded trailing bar never truncates the navigation title.
struct PrimaryActionItem: ToolbarContent {
    let title: String
    var systemImage: String? = nil
    var iconOnly: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(action: action) {
                if let systemImage {
                    if iconOnly {
                        Image(systemName: systemImage)
                    } else {
                        Label(title, systemImage: systemImage)
                    }
                } else {
                    Text(title)
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(isDisabled)
            .accessibilityLabel(title)
        }
    }
}
