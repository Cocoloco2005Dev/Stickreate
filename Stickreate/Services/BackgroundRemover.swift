import UIKit
import Vision
import CoreImage
import CoreVideo

/// Automatic background removal using Apple's on-device Vision subject lifting.
enum BackgroundRemover {
    enum Failure: LocalizedError {
        case noSubject
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noSubject:
                "Couldn't find a subject to cut out."
            case .failed(let message):
                message
            }
        }
    }

    /// A subject cut-out plus the single-channel mask Vision used to build it.
    struct SubjectExtraction {
        /// Subject on a transparent background.
        let cutout: UIImage
        /// Single-channel mask, white = keep, same pixel size as the input.
        let mask: CGImage
    }

    private static let context = CIContext()

    /// Returns the subject on a transparent background.
    /// Uses `VNGenerateForegroundInstanceMaskRequest` (iOS 17+).
    ///
    /// The Vision pass runs off the main thread so callers awaiting this method
    /// (typically the UI) stay responsive.
    static func removeBackground(from image: UIImage) async throws -> UIImage {
        let extraction = try await extractSubject(from: image)
        return extraction.cutout
    }

    /// Returns both the cut-out and the raw subject mask so the user can edit it.
    ///
    /// The Vision pass runs off the main thread.
    static func extractSubject(from image: UIImage) async throws -> SubjectExtraction {
        let upright = image.upNormalized() ?? image
        guard let ciImage = CIImage(image: upright) else {
            throw Failure.failed("Couldn't read this image.")
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SubjectExtraction, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
                do {
                    try handler.perform([request])
                    guard let result = request.results?.first else {
                        continuation.resume(throwing: Failure.noSubject)
                        return
                    }

                    let cutoutBuffer = try result.generateMaskedImage(
                        ofInstances: result.allInstances,
                        from: handler,
                        croppedToInstancesExtent: false
                    )
                    let masked = CIImage(cvPixelBuffer: cutoutBuffer)
                    guard let cutoutCG = context.createCGImage(masked, from: masked.extent) else {
                        continuation.resume(throwing: Failure.failed("Couldn't render the cut-out."))
                        return
                    }

                    let maskBuffer = try result.generateScaledMaskForImage(
                        forInstances: result.allInstances,
                        from: handler
                    )
                    guard let mask = makeMaskImage(from: maskBuffer) else {
                        continuation.resume(throwing: Failure.failed("Couldn't read the subject mask."))
                        return
                    }

                    continuation.resume(returning: SubjectExtraction(
                        cutout: UIImage(cgImage: cutoutCG),
                        mask: mask
                    ))
                } catch {
                    continuation.resume(throwing: Failure.failed(error.localizedDescription))
                }
            }
        }
    }

    /// Converts Vision's mask pixel buffer into a single-channel `CGImage`.
    /// Falls back to a Core Image render if the buffer isn't 8-bit grayscale.
    private static func makeMaskImage(from buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
           let base = CVPixelBufferGetBaseAddress(buffer) {
            // Copy out of the buffer so the CGImage doesn't point at locked memory.
            let data = Data(bytes: base, count: bytesPerRow * height)
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }

        let ciImage = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(
            ciImage,
            from: ciImage.extent,
            format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
    }
}
