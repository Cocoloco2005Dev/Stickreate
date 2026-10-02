import UIKit
import SDWebImageWebPCoder

/// Encodes sticker artwork to WhatsApp-compatible WebP.
///
/// Phase 1 wires the static path only, to validate that `libwebp` links and
/// builds in CI. Quality/size budgeting and the animated path land in Phase 2.
enum StickerEncoder {
    static func encodeStatic(_ image: UIImage) -> Data? {
        SDImageWebPCoder.shared.encodedData(with: image, format: .webP, options: nil)
    }
}
