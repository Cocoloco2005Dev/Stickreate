import SwiftUI

/// Stickreate's small design system. One namespace, deliberately thin.
///
/// It does **not** re-implement what SwiftUI already provides: text comes from
/// system `Font` roles (Dynamic Type safe), colors come from system semantic
/// colors, and glass comes from the system button styles. This file only
/// standardizes the *choices* that used to be scattered magic numbers across the
/// screens so the reskin stays internally consistent.
enum DS {

    // MARK: Spacing

    /// Base-4 spacing scale matching the 4/8/12/16/20/24 rhythm the app already
    /// used, so the reskin stays visually continuous.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        /// Default gap between stacked sections in a screen.
        static let section: CGFloat = 24
    }

    // MARK: Radii

    /// Continuous corner radii for the shapes we draw.
    enum Radius {
        static let badge: CGFloat = 10
        static let thumb: CGFloat = 12
        static let tile: CGFloat = 16
        static let card: CGFloat = 20
        /// Large surfaces: full-screen previews and overlay cards.
        static let large: CGFloat = 24
        static let pill: CGFloat = 999
    }

    // MARK: Motion

    /// Short, springy, interruptible. Screens that must respect Reduce Motion
    /// pass `nil` instead of a value here (the change then happens instantly).
    enum Motion {
        static let quick: Animation = .snappy(duration: 0.22, extraBounce: 0.04)
        static let standard: Animation = .snappy(duration: 0.32, extraBounce: 0.08)
        static let gentle: Animation = .smooth(duration: 0.35)
        /// How long a transient confirmation stays on screen.
        static let confirmationHold: Duration = .seconds(2)
    }

    /// HIG minimum tap target.
    static let minTapTarget: CGFloat = 44
}
