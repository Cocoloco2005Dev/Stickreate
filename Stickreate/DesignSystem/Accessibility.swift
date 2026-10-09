import SwiftUI
import UIKit

extension StickerCreationStage {
    /// A stable phrase that changes only on a phase boundary — not on every
    /// progress tick — so VoiceOver announcements don't flood during encoding.
    var announcementPhase: String {
        switch self {
        case .loading: "Preparing sticker"
        case .extracting: "Extracting frames"
        case .cutting: "Intelligent Cut"
        case .compressing: "Optimizing"
        case .saving: "Saving"
        case .done: "Done"
        }
    }
}

extension Optional where Wrapped == StickerCreationStage {
    /// Phase phrase for an optional stage (empty when there is no stage).
    var announcementPhase: String {
        switch self {
        case .some(let stage): stage.announcementPhase
        case .none: ""
        }
    }
}

extension View {
    /// Posts a VoiceOver announcement whenever `value` changes, using the
    /// message built from the new value. Used for creation-stage transitions so
    /// VoiceOver users hear progress instead of silence.
    ///
    /// An empty message is skipped, so callers can pass a value that only changes
    /// on a phase boundary (not on every progress tick) without spamming.
    ///
    /// Uses `UIAccessibility.post` (rock-solid across OS versions) rather than
    /// the newer SwiftUI notification type.
    func announceOnChange<V: Equatable>(
        of value: V,
        _ message: @escaping (V) -> String
    ) -> some View {
        onChange(of: value) { _, newValue in
            let text = message(newValue)
            guard !text.isEmpty else { return }
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
}
