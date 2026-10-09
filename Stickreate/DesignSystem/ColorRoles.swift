import SwiftUI

extension DS {
    /// Semantic color roles.
    ///
    /// Rule: **accent is reserved for the single primary action and for
    /// selection.** It is never body text and never a content surface. The app
    /// ships one coral accent (`AccentColor`) that measures ≥4.5:1 against white
    /// for label text and ≥3:1 as a UI tint; the numbers live in
    /// `docs/overhaul/02-design-spec.md`. Everything iOS already covers
    /// (backgrounds, labels, separators) uses the system semantic colors — we do
    /// not invent a parallel palette for those.
    enum ColorRole {
        /// Primary action tint + current selection.
        static let accent = Color.accentColor
        /// Opaque content surface for cards and tiles (content is never glass).
        static let contentSurface = Color(uiColor: .secondarySystemBackground)
        /// Raised content surface, e.g. rows or cards on a plain background.
        static let contentSurfaceRaised = Color(uiColor: .systemBackground)
        /// Scrim used behind white text drawn over media (badges/thumbnails).
        static let mediaScrim = Color.black.opacity(0.55)
        /// Positive confirmation for transient "added" states. Deliberately the
        /// accent — not a brand-green — so we never mimic another brand.
        static let positive = Color.accentColor
    }
}
