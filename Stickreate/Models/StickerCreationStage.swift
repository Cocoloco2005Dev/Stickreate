import Foundation

/// User-facing phase of sticker creation, so progress UIs can show real stages
/// instead of a single spinner that stalls at 100%.
enum StickerCreationStage: Equatable, Sendable {
    case loading
    case extracting(Double)   // frame extraction, 0...1
    case cutting(Double)      // Vision subject lift, 0...1
    case compressing          // indeterminate: WebP encode can take a while
    case saving
    case done

    var label: String {
        switch self {
        case .loading:
            "Loading…"
        case .extracting(let progress):
            "Extracting frames… \(Self.percent(progress))%"
        case .cutting(let progress):
            "Intelligent Cut… \(Self.percent(progress))%"
        case .compressing:
            "Optimizing WebP…"
        case .saving:
            "Saving…"
        case .done:
            "Done"
        }
    }

    /// `0...1` when the stage is determinate, `nil` for indeterminate stages.
    var fraction: Double? {
        switch self {
        case .loading, .compressing, .saving:
            nil
        case .extracting(let progress), .cutting(let progress):
            min(max(progress, 0), 1)
        case .done:
            1.0
        }
    }

    private static func percent(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 100).rounded())
    }
}
