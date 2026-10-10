import UIKit
import SDWebImage
import SDWebImageWebPCoder

/// Encodes artwork into WhatsApp-compliant WebP.
///
/// Budgets (WhatsApp, iOS): static ≤ 100 KB, animated ≤ 500 KB,
/// frames ≥ 8 ms, total animation ≤ 10 s, canvas exactly 512×512.
enum StickerEncoder {
    // MARK: - Static

    /// 512×512 static sticker. Must shrink quality until it fits 100 KB.
    static func staticSticker(from image: UIImage) -> Data? {
        guard let canvas = aspectFit(image, in: canvasSize) else { return nil }
        return encode(canvas, maxBytes: Limits.maxStaticBytes)
    }

    // MARK: - Animated

    /// Target budget for animated stickers. WhatsApp enforces a 500 KB hard cap;
    /// aim just under it so we can keep as many frames as possible.
    private static let animatedByteBudget = 480 * 1024

    /// Quality ladder (libwebp 0...100), ASCENDING. At each candidate frame count
    /// the lowest quality is tried first: if even that overflows the budget, every
    /// higher quality would too, so the candidate is abandoned without trying
    /// them. Only when the lowest fits do qualities ramp up, and the highest that
    /// fits wins. The whole quality ramp runs before any frames are dropped.
    private static let animatedQualities: [Float] = [15, 25, 40, 60, 80]

    /// libwebp compression method (0 = fastest … 6 = slowest). This is the single
    /// biggest speed lever; the native encoder already exploits inter-frame
    /// redundancy, so a slow method buys little. Normal attempts use 2; the large,
    /// mostly-doomed first candidates use 0.
    private static let animatedMethod = 2
    private static let animatedFastMethod = 0

    /// Frame count at or above which a candidate uses `animatedFastMethod`.
    private static let fastMethodFrameThreshold = 96

    /// Largest frame count the ladder starts from. A cut clip never needs to begin
    /// at 220/240 frames, and every wasted large encode is seconds long.
    private static let maxLadderStart = 160

    /// Fallback per-frame settings (SDWebImageWebPCoder), used only if the
    /// native C encoder returns nil so we never regress to no sticker. Low method
    /// and a small frame cap keep this slow path from becoming a 40 s outlier.
    private static let fallbackMethod = 2
    private static let fallbackPass = 1

    /// Largest candidate frame count that will fall back to the per-frame static
    /// encoder when the native encoder fails. Above this the candidate is simply
    /// abandoned — a full static re-encode of many frames is far too slow.
    private static let fallbackFrameLimit = 60

    /// Animated sticker from frames, using libwebp's native `WebPAnimEncoder`
    /// (inter-frame compression) via `WebPAnimationEncoder`.
    ///
    /// Fewest-encodes ladder, frames preserved. Candidate frame counts are
    /// processed DESCENDING (most frames first, start capped at `maxLadderStart`);
    /// at each candidate qualities are tried ASCENDING. The moment the lowest
    /// quality overflows the budget the candidate is abandoned (higher qualities
    /// would only be larger) and the next, smaller candidate is tried. The first
    /// candidate whose lowest quality fits wins, and qualities then ramp up to the
    /// highest that still fits — so the returned payload has the most frames and
    /// the best quality that both fit.
    ///
    /// Every normal attempt encodes with `minimize_size = false`. Only if the whole
    /// ladder fails is a SINGLE last-resort encode run at the smallest frame count
    /// and lowest quality with `minimize_size = true`. Falls back to the per-frame
    /// static encoder only when the C encoder itself returns nil.
    ///
    /// The canvas stays exactly 512×512 (a WhatsApp requirement — dimensions are
    /// never reduced). Requires at least two frames; one frame is not a valid
    /// animated payload.
    ///
    /// When `targetDuration` is provided, frame durations are distributed as
    /// whole milliseconds that sum to `targetDuration`. `onProgress` reports a
    /// monotonic `0...1` fraction across frames and attempts; in-flight values
    /// never exceed `0.999` and only a payload actually returned reports `1.0`.
    ///
    /// `byteBudget` overrides the 480 KB target; it exists so tests can force the
    /// failure path without generating an incompressibly large clip.
    static func animatedSticker(
        from frames: [Frame],
        loopCount: Int = 0,
        targetDuration: TimeInterval? = nil,
        byteBudget: Int? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) -> Data? {
        guard frames.count >= 2 else { return nil }
        #if DEBUG
        // Estimated source-set cost, captured before `frames` is released so the
        // peak log can report the pre-release upper bound.
        let sourceBytes = rgbaBytes(frames)
        #endif
        // Build the resident canvas set ONCE. `prepare` passes through any frame
        // that is already a 512×512 upright canvas (no new pixel buffer), and
        // this function keeps no reference to `frames` past this point, so the
        // source set can be released (Release ARC) before the encode ladder and
        // only the prepared set stays resident across it.
        let prepared = prepare(frames)
        guard prepared.count >= 2 else { return nil }

        let budget = byteBudget ?? animatedByteBudget

        #if DEBUG
        logPreparedBudget(prepared, sourceBytes: sourceBytes)
        #endif

        let loop = max(0, loopCount)

        // Candidate frame counts, most frames first (start capped at
        // `maxLadderStart`), descending to the last-resort floor.
        let candidateCounts = frameCandidateCounts(sourceCount: prepared.count)
        guard !candidateCounts.isEmpty else { return nil }

        // Pure policy: candidates descending, qualities ascending, a candidate is
        // abandoned the moment its LOWEST quality overflows.
        var ladder = EncodeLadder(frameCounts: candidateCounts, qualities: animatedQualities)

        // Progress estimate: one probe per candidate plus a quality ramp at the
        // winning candidate. `report` clamps below 1.0 regardless.
        let plannedAttempts = max(1, candidateCounts.count + animatedQualities.count)
        var attempt = 0
        // Monotonic + rate-limited: per-frame/per-attempt reports are clamped so
        // the bar never moves backwards, and intermediate frames inside the same
        // ~50 ms window are dropped so we never flood the UI. The first report
        // always goes through, so even a fast encode still ticks.
        var accumulator = ProgressAccumulator()
        var lastReport = CFAbsoluteTimeGetCurrent() - 1
        func report(_ frameFraction: Double) {
            let progress = (Double(attempt) + frameFraction) / Double(plannedAttempts)
            let monotonic = accumulator.update(min(0.999, progress))
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastReport >= 1.0 / 20.0 else { return }
            lastReport = now
            onProgress?(monotonic)
        }

        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        #endif

        /// Runs one native (or fallback) encode and reports whether it fits.
        func runAttempt(frameCount: Int, quality: Float) -> (data: Data?, fit: Bool) {
            let candidate = resample(prepared, to: frameCount)
            let durations = targetMilliseconds(candidate, targetDuration: targetDuration)
            let images = candidate.map(\.image)
            // Low method for the large, mostly-doomed candidates; 2 otherwise.
            let method = frameCount >= fastMethodFrameThreshold ? animatedFastMethod : animatedMethod
            let options = WebPAnimationEncoder.Options(
                quality: quality,
                method: method,
                keyframeInterval: 10,
                loopCount: loop,
                minimizeSize: false
            )
            let attemptStarted = CFAbsoluteTimeGetCurrent()
            let native = WebPAnimationEncoder.encode(
                frames: images,
                durationsMs: durations,
                options: options,
                onProgress: report
            )
            // The per-frame static fallback has no inter-frame compression and is
            // orders of magnitude slower on many frames (a 120-frame fallback is
            // the suspected 40 s outlier). Only run it for small candidates; a
            // large candidate whose native encode failed is simply abandoned.
            let data: Data?
            if native == nil, frameCount <= fallbackFrameLimit {
                Log.info(
                    .encode,
                    "webp native nil -> per-frame fallback frames=\(frameCount)"
                )
                data = encodeAnimatedFallback(
                    images: images,
                    durationsMs: durations,
                    loopCount: loop,
                    quality: Double(quality) / 100.0
                )
            } else {
                data = native
            }
            // Per-attempt tick: report the completed attempt even when the native
            // encoder bailed before its first per-frame callback.
            report(1.0)
            attempt += 1
            // 480 KB target is below the 500 KB hard cap, so this also guarantees
            // WhatsApp compliance.
            let attemptMs = (CFAbsoluteTimeGetCurrent() - attemptStarted) * 1000
            let fit = data.map { $0.count <= budget } ?? false
            Log.timing(
                .encode,
                "webp ladder q=\(Int(quality)) method=\(method) frames=\(images.count) bytes=\(data?.count ?? 0) fit=\(fit)",
                ms: attemptMs
            )
            return (data, fit)
        }

        // The last encode that fit — always the winner, since a candidate is only
        // abandoned before any fit and the first candidate with a fit always wins.
        var bestData: Data?
        var action = ladder.start()
        ladderLoop: while true {
            // Abort promptly on cancellation; a thrown CancellationError upstream
            // is treated by the UI as a silent cancel, so returning nil is safe.
            if Task.isCancelled { return nil }
            switch action {
            case .exhausted:
                break ladderLoop
            case .win(let frameCount, let quality):
                guard let data = bestData else { return nil }
                Log.timing(
                    .encode,
                    "webp ladder WON q=\(Int(quality)) frames=\(frameCount) bytes=\(data.count)",
                    ms: 0
                )
                #if DEBUG
                let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
                print(String(
                    format: "[StickerEncoder] animated total %.0fms: %d frames q=%d -> %d bytes",
                    ms, frameCount, Int(quality), data.count
                ))
                #endif
                onProgress?(1.0)
                return data
            case .encode(let frameCount, let quality):
                let result = runAttempt(frameCount: frameCount, quality: quality)
                if result.fit { bestData = result.data }
                action = ladder.advance(fit: result.fit)
            }
        }

        // Nothing in the ladder fit. Last resort: ONE slow `minimize_size` encode
        // at the smallest candidate and lowest quality — never a slow ladder.
        if let smallest = candidateCounts.last, let lowest = animatedQualities.first {
            let candidate = resample(prepared, to: smallest)
            let images = candidate.map(\.image)
            let durations = targetMilliseconds(candidate, targetDuration: targetDuration)
            let options = WebPAnimationEncoder.Options(
                quality: lowest,
                method: animatedMethod,
                keyframeInterval: 10,
                loopCount: loop,
                minimizeSize: true
            )
            let attemptStarted = CFAbsoluteTimeGetCurrent()
            if let data = WebPAnimationEncoder.encode(
                frames: images,
                durationsMs: durations,
                options: options,
                onProgress: report
            ), data.count <= budget {
                Log.timing(
                    .encode,
                    "webp ladder WON (minimize) q=\(Int(lowest)) frames=\(images.count) bytes=\(data.count)",
                    ms: (CFAbsoluteTimeGetCurrent() - attemptStarted) * 1000
                )
                onProgress?(1.0)
                return data
            }
        }

        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print("[StickerEncoder] animated failed after \(Int(ms.rounded()))ms (exhausted frame + quality ladder)")
        #endif
        Log.info(.encode, "webp ladder exhausted without a payload")
        // No `onProgress?(1.0)` here: a failed encode must never look finished.
        // In-flight progress is capped at 0.999 by `report`; the thrown
        // `Failure` in the caller drives the error UI.
        return nil
    }

    // MARK: - Tray & preview

    /// 96×96 PNG tray icon, ≤ 50 KB.
    static func trayIcon(from image: UIImage) -> Data? {
        let side = CGFloat(Limits.traySize)
        guard let canvas = aspectFit(image, in: CGSize(width: side, height: side)),
              let data = canvas.pngData() else { return nil }
        return data.count <= Limits.maxTrayBytes ? data : nil
    }

    /// Square PNG preview for the app UI.
    static func previewPNG(from image: UIImage, size: CGFloat) -> Data? {
        guard size > 0,
              let canvas = aspectFit(image, in: CGSize(width: size, height: size)) else { return nil }
        return canvas.pngData()
    }

    // MARK: - Encoding

    /// Tries `.encodeCompressionQuality` from 1.0 down to 0.3 in 0.05 steps,
    /// returning the first WebP that fits `maxBytes`.
    private static func encode(_ image: UIImage, maxBytes: Int) -> Data? {
        let started = CFAbsoluteTimeGetCurrent()
        for step in 0...14 {
            let quality = 1.0 - Double(step) * 0.05
            let data = autoreleasepool { () -> Data? in
                SDImageWebPCoder.shared.encodedData(
                    with: image,
                    format: .webP,
                    options: [.encodeCompressionQuality: quality]
                )
            }
            if let data, data.count <= maxBytes {
                Log.timing(
                    .encode,
                    "static webp q=\(quality) bytes=\(data.count)",
                    ms: (CFAbsoluteTimeGetCurrent() - started) * 1000
                )
                return data
            }
        }
        Log.timing(
            .encode,
            "static webp failed (exhausted quality ladder)",
            ms: (CFAbsoluteTimeGetCurrent() - started) * 1000
        )
        return nil
    }

    /// Fallback used only when the native C animated encoder returns nil.
    ///
    /// Reuses the previous per-frame static WebP path (no inter-frame
    /// compression) so a libwebp failure degrades in size/speed but never in
    /// correctness. Runs in its own autorelease pool. Durations carry the
    /// sub-microsecond epsilon SDWebImageWebPCoder needs for exact
    /// `int(duration * 1000)` truncation.
    private static func encodeAnimatedFallback(
        images: [UIImage],
        durationsMs: [Int],
        loopCount: Int,
        quality: Double
    ) -> Data? {
        let sdFrames = zip(images, durationsMs).map { image, ms in
            SDImageFrame(image: image, duration: Double(ms) / 1000.0 + 1e-9)
        }
        let options: [SDImageCoderOption: Any] = [
            .encodeCompressionQuality: quality,
            .encodeWebPMethod: fallbackMethod,
            .encodeWebPPass: fallbackPass,
            .encodeWebPThreadLevel: 1,
            .encodeWebPAlphaQuality: 60
        ]
        return autoreleasepool { () -> Data? in
            SDImageWebPCoder.shared.encodedData(
                with: sdFrames,
                loopCount: UInt(max(0, loopCount)),
                format: .webP,
                options: options
            )
        }
    }

    // MARK: - Alpha fit

    /// Padding (in pixels) added around the detected subject before cropping, so
    /// antialiased edges and drop shadows are never clipped.
    static let alphaMargin: CGFloat = 8

    /// Alpha at or below this counts as transparent. Raised from 8 to 16 so the
    /// soft near-transparent halo Vision leaves around a subject does not extend
    /// the fitted box (which would shrink the subject). A few noisy near-zero
    /// samples still can't defeat the "fully transparent" test.
    private static let alphaThreshold: UInt8 = 16

    /// Bounding box of the non-transparent pixels, in top-left image coordinates
    /// (matching the pixel buffer, so it feeds `cgImage.cropping(to:)` directly).
    /// Returns `nil` when the image is fully opaque (nothing to fit) or fully
    /// transparent (no subject).
    static func alphaBounds(of image: UIImage) -> CGRect? {
        let oriented = image.upNormalized() ?? image
        guard let cgImage = oriented.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        // Draw into a known RGBA8 premultiplied buffer: its first row is the
        // image's TOP row (same orientation as the closed `assertRGBAIsTopLeft`
        // check in WebPAnimationEncoder), so the scan below is top-left.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var minX = width, minY = height, maxX = -1, maxY = -1
        var sawOpaque = false
        var sawTransparent = false
        pixels.withUnsafeBufferPointer { buffer in
            for y in 0..<height {
                let row = y * bytesPerRow
                for x in 0..<width {
                    if buffer[row + x * 4 + 3] >= alphaThreshold {
                        sawOpaque = true
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    } else {
                        sawTransparent = true
                    }
                }
            }
        }
        guard sawOpaque, sawTransparent else { return nil }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    /// Expands `rect` by `margin` (pixels) and clamps it to the image's bounds,
    /// so the padded crop can never ask for pixels outside the source.
    static func paddedCropRect(_ rect: CGRect, margin: CGFloat, in image: UIImage) -> CGRect {
        let oriented = image.upNormalized() ?? image
        let width = CGFloat(oriented.cgImage?.width ?? Int((image.size.width * image.scale).rounded()))
        let height = CGFloat(oriented.cgImage?.height ?? Int((image.size.height * image.scale).rounded()))
        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let expanded = rect.insetBy(dx: -max(0, margin), dy: -max(0, margin))
        let clamped = expanded.intersection(imageBounds)
        return clamped.isNull ? imageBounds : clamped
    }

    /// Crops `image` to its (padded) alpha bounds when it has meaningful
    /// transparency, so a small cut-out subject fills the canvas; returns the
    /// image unchanged when it is opaque or fully transparent.
    static func alphaFitted(_ image: UIImage) -> UIImage {
        guard let bounds = alphaBounds(of: image) else { return image }
        let oriented = image.upNormalized() ?? image
        guard let cgImage = oriented.cgImage else { return image }
        let crop = paddedCropRect(bounds, margin: alphaMargin, in: image).integral
        guard crop.width >= 1, crop.height >= 1,
              let cropped = cgImage.cropping(to: crop) else { return image }
        return UIImage(cgImage: cropped)
    }

    /// Union of `alphaBounds` across `images`, or `nil` when none has meaningful
    /// transparency. Used to crop a whole animation to ONE shared box so the
    /// subject fills the canvas without per-frame scale jitter.
    ///
    /// Early-out: when the FIRST frame has no transparency (the common non-cut
    /// path) this returns `nil` immediately, without scanning the remaining
    /// frames — an opaque video costs one scan, not one per frame.
    ///
    /// Bounds come from the (already mask-cleaned) frames. A box covering an
    /// implausibly large fraction of the frame (> 50%) is a broken mask and is
    /// dropped; a box far smaller than the median is a stray speck and is also
    /// dropped. The upper guard cannot clip a legitimately growing subject (a
    /// real subject stays well under half the canvas); a shrinking subject's
    /// smaller boxes are covered by the union of its larger ones.
    /// ponytail: area heuristics, not connected-component analysis — swap in blob
    /// filtering if specks ever survive the mask threshold.
    static func alphaUnion(of images: [UIImage]) -> CGRect? {
        guard let first = images.first, let firstBounds = alphaBounds(of: first) else {
            return nil
        }
        var bounds = [firstBounds]
        bounds.append(contentsOf: images.dropFirst().compactMap { alphaBounds(of: $0) })
        func unionAll(_ rects: [CGRect]) -> CGRect {
            rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        }
        // Too few frames to tell a bad mask from a real size change: keep all.
        guard bounds.count >= 4 else { return unionAll(bounds) }
        let oriented = first.upNormalized() ?? first
        let frameArea = CGFloat((oriented.cgImage?.width ?? 0) * (oriented.cgImage?.height ?? 0))
        let areas = bounds.map { $0.width * $0.height }.sorted()
        let median = areas[areas.count / 2]
        let kept = bounds.filter { box in
            let area = box.width * box.height
            if frameArea > 0, area > frameArea / 2 { return false } // bad-mask guard
            if median > 0, area < median / 8 { return false } // stray-speck guard
            return true
        }
        return unionAll(kept.isEmpty ? bounds : kept)
    }

    // MARK: - Frame preparation

    /// Draws every frame on the 512×512 canvas, clamps durations to the 8 ms
    /// floor and scales the whole animation down to the 10 s ceiling.
    ///
    /// A frame that is already a pixel-exact 512×512 upright canvas is reused
    /// as-is (same `UIImage`), so it never allocates a second pixel set. Only
    /// frames whose size or orientation actually differs are redrawn.
    private static func prepare(_ frames: [Frame]) -> [Frame] {
        var prepared: [Frame] = []
        prepared.reserveCapacity(frames.count)
        for frame in frames {
            let duration = max(frame.duration, Limits.minFrameDuration)
            if isCanvasReady(frame.image) {
                prepared.append(Frame(image: frame.image, duration: duration))
            } else if let canvas = autoreleasepool(invoking: { aspectFit(frame.image, in: canvasSize) }) {
                prepared.append(Frame(image: canvas, duration: duration))
            }
        }

        let total = prepared.reduce(0) { $0 + $1.duration }
        guard total > Limits.maxAnimationDuration else { return prepared }

        // Proportionally scale durations to fit 10 s.
        let scale = Limits.maxAnimationDuration / total
        prepared = prepared.map { Frame(image: $0.image, duration: $0.duration * scale) }

        // If scaling pushed a frame below the 8 ms floor, drop the shortest ones.
        if prepared.contains(where: { $0.duration < Limits.minFrameDuration }) {
            prepared = prepared.filter { $0.duration >= Limits.minFrameDuration }
        }
        return prepared
    }

    /// True when `image` is already a pixel-exact 512×512 upright canvas, so the
    /// frame can be reused without a redraw. Requires a bitmap backing, since the
    /// redraw path is also what materialises a `cgImage` for exotic inputs.
    private static func isCanvasReady(_ image: UIImage) -> Bool {
        guard image.imageOrientation == .up, image.cgImage != nil else { return false }
        let width = Int((image.size.width * image.scale).rounded())
        let height = Int((image.size.height * image.scale).rounded())
        return width == Limits.canvas && height == Limits.canvas
    }

    /// Test seam: runs the canvas-preparation step so tests can assert an
    /// already-512×512 upright frame is passed through without a redraw.
    static func preparedFramesForTesting(_ frames: [Frame]) -> [Frame] {
        prepare(frames)
    }

    #if DEBUG
    /// RGBA byte estimate for a frame set (`width × height × 4 bytes × count`).
    private static func rgbaBytes(_ frames: [Frame]) -> Int {
        frames.reduce(0) { total, frame in
            let width = Int((frame.image.size.width * frame.image.scale).rounded())
            let height = Int((frame.image.size.height * frame.image.scale).rounded())
            return total + width * height * 4
        }
    }

    /// Logs the prepared frame-set cost and the pre-release peak upper bound
    /// (`source + prepared`; pass-through frames share pixels, so the real peak is
    /// ≤ this) so device runs can confirm the single-set budget.
    private static func logPreparedBudget(_ frames: [Frame], sourceBytes: Int) {
        let preparedBytes = rgbaBytes(frames)
        print(String(
            format: "[StickerEncoder] prepared %d frames ≈ %.1f MB RGBA; peak ≤ %.1f MB (source %.1f + prepared)",
            frames.count,
            Double(preparedBytes) / 1_048_576,
            Double(sourceBytes + preparedBytes) / 1_048_576,
            Double(sourceBytes) / 1_048_576
        ))
    }
    #endif

    /// Frame durations as whole milliseconds. With a `targetDuration` the
    /// millisecond values sum exactly to it (never below the 8 ms floor); without
    /// one, each duration is truncated to milliseconds and clamped to the floor.
    private static func targetMilliseconds(_ frames: [Frame], targetDuration: TimeInterval?) -> [Int] {
        let floorMs = Int((Limits.minFrameDuration * 1000).rounded())
        guard let targetDuration, !frames.isEmpty else {
            return frames.map { max(floorMs, Int($0.duration * 1000 + 1e-6)) }
        }

        let count = frames.count
        let floorTotal = count * floorMs
        let requestedMs = Int((min(max(targetDuration, 0), Limits.maxAnimationDuration) * 1000).rounded())
        let totalMs = max(requestedMs, floorTotal)
        guard totalMs > 0 else { return Array(repeating: floorMs, count: count) }

        let base = totalMs / count
        let remainder = totalMs % count
        let result = (0..<count).map { base + ($0 < remainder ? 1 : 0) }
        #if DEBUG
        assert(result.reduce(0, +) == totalMs, "Animated frame durations must sum to the target")
        #endif
        return result
    }

    /// Absolute floor for the last-resort frame set. Preserving motion is worth
    /// more than fitting a noisy clip, so the ladder never drops below this.
    private static let minFramesLastResort = 8

    /// Fixed rungs (below the capped start) the frame ladder descends through, so
    /// a motion-heavy clip degrades in steps rather than jumping to a tiny set.
    private static let lastResortRungs = [120, 90, 60, 45, 30, 20, 16]

    /// Descending candidate frame counts for the size ladder. The start is capped
    /// at `maxLadderStart` (a cut clip never begins at 220/240 frames), then the
    /// list descends through `lastResortRungs` to `minFramesLastResort`. The source
    /// count itself is always included, so a small clip is tried at full length.
    /// Pure: no images — unit-testable.
    static func frameCandidateCounts(sourceCount: Int) -> [Int] {
        guard sourceCount >= 2 else { return [] }
        let start = min(sourceCount, maxLadderStart)
        var counts: Set<Int> = [start]
        for rung in lastResortRungs where rung < start && rung >= minFramesLastResort {
            counts.insert(rung)
        }
        if minFramesLastResort < start { counts.insert(minFramesLastResort) }
        return counts.sorted(by: >)
    }

    /// Picks `count` evenly-spaced frames and spreads the total duration across
    /// them, preserving the overall animation length.
    private static func resample(_ frames: [Frame], to count: Int) -> [Frame] {
        guard count >= 1, frames.count > count else { return frames }
        let total = frames.reduce(0) { $0 + $1.duration }
        let step = Double(frames.count) / Double(count)
        let duration = total / Double(count)
        return (0..<count).map { index in
            let source = frames[min(frames.count - 1, Int(Double(index) * step))]
            return Frame(image: source.image, duration: duration)
        }
    }

    // MARK: - Drawing

    private static let canvasSize = CGSize(
        width: CGFloat(Limits.canvas),
        height: CGFloat(Limits.canvas)
    )

    /// Redraws `image` aspect-fit (contain), centred, on a transparent square
    /// canvas of exactly `size` pixels. No border, stroke or background.
    private static func aspectFit(_ image: UIImage, in size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let source = image.upNormalized() ?? image
        let sourceSize = source.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let scale = min(size.width / sourceSize.width, size.height / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let origin = CGPoint(
            x: (size.width - drawSize.width) / 2,
            y: (size.height - drawSize.height) / 2
        )

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1 // pixel-exact canvas
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}

/// Pure encode-ladder policy: no images, no encoding — unit-testable.
///
/// Order: candidate frame counts DESCENDING (most frames first), qualities
/// ASCENDING (lowest first). At each candidate the lowest quality is tried first;
/// if even that overflows the budget, every higher quality would too, so the
/// candidate is abandoned and the next, smaller candidate is tried. When the
/// lowest quality fits, qualities ramp up while they fit and the highest fitting
/// quality wins. The first candidate (most frames) with any fit wins, so motion
/// is preserved at the best quality that fits.
struct EncodeLadder {
    enum Action: Equatable {
        /// Encode `frameCount` frames at `quality`.
        case encode(frameCount: Int, quality: Float)
        /// `frameCount`/`quality` is the largest fitting rung: return it.
        case win(frameCount: Int, quality: Float)
        /// Nothing fit: fail cleanly.
        case exhausted
    }

    /// Candidate frame counts, most frames first.
    let frameCounts: [Int]
    /// Qualities to try at each candidate, lowest first.
    let qualities: [Float]

    private var candidateIndex = 0
    private var qualityIndex = 0
    private var started = false

    init(frameCounts: [Int], qualities: [Float]) {
        self.frameCounts = frameCounts
        self.qualities = qualities
    }

    /// The first encode to run, or `.exhausted` when there is nothing to try.
    mutating func start() -> Action {
        guard !started else { return .exhausted }
        started = true
        candidateIndex = 0
        qualityIndex = 0
        guard let count = frameCounts.first, let quality = qualities.first else {
            return .exhausted
        }
        return .encode(frameCount: count, quality: quality)
    }

    /// Records whether the last `.encode` fit the budget and returns the next
    /// action.
    mutating func advance(fit: Bool) -> Action {
        guard started, candidateIndex < frameCounts.count, qualityIndex < qualities.count else {
            return .exhausted
        }
        if !fit {
            if qualityIndex == 0 {
                // Lowest quality overflows: the whole candidate is impossible.
                candidateIndex += 1
                qualityIndex = 0
                guard candidateIndex < frameCounts.count, let quality = qualities.first else {
                    return .exhausted
                }
                return .encode(frameCount: frameCounts[candidateIndex], quality: quality)
            }
            // A higher quality overflowed: the previous one was the best fit.
            return .win(
                frameCount: frameCounts[candidateIndex],
                quality: qualities[qualityIndex - 1]
            )
        }
        // Fits: try the next-higher quality.
        qualityIndex += 1
        guard qualityIndex < qualities.count else {
            return .win(
                frameCount: frameCounts[candidateIndex],
                quality: qualities[qualities.count - 1]
            )
        }
        return .encode(frameCount: frameCounts[candidateIndex], quality: qualities[qualityIndex])
    }
}

extension UIImage {
    /// Returns a copy with `.up` orientation so downstream pixel work is upright.
    func upNormalized() -> UIImage? {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Returns a copy whose longest side is at most `maxDimension` pixels.
    /// Returns `self` when already small enough.
    func scaled(toMaxDimension maxDimension: CGFloat) -> UIImage {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard maxDimension > 0, longest > maxDimension else { return self }

        let ratio = maxDimension / longest
        let target = CGSize(
            width: max(1, (pixelWidth * ratio).rounded()),
            height: max(1, (pixelHeight * ratio).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// Composes the independent creation stages (extraction → cut → compress →
/// saving) into ONE monotonically non-decreasing `0...1` fraction, so a progress
/// bar can never jump backwards and can never reach 100% before the payload
/// exists. Pure value type — no state beyond the last emitted value.
struct ProgressAccumulator {
    /// Ordered creation stages and the share of the overall bar each occupies.
    /// The weights sum to 1, so `update(_:in:)` always yields a value in `0...1`.
    enum Stage: CaseIterable {
        case extraction
        case cut
        case compression
        case saving

        var weight: Double {
            switch self {
            case .extraction: 0.30
            case .cut: 0.35
            case .compression: 0.30
            case .saving: 0.05
            }
        }

        /// Start of this stage's slice of the overall `0...1` range.
        var lowerBound: Double {
            Stage.allCases
                .prefix { $0 != self }
                .reduce(0) { $0 + $1.weight }
        }
    }

    private(set) var value: Double = 0

    /// Clamps `value` into `0...1` and never lets the accumulator decrease, so
    /// callers can forward raw per-stage fractions without ordering them.
    @discardableResult
    mutating func update(_ value: Double) -> Double {
        self.value = max(self.value, min(max(value, 0), 1))
        return self.value
    }

    /// Maps a stage-local `0...1` fraction into the composed overall fraction.
    @discardableResult
    mutating func update(_ fraction: Double, in stage: Stage) -> Double {
        update(stage.lowerBound + stage.weight * min(max(fraction, 0), 1))
    }
}
