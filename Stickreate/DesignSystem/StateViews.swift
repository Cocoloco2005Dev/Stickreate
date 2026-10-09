import SwiftUI

// ponytail: components take `String` (not LocalizedStringKey) so dynamic error
// messages compose. When the String Catalog lands, switch to LocalizedStringKey
// at literal call sites or `String(localized:)`.

/// Shared empty state. Wraps the HIG `ContentUnavailableView` and standardizes
/// the framing so every empty screen reads the same: one symbol, one title, one
/// short description, and (at most) one prominent action.
struct EmptyState<Actions: View>: View {
    private let symbol: String
    private let title: String
    private let message: String
    private let actions: Actions

    init(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    /// Empty state with no action buttons.
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// Shared loading state: one large spinner with a short label. Replaces the
/// ad-hoc `ProgressView(…).background(.material)` scrims so no custom bar/sheet
/// material is introduced.
struct LoadingState: View {
    let title: String

    var body: some View {
        VStack(spacing: DS.Space.md) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(DS.TextRole.supporting)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// Inline success confirmation ("Added to WhatsApp", "Saved"). Uses the accent,
/// never a brand-green.
struct SuccessLabel: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "checkmark.circle.fill")
            .font(DS.TextRole.supporting.weight(.semibold))
            .foregroundStyle(DS.ColorRole.positive)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(title)
    }
}

/// Transient, non-blocking confirmation banner shown over content. It is a
/// content-layer surface (opaque), never glass, and never a substitute for the
/// one prominent action on the screen.
struct StatusBanner: View {
    let title: String

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DS.ColorRole.accent)
            Text(title)
                .font(DS.TextRole.supporting.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .background(DS.ColorRole.contentSurface, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

#Preview("State views") {
    VStack(spacing: DS.Space.xxl) {
        StatusBanner(title: "Pack imported")
        SuccessLabel(title: "Added to WhatsApp")
    }
    .padding()
}
