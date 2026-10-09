import SwiftUI

/// App haptic vocabulary mapped onto `.sensoryFeedback`. Attach as a modifier:
///
///     .haptic(.success, trigger: didImport)
///
/// The feedback plays whenever `trigger` changes; equal values do nothing.
enum Haptic {
    case selection
    case success
    case warning
    case error
    case impact

    var feedback: SensoryFeedback {
        switch self {
        case .selection: .selection
        case .success: .success
        case .warning: .warning
        case .error: .error
        case .impact: .impact(weight: .light)
        }
    }
}

extension View {
    /// Plays `kind` whenever `trigger` changes.
    func haptic(_ kind: Haptic, trigger: some Equatable) -> some View {
        sensoryFeedback(kind.feedback, trigger: trigger)
    }
}
