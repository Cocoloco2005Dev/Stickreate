import Foundation

/// WhatsApp sticker constraints. Source: https://github.com/WhatsApp/stickers (iOS).
enum Limits {
    /// Sticker canvas is exactly 512×512.
    static let canvas = 512
    /// Tray (pack) icon is 96×96.
    static let traySize = 96

    static let minStickers = 3
    static let maxStickers = 30
    static let maxEmojisPerSticker = 3

    static let maxStaticBytes = 100 * 1024
    static let maxAnimatedBytes = 500 * 1024
    static let maxTrayBytes = 50 * 1024

    /// Animated stickers: minimum frame duration and total animation length.
    static let minFrameDuration: TimeInterval = 0.008
    static let maxAnimationDuration: TimeInterval = 10
}
