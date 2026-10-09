#if DEBUG
import UIKit

/// Launch-argument flags for the DEBUG self-test / debug screen.
///
/// Compiled only in DEBUG. The app entry (`StickreateApp`) checks these inside
/// its own `#if DEBUG` branch, so a Release build never references them.
enum SelfTestLaunch {
    static let selfTestArgument = "-StickreateSelfTest"
    static let debugArgument = "-StickreateDebug"

    static var isSelfTest: Bool {
        ProcessInfo.processInfo.arguments.contains(selfTestArgument)
    }

    static var isDebug: Bool {
        ProcessInfo.processInfo.arguments.contains(debugArgument)
    }
}

/// DEBUG-only synthetic self-test.
///
/// Uses only generated fixtures — no bundled assets, no network, no UI. Each
/// check catches its own error and records pass/fail; `run()` never throws and
/// never crashes. The whole file is `#if DEBUG`, so none of it exists in a
/// Release/App Store build.
enum SelfTest {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs every check, writes `selftest-report.json` to Documents and logs one
    /// summary line. Returns the report for the result screen.
    @discardableResult
    static func run() -> SelfTestReport {
        let started = Date()
        let clock = CFAbsoluteTimeGetCurrent()

        let solid = makeFixtureImage(index: 0)
        let packBuild: Result<StickerPack, Error> = Result { try makePack() }

        var checks: [SelfTestReport.Check] = []
        checks.append(staticCheck(solid))
        checks.append(animatedCheck())
        checks.append(packValidationCheck(packBuild))
        checks.append(archiveCheck(packBuild))
        checks.append(whatsAppPayloadCheck(packBuild))
        checks.append(worstCaseCheck())

        let totalMS = ms(since: clock)
        let report = SelfTestReport(startedAt: started, checks: checks, totalDurationMS: totalMS)
        report.persist()
        Log.selfTest.info("\(report.summary, privacy: .public)")
        return report
    }

    // MARK: - Checks

    /// Static sticker encodes and stays within the 100 KB budget.
    private static func staticCheck(_ image: UIImage?) -> SelfTestReport.Check {
        measure("static ≤100 KB") {
            guard let image else { throw Failure(message: "fixture image unavailable") }
            let clock = CFAbsoluteTimeGetCurrent()
            guard let data = StickerEncoder.staticSticker(from: image) else {
                throw Failure(message: "StickerEncoder.staticSticker returned nil")
            }
            let elapsed = ms(since: clock)
            Log.encode.info("static \(data.count, privacy: .public) bytes in \(Int(elapsed), privacy: .public)ms")
            guard data.count <= Limits.maxStaticBytes else {
                throw Failure(message: "\(kb(data.count)) KB exceeds \(kb(Limits.maxStaticBytes)) KB")
            }
            return "\(kb(data.count)) KB in \(Int(elapsed)) ms"
        }
    }

    /// Animated sticker from generated frames stays within the 500 KB budget.
    private static func animatedCheck() -> SelfTestReport.Check {
        measure("animated ≤500 KB") {
            let frames = makeMovingFrames(count: 12)
            guard frames.count >= 2 else { throw Failure(message: "fixture frames unavailable") }
            Log.extraction.info("synthetic \(frames.count, privacy: .public) frames generated")
            let clock = CFAbsoluteTimeGetCurrent()
            guard let data = StickerEncoder.animatedSticker(from: frames) else {
                throw Failure(message: "StickerEncoder.animatedSticker returned nil")
            }
            let elapsed = ms(since: clock)
            Log.encode.info(
                "animated \(frames.count, privacy: .public) frames -> \(data.count, privacy: .public) bytes"
            )
            guard data.count <= Limits.maxAnimatedBytes else {
                throw Failure(message: "\(kb(data.count)) KB exceeds \(kb(Limits.maxAnimatedBytes)) KB")
            }
            return "\(frames.count) frames, \(kb(data.count)) KB in \(Int(elapsed)) ms"
        }
    }

    /// A 3-sticker pack validates against `Limits` / `StickerPack.validate()`.
    private static func packValidationCheck(_ build: Result<StickerPack, Error>) -> SelfTestReport.Check {
        measure("pack validation (3 static)") {
            let pack = try build.get()
            try pack.validate()
            guard pack.stickers.count == Limits.minStickers else {
                throw Failure(message: "expected \(Limits.minStickers) stickers, got \(pack.stickers.count)")
            }
            guard !pack.isMixed else { throw Failure(message: "pack reports mixed kinds") }
            return "\(pack.stickers.count) stickers, single kind, validate() OK"
        }
    }

    /// `.wasticker` export → re-import preserves sticker bytes, count and order.
    private static func archiveCheck(_ build: Result<StickerPack, Error>) -> SelfTestReport.Check {
        measure("archive round-trip") {
            let pack = try build.get()
            let data = try PackArchive.exportData(pack)
            let imported = try PackArchive.importPack(from: data)
            guard imported.stickers.count == pack.stickers.count else {
                throw Failure(message: "count \(imported.stickers.count) ≠ \(pack.stickers.count)")
            }
            for (index, pair) in zip(pack.stickers, imported.stickers).enumerated() {
                guard pair.0.stickerData == pair.1.stickerData else {
                    throw Failure(message: "sticker \(index + 1) bytes differ after round-trip")
                }
            }
            return "\(imported.stickers.count) stickers, bytes+order preserved (\(kb(data.count)) KB)"
        }
    }

    /// Builds the WhatsApp payload and validates its JSON — WITHOUT opening
    /// WhatsApp or touching the pasteboard.
    ///
    /// `WhatsAppExporter.export` has no non-opening entry point and is out of
    /// scope to edit, so this rebuilds the exact payload shape (same pasteboard
    /// payload keys, same base64 WebP/tray encoding) and asserts it is valid.
    /// ponytail: duplicate of WhatsAppExporter; extract a pure non-opening
    /// `payload(...) -> Data?` there in a later phase and call it from here.
    private static func whatsAppPayloadCheck(_ build: Result<StickerPack, Error>) -> SelfTestReport.Check {
        measure("whatsapp payload (no open)") {
            let pack = try build.get()
            guard let first = pack.stickers.first,
                  let preview = UIImage(data: first.previewData),
                  let tray = StickerEncoder.trayIcon(from: preview) else {
                throw Failure(message: "couldn't build the tray icon")
            }
            let stickerJSON: [[String: Any]] = pack.stickers.map { sticker in
                [
                    "image_data": sticker.stickerData.base64EncodedString(),
                    "emojis": Array(sticker.emojis.prefix(Limits.maxEmojisPerSticker)),
                    "accessibility_text": String(pack.name.prefix(125))
                ]
            }
            let payload: [String: Any] = [
                "identifier": sanitized(pack.id.uuidString),
                "name": String(pack.name.prefix(128)),
                "publisher": String(pack.publisher.prefix(128)),
                "tray_image": tray.base64EncodedString(),
                "stickers": stickerJSON
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload) else {
                throw Failure(message: "payload isn't valid JSON")
            }
            guard tray.count <= Limits.maxTrayBytes else {
                throw Failure(message: "tray \(kb(tray.count)) KB exceeds \(kb(Limits.maxTrayBytes)) KB")
            }
            return "\(pack.stickers.count) stickers, payload \(kb(data.count)) KB, tray \(kb(tray.count)) KB"
        }
    }

    /// Worst-case (high-entropy noise) clip encodes within budget; time recorded.
    private static func worstCaseCheck() -> SelfTestReport.Check {
        measure("worst-case clip within budget") {
            let frames = makeNoiseFrames(count: 6)
            guard frames.count >= 2 else { throw Failure(message: "noise fixture unavailable") }
            let clock = CFAbsoluteTimeGetCurrent()
            guard let data = StickerEncoder.animatedSticker(from: frames) else {
                throw Failure(message: "encoder returned nil for a noise clip")
            }
            let elapsed = ms(since: clock)
            Log.encode.info(
                "worst-case \(frames.count, privacy: .public) noise frames -> \(data.count, privacy: .public) bytes in \(Int(elapsed), privacy: .public)ms"
            )
            guard data.count <= Limits.maxAnimatedBytes else {
                throw Failure(message: "\(kb(data.count)) KB exceeds \(kb(Limits.maxAnimatedBytes)) KB")
            }
            return "\(frames.count) noise frames, \(kb(data.count)) KB in \(Int(elapsed)) ms"
        }
    }

    // MARK: - Harness

    private static func measure(_ name: String, _ body: () throws -> String) -> SelfTestReport.Check {
        let clock = CFAbsoluteTimeGetCurrent()
        do {
            let detail = try body()
            return SelfTestReport.Check(name: name, passed: true, durationMS: ms(since: clock), detail: detail)
        } catch {
            return SelfTestReport.Check(
                name: name,
                passed: false,
                durationMS: ms(since: clock),
                detail: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }

    private static func ms(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    // MARK: - Fixtures (generated in code, no bundled assets)

    private static func makePack() throws -> StickerPack {
        var items: [StickerItem] = []
        items.reserveCapacity(Limits.minStickers)
        for index in 0..<Limits.minStickers {
            guard let image = makeFixtureImage(index: index),
                  let sticker = StickerEncoder.staticSticker(from: image),
                  let preview = StickerEncoder.previewPNG(from: image, size: CGFloat(Limits.canvas)) else {
                throw Failure(message: "couldn't build fixture sticker \(index + 1)")
            }
            items.append(StickerItem(kind: .static, stickerData: sticker, previewData: preview))
        }
        return StickerPack(name: "SelfTest Pack", stickers: items)
    }

    /// A 512×512 fixture: gradient background with a coloured disc (varied by index).
    private static func makeFixtureImage(index: Int) -> UIImage? {
        makeImage(side: Limits.canvas) { x, y in
            let fx = Double(x) / Double(Limits.canvas)
            let fy = Double(y) / Double(Limits.canvas)
            let dx = fx - 0.5
            let dy = fy - 0.5
            if dx * dx + dy * dy < 0.12 {
                let r = UInt8((index * 70 + 60) % 255)
                return (r, 90, 200, 255)
            }
            return (UInt8(fx * 180), UInt8(fy * 180), 40, 255)
        }
    }

    /// A short sequence where a bright square moves left→right.
    private static func makeMovingFrames(count: Int) -> [Frame] {
        (0..<count).compactMap { item -> Frame? in
            let t = Double(item) / Double(max(1, count - 1))
            guard let image = makeImage(side: Limits.canvas, pixel: { x, y in
                let fx = Double(x) / Double(Limits.canvas)
                let fy = Double(y) / Double(Limits.canvas)
                let center = 0.15 + 0.7 * t
                let inSquare = abs(fx - center) < 0.15 && abs(fy - 0.5) < 0.25
                return inSquare ? (250, 240, 60, 255) : (30, 30, 40, 255)
            }) else { return nil }
            return Frame(image: image, duration: 0.08)
        }
    }

    /// Pseudo-random noise frames — nearly incompressible, i.e. worst case.
    private static func makeNoiseFrames(count: Int) -> [Frame] {
        var seed: UInt64 = 0x1234_5678_9ABC_DEF0
        func next() -> UInt8 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8((seed >> 40) & 0xFF)
        }
        return (0..<count).compactMap { _ -> Frame? in
            guard let image = makeImage(side: Limits.canvas, pixel: { _, _ in
                (next(), next(), next(), 255)
            }) else { return nil }
            return Frame(image: image, duration: 0.08)
        }
    }

    /// Builds an opaque 512×512 `UIImage` from a per-pixel closure.
    private static func makeImage(
        side: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> UIImage? {
        let bytesPerRow = side * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * side)
        for y in 0..<side {
            let row = y * bytesPerRow
            for x in 0..<side {
                let (r, g, b, a) = pixel(x, y)
                let offset = row + x * 4
                bytes[offset] = r
                bytes[offset + 1] = g
                bytes[offset + 2] = b
                bytes[offset + 3] = a
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// WhatsApp identifier charset: a-z A-Z 0-9 _ - . space, ≤ 128.
    private static func sanitized(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_- .")
        return String(value.filter { allowed.contains($0) }.prefix(128))
    }

    private static func kb(_ bytes: Int) -> String {
        "\(bytes / 1024)"
    }
}
#endif
