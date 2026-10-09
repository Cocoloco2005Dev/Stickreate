import SwiftUI

extension DS {
    /// Semantic type roles. Each maps to a system text style so Dynamic Type —
    /// including the largest accessibility sizes — keeps working. Screens must
    /// use these (or a system style) and never `.system(size:)`.
    enum TextRole {
        /// Screen / empty-state title.
        static let screen = Font.title2.weight(.semibold)
        /// Section header inside a screen.
        static let section = Font.headline
        /// Pack / card title.
        static let cardTitle = Font.headline
        /// Primary reading text.
        static let body = Font.body
        /// Supporting line under a title.
        static let supporting = Font.subheadline
        /// Secondary metadata.
        static let footnote = Font.footnote
        /// Small status text.
        static let caption = Font.caption
        /// Text inside a small badge (bold, still scales).
        static let badge = Font.caption2.weight(.bold)
    }
}
