import Foundation

/// A picked video that hasn't been converted to frames yet.
///
/// The `url` points at a temporary copy that stays valid until the sticker is
/// created, so the user can choose a trim range before frames are extracted.
struct VideoDraft {
    let url: URL
    let duration: TimeInterval
}
