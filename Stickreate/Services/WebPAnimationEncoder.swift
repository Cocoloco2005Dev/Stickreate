import UIKit
import Accelerate
import libwebp

/// Thin Swift wrapper over libwebp's native animated encoder
/// (`WebPAnimEncoder` from `webp/mux.h`).
///
/// Unlike `SDImageWebPCoder.encodedData(with:frames:...)` — which encodes every
/// frame as an independent static WebP and muxes them, with no inter-frame
/// compression — `WebPAnimEncoder` reuses the previous canvas, so identical
/// regions are stored as small frame deltas. That is both faster and smaller.
///
/// Notes:
/// - `kmin`/`kmax` live on `WebPAnimEncoderOptions`, NOT on `WebPConfig`
///   (the task brief said `config`; that is a libwebp 1.3.2 header mismatch).
/// - `minimize_size = true` implicitly disables key-frame insertion, so
///   `keyframeInterval` is a no-op unless `minimizeSize` is false.
/// - Frames are imported as straight (non-premultiplied) RGBA.
enum WebPAnimationEncoder {

    struct Options {
        /// libwebp lossy quality, 0...100 (100 = best/largest).
        var quality: Float = 80
        /// Quality/speed trade-off, 0...6 (6 = slowest/best). Low values are the
        /// single biggest speed lever; the animated encoder already exploits
        /// inter-frame redundancy, so 2 is the fast default here.
        var method: Int = 2
        /// Minimum distance between key frames (`WebPAnimEncoderOptions.kmin`).
        var keyframeInterval: Int = 10
        /// 0 = loop forever.
        var loopCount: Int = 0
        /// Try both dispose methods / lossless candidates to shave bytes (slower).
        /// Default OFF: this is the slowest libwebp mode and is only enabled as a
        /// last-resort fallback by the encode ladder.
        var minimizeSize: Bool = false

        init(
            quality: Float = 80,
            method: Int = 2,
            keyframeInterval: Int = 10,
            loopCount: Int = 0,
            minimizeSize: Bool = false
        ) {
            self.quality = quality
            self.method = method
            self.keyframeInterval = keyframeInterval
            self.loopCount = loopCount
            self.minimizeSize = minimizeSize
        }
    }

    /// sRGB, 8-bit, premultiplied RGBA. `vImageBuffer_InitWithCGImage` converts
    /// every frame into this format before it is unpremultiplied for libwebp.
    private static let rgbaFormat: vImage_CGImageFormat? = {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            renderingIntent: .defaultIntent
        )
    }()

    #if DEBUG
    /// Runs the row-order self-check once per process.
    private static let didCheckRGBAOrientation: Bool = {
        assertRGBAIsTopLeft()
        return true
    }()

    /// Sanity check that the RGBA fill path produces a TOP-LEFT row-major buffer:
    /// a UIKit-rendered red-top / blue-bottom pattern must have red in the first
    /// row of the buffer (row 0), which is what `WebPPictureImportRGBA` expects.
    /// If this ever fails, the export would be vertically flipped.
    private static func assertRGBAIsTopLeft() {
        let side = 4
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        // UIKit renderers use a top-left origin: y = 0 is the TOP row.
        let pattern = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: rendererFormat
        ).image { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
            context.cgContext.setFillColor(UIColor.blue.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: side / 2, width: side, height: side / 2))
        }
        guard let cgImage = pattern.cgImage, var format = rgbaFormat else { return }

        var buffer = vImage_Buffer()
        defer { buffer.free() }
        guard vImageBuffer_InitWithCGImage(
            &buffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags)
        ) == kvImageNoError,
        let data = buffer.data?.assumingMemoryBound(to: UInt8.self) else { return }

        // Premultiplied RGBA with alpha 255, so the components are the raw colors.
        assert(
            data[0] > 180 && data[1] < 80 && data[2] < 80,
            "WebPAnimationEncoder RGBA buffer row 0 must be the image TOP row (expected red)"
        )
    }
    #endif

    /// Encodes RGBA frames (all the same pixel size) into an animated WebP.
    /// `durationsMs[i]` is frame i's duration in integer milliseconds.
    /// `onProgress` is called after each frame with a `0...1` fraction.
    ///
    /// Returns `nil` on any failure so the caller can fall back to the
    /// per-frame static encoder. Assumes every frame is opaque-ready in the
    /// sense that its `cgImage` already carries the intended orientation
    /// (the caller draws aspect-fit frames); non-`.up` images are normalized.
    static func encode(
        frames: [UIImage],
        durationsMs: [Int],
        options: Options,
        onProgress: ((Double) -> Void)?
    ) -> Data? {
        guard frames.count >= 2,
              frames.count == durationsMs.count,
              durationsMs.allSatisfy({ $0 > 0 }) else { return nil }

        let width = Int((frames[0].size.width * frames[0].scale).rounded())
        let height = Int((frames[0].size.height * frames[0].scale).rounded())
        guard width > 0, height > 0 else { return nil }
        for image in frames {
            let w = Int((image.size.width * image.scale).rounded())
            let h = Int((image.size.height * image.scale).rounded())
            guard w == width, h == height else { return nil }
        }

        #if DEBUG
        // Frames are expected UPRIGHT before encoding: `FrameExtractor` decodes
        // with `AVAssetImageGenerator.appliesPreferredTrackTransform = true`, so
        // the track's rotation/mirroring is already baked in. This encoder never
        // rotates — a flipped input would ship a flipped sticker.
        assert(
            frames.allSatisfy { $0.imageOrientation == .up },
            "WebPAnimationEncoder expects upright frames; extraction must apply the track transform"
        )
        // Also verify the RGBA fill path itself keeps row 0 = image top.
        _ = didCheckRGBAOrientation
        #endif

        var encOptions = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&encOptions) != 0 else { return nil }
        encOptions.anim_params.loop_count = Int32(options.loopCount)
        // 0x00000000 = transparent canvas background; the default is opaque white.
        encOptions.anim_params.bgcolor = 0
        encOptions.minimize_size = options.minimizeSize ? 1 : 0
        encOptions.allow_mixed = 0
        encOptions.verbose = 0
        let kmin = Int32(max(0, options.keyframeInterval))
        encOptions.kmin = kmin
        // libwebp sanitizes these (kmin_lower_bound = kmax/2 + 1, window ≤ 30).
        encOptions.kmax = kmin > 0 ? kmin * 2 : 0

        guard let encoder = WebPAnimEncoderNew(Int32(width), Int32(height), &encOptions) else {
            return nil
        }
        defer { WebPAnimEncoderDelete(encoder) }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { return nil }
        config.lossless = 0
        config.quality = min(max(options.quality, 0), 100)
        config.method = Int32(min(max(options.method, 0), 6))
        // Tie alpha quality to the quality ladder: stickers are mostly alpha.
        config.alpha_quality = Int32(config.quality)
        guard WebPValidateConfig(&config) != 0 else { return nil }

        // sRGB, 8-bit, premultiplied RGBA — the format `vImageBuffer_InitWithCGImage`
        // converts each frame into before unpremultiplying for libwebp.
        guard var format = rgbaFormat else { return nil }

        var timestamp = 0
        let total = frames.count
        // Announce the attempt immediately so the caller's bar moves as soon as
        // encoding starts, then tick after every frame (never only at the end).
        onProgress?(0)
        for index in 0..<total {
            var added = false
            autoreleasepool {
                let image = frames[index]
                guard let cgImage = image.cgImage ?? image.upNormalized()?.cgImage else { return }

                // vImage fills a buffer whose `data` is defined as the TOP-LEFT
                // pixel, so the result is top-left row-major — exactly what
                // `WebPPictureImportRGBA` expects. (Drawing through a raw
                // CGContext required a CTM flip whose direction was easy to get
                // wrong; that is what previously produced upside-down exports.)
                var buffer = vImage_Buffer()
                defer { buffer.free() }
                guard vImageBuffer_InitWithCGImage(
                    &buffer, &format, nil, cgImage, vImage_Flags(kvImageNoFlags)
                ) == kvImageNoError else { return }

                // vImageBuffer_InitWithCGImage yields premultiplied alpha;
                // libwebp (like SDWebImageWebPCoder) wants straight alpha,
                // otherwise semi-transparent edges come out dark.
                guard vImageUnpremultiplyData_RGBA8888(
                    &buffer, &buffer, vImage_Flags(kvImageNoFlags)
                ) == kvImageNoError else { return }

                var picture = WebPPicture()
                guard WebPPictureInit(&picture) != 0 else { return }
                defer { WebPPictureFree(&picture) }
                picture.width = Int32(width)
                picture.height = Int32(height)
                guard let pixels = buffer.data?.assumingMemoryBound(to: UInt8.self),
                      WebPPictureImportRGBA(&picture, pixels, Int32(buffer.rowBytes)) != 0 else {
                    return
                }
                guard WebPAnimEncoderAdd(encoder, &picture, Int32(timestamp), &config) != 0 else {
                    return
                }
                added = true
            }
            guard added else { return nil }
            timestamp += durationsMs[index]
            onProgress?(Double(index + 1) / Double(total))
        }

        // Signal the final frame's duration.
        guard WebPAnimEncoderAdd(encoder, nil, Int32(timestamp), nil) != 0 else { return nil }

        var webpData = WebPData()
        // Safe to clear on the error path too; this also frees any partial buffer.
        defer { WebPDataClear(&webpData) }
        guard WebPAnimEncoderAssemble(encoder, &webpData) != 0 else { return nil }
        guard let bytes = webpData.bytes, webpData.size > 0 else { return nil }
        let data = Data(bytes: bytes, count: webpData.size)
        Log.info(
            .encode,
            "native animated encode frames=\(frames.count) bytes=\(data.count) q=\(Int(options.quality))"
        )
        return data
    }
}
