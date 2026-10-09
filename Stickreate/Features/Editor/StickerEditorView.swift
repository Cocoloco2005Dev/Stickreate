import SwiftUI
import UIKit

/// "Adjust" editor for a single still image.
///
/// Checkerboard canvas with pinch-to-zoom / drag-to-pan above a control layer:
/// a contextual row, a 2×N tool grid, and the Cancel · undo/redo · Apply bar.
/// Everything is non-destructive through `MaskEditor`. Background removal is
/// `Intelligent Cut`: it opens the VisionKit subject-lift step
/// (`SubjectLiftView`), where press-and-hold behaves exactly like Photos and
/// the lifted cut-out is dragged into a target to use it. The cut-out becomes
/// the working image directly (transparent background, mask keeps everything),
/// so the manual tools refine the real subject instead of a mapped mask.
/// Nothing is removed until the user asks for it.
@MainActor
struct StickerEditorView: View {
    let source: StickerSource
    let onDone: (StickerItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var editor: MaskEditor?
    @State private var isLoading = true
    @State private var didLoad = false
    @State private var loadErrorMessage: String?

    @State private var activeTool: Tool = .original
    @State private var hasCommittedChange = false

    /// Keep / Remove intent for Rectangle and Lasso (and the paint concept for
    /// Brush/Erase). A mode, never a commit action.
    @State private var selectionMode: SelectionMode = .remove

    // Canvas transform
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var panning = false
    @State private var magnifying = false
    @State private var showZoomHint = true
    @State private var didSetInitialZoom = false
    @State private var canvasSize: CGSize = .zero

    // Brush
    @State private var lastPoint: CGPoint?

    // Region tools (normalized image coordinates, top-left origin)
    @State private var selectionStart: CGPoint?
    @State private var selectionRect: CGRect?
    @State private var lassoPoints: [CGPoint] = []

    // Crop
    @State private var cropRect = StickerEditorView.fullCrop
    @State private var cropInitialRect = StickerEditorView.fullCrop
    @State private var cropDragging = false
    @State private var cropActiveHandle: CropHandle?

    // Intelligent Cut / VisionKit subject lift
    /// Presents the full-screen press-and-hold subject-lift step.
    @State private var showSubjectLift = false
    /// True once a lifted cut-out has been seeded into the editable mask.
    @State private var hasLiftedSubject = false
    @State private var instanceFeedback: String?
    @State private var feedbackTask: Task<Void, Never>?

    // Apply / encode
    @State private var isSaving = false
    @State private var applyStage: StickerCreationStage?

    @State private var alertMessage: String?
    @State private var successPulse = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let maxZoom: CGFloat = 5
    private static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    private var hasCrop: Bool {
        cropRect.minX > 0.001 || cropRect.minY > 0.001
            || cropRect.width < 0.999 || cropRect.height < 0.999
    }

    /// Apply is available once the user has changed the mask or framed a crop.
    private var hasEdits: Bool { hasCommittedChange || hasCrop }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if let editor {
                    canvas(editor)
                } else if isLoading {
                    LoadingState(title: "Preparing photo…")
                } else {
                    EmptyState(
                        symbol: "exclamationmark.triangle",
                        title: "Couldn't Open This Photo",
                        message: loadErrorMessage ?? "Try choosing a different photo."
                    ) {
                        Button("Try Again") { retry() }
                            .buttonStyle(.glassProminent)
                        Button("Cancel", role: .cancel) { dismiss() }
                            .buttonStyle(.glass)
                    }
                }
            }
            .navigationTitle("Adjust")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .bottom) {
                if editor != nil {
                    controlLayer
                }
            }
            .overlay {
                if isSaving {
                    busyOverlay(title: applyProgressText, subtitle: nil)
                }
            }
            .alert("Something went wrong", isPresented: alertBinding) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .haptic(.success, trigger: successPulse)
            .announceOnChange(of: applyStage.announcementPhase) { $0 }
        }
        .task { await load() }
        .fullScreenCover(isPresented: $showSubjectLift) { subjectLiftCover }
    }

    // MARK: - Canvas

    private func canvas(_ editor: MaskEditor) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = StickerGeometry.imageFrame(
                canvas: size,
                imageSize: editor.base.size,
                zoom: zoom,
                pan: pan
            )

            ZStack {
                CheckerboardView()

                Image(uiImage: editor.preview)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                    .shadow(
                        color: .black.opacity(hasLiftedSubject ? 0.35 : 0),
                        radius: hasLiftedSubject ? 14 : 0,
                        y: hasLiftedSubject ? 8 : 0
                    )
                    .animation(reduceMotion ? nil : DS.Motion.quick, value: hasLiftedSubject)
                    .position(x: frame.midX, y: frame.midY)

                canvasOverlay(frame: frame)

                if let instanceFeedback {
                    infoPill(instanceFeedback)
                }

                if showZoomHint && !isSaving {
                    zoomHint
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(editor: editor, frame: frame, canvas: size))
            .simultaneousGesture(magnifyGesture(canvas: size, imageSize: editor.base.size))
            .onAppear {
                canvasSize = size
                applyInitialZoom(canvas: size, imageSize: editor.base.size)
            }
            .onChange(of: size) { _, newSize in
                canvasSize = newSize
                applyInitialZoom(canvas: newSize, imageSize: editor.base.size)
            }
        }
    }

    private var zoomHint: some View {
        VStack {
            Spacer()
            Text("Pinch to zoom in and out")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .padding(.bottom, 18)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func infoPill(_ text: String) -> some View {
        VStack {
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .padding(.top, 14)
            Spacer()
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: - Canvas overlays

    @ViewBuilder
    private func canvasOverlay(frame: CGRect) -> some View {
        if activeTool == .crop || hasCrop {
            cropOverlay(frame: frame)
        }

        if activeTool == .rectangle, let rect = selectionRect {
            regionOverlay(path: Path { $0.addRect(canvasRect(rect, in: frame)) })
        } else if activeTool == .lasso, lassoPoints.count >= 2 {
            regionOverlay(path: lassoPath(frame: frame))
        }
    }

    /// Dims outside the crop rect, draws rule-of-thirds guides, a white border,
    /// and (while Crop is active) draggable corner handles.
    private func cropOverlay(frame: CGRect) -> some View {
        let crop = cropFrame(frame: frame)
        let active = activeTool == .crop
        let corners = cornerPoints(of: crop)

        return ZStack {
            Path { path in
                path.addRect(frame)
                path.addRect(crop)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                for index in 1...2 {
                    let x = crop.minX + crop.width * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: crop.minY))
                    path.addLine(to: CGPoint(x: x, y: crop.maxY))
                    let y = crop.minY + crop.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: crop.minX, y: y))
                    path.addLine(to: CGPoint(x: crop.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 1)
            .allowsHitTesting(false)

            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: max(crop.width, 1), height: max(crop.height, 1))
                .position(x: crop.midX, y: crop.midY)
                .allowsHitTesting(false)

            if active {
                ForEach(corners.indices, id: \.self) { index in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(DS.ColorRole.accent, lineWidth: 3))
                        .shadow(radius: 2)
                        .position(corners[index])
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crop area")
        .accessibilityValue(Text(cropAccessibilityValue))
        .accessibilityHint("Swipe up or down to resize the crop")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjustCrop(expanding: true)
            case .decrement: adjustCrop(expanding: false)
            @unknown default: break
            }
        }
    }

    /// Dashed region overlay tinted by the current Keep / Remove intent.
    private func regionOverlay(path: Path) -> some View {
        ZStack {
            path.fill(selectionMode.color.opacity(0.18))
            path.stroke(selectionMode.color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        .allowsHitTesting(false)
    }

    private func lassoPath(frame: CGRect) -> Path {
        var path = Path()
        let points = lassoPoints.map { StickerGeometry.canvasPoint($0, in: frame) }
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    // MARK: - Gestures

    private func dragGesture(editor: MaskEditor, frame: CGRect, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if showZoomHint { showZoomHint = false }
                guard !magnifying else { return }

                switch activeTool {
                case .brush, .erase:
                    draw(editor: editor, value: value, frame: frame)
                case .rectangle:
                    updateRectSelection(value: value, frame: frame)
                case .lasso:
                    updateLasso(value: value, frame: frame)
                case .crop:
                    updateCrop(value: value, frame: frame)
                case .original, .aiCut:
                    panCanvas(value: value, canvas: canvas, imageSize: editor.base.size)
                }
            }
            .onEnded { _ in
                guard !magnifying else { return }

                switch activeTool {
                case .brush, .erase:
                    if lastPoint != nil {
                        editor.endStroke()
                        hasCommittedChange = true
                    }
                    lastPoint = nil
                case .rectangle:
                    commitRectSelection(editor: editor)
                case .lasso:
                    commitLasso(editor: editor)
                case .crop:
                    finishCrop()
                case .original, .aiCut:
                    panning = false
                    panStart = pan
                }
            }
    }

    private func magnifyGesture(canvas: CGSize, imageSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if showZoomHint { showZoomHint = false }
                if !magnifying {
                    magnifying = true
                    zoomStart = zoom
                    panStart = pan
                }
                zoom = min(max(zoomStart * value.magnification, 1), maxZoom)
                pan = StickerGeometry.clampedPan(pan, canvas: canvas, imageSize: imageSize, zoom: zoom)
            }
            .onEnded { _ in
                magnifying = false
                zoomStart = zoom
                panStart = pan
                pan = StickerGeometry.clampedPan(pan, canvas: canvas, imageSize: imageSize, zoom: zoom)
            }
    }

    private func draw(editor: MaskEditor, value: DragGesture.Value, frame: CGRect) {
        let point = StickerGeometry.normalized(value.location, in: frame)
        if lastPoint == nil { editor.beginStroke() }
        editor.stroke(
            from: lastPoint ?? point,
            to: point,
            restoring: activeTool == .brush
        )
        lastPoint = point
    }

    private func panCanvas(value: DragGesture.Value, canvas: CGSize, imageSize: CGSize) {
        if !panning {
            panning = true
            panStart = pan
        }
        let candidate = CGSize(
            width: panStart.width + value.translation.width,
            height: panStart.height + value.translation.height
        )
        pan = StickerGeometry.clampedPan(candidate, canvas: canvas, imageSize: imageSize, zoom: zoom)
    }

    private func updateRectSelection(value: DragGesture.Value, frame: CGRect) {
        let start = selectionStart ?? StickerGeometry.normalized(value.startLocation, in: frame)
        selectionStart = start
        let current = StickerGeometry.normalized(value.location, in: frame)
        selectionRect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func commitRectSelection(editor: MaskEditor) {
        defer {
            selectionStart = nil
            selectionRect = nil
        }
        guard let rect = selectionRect, rect.width > 0.01, rect.height > 0.01 else { return }
        editor.selectRectangle(rect, removing: selectionMode.removing)
        hasCommittedChange = true
    }

    private func updateLasso(value: DragGesture.Value, frame: CGRect) {
        let point = StickerGeometry.normalized(value.location, in: frame)
        if let last = lassoPoints.last {
            let dx = point.x - last.x
            let dy = point.y - last.y
            if dx * dx + dy * dy < 0.00002 { return }
        }
        lassoPoints.append(point)
    }

    private func commitLasso(editor: MaskEditor) {
        defer { lassoPoints = [] }
        guard lassoPoints.count >= 3 else { return }
        editor.selectLasso(lassoPoints, removing: selectionMode.removing)
        hasCommittedChange = true
    }

    // MARK: - VisionKit subject lift

    /// Full-screen VisionKit step. Press-and-hold lifts a subject exactly like
    /// Photos; the user drags the cut-out into a target, then we adopt it.
    @ViewBuilder
    private var subjectLiftCover: some View {
        if let editor {
            SubjectLiftView(image: editor.base) { cutout in
                applyLiftedSubject(cutout)
            }
        }
    }

    /// Adopts the VisionKit cut-out as the working image directly. The
    /// background is already removed, so the mask starts as "keep everything"
    /// and there is no alpha-to-mask bridge to misalign. Restore, Erase,
    /// Rectangle, Lasso, Crop and Original now operate on the clean cut-out.
    private func applyLiftedSubject(_ cutout: UIImage) {
        guard let editor else { return }
        guard cutout.size.width > 0, cutout.size.height > 0 else {
            alertMessage = "Couldn't read the lifted subject."
            return
        }
        let radius = editor.brushRadius
        let updated = MaskEditor(base: cutout, mask: nil, maxDimension: 1024)
        updated.brushRadius = radius
        self.editor = updated
        activeTool = .aiCut
        hasLiftedSubject = true
        hasCommittedChange = true
        applyInitialZoom(canvas: canvasSize, imageSize: updated.base.size, force: true)
        successPulse += 1
        flash("Subject lifted · refine with the manual tools.", duration: 2.0)
    }

    private func flash(_ text: String, duration: TimeInterval = 1.2) {
        instanceFeedback = text
        feedbackTask?.cancel()
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            if Task.isCancelled { return }
            instanceFeedback = nil
        }
    }

    // MARK: - Crop gestures

    private func updateCrop(value: DragGesture.Value, frame: CGRect) {
        if !cropDragging {
            cropDragging = true
            cropInitialRect = cropRect
            cropActiveHandle = cropHandle(at: value.startLocation, in: cropFrame(frame: frame))
        }

        let handle = cropActiveHandle ?? .new
        if handle == .new {
            let start = StickerGeometry.normalized(value.startLocation, in: frame)
            let current = StickerGeometry.normalized(value.location, in: frame)
            cropRect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
        } else {
            cropRect = updatedCropRect(
                handle: handle,
                initial: cropInitialRect,
                translation: value.translation,
                frame: frame
            )
        }
    }

    private func finishCrop() {
        cropDragging = false
        cropActiveHandle = nil
        if cropRect.width < 0.08 || cropRect.height < 0.08 {
            cropRect = Self.fullCrop
        }
    }

    private func resetCrop() {
        cropRect = Self.fullCrop
        cropInitialRect = Self.fullCrop
        cropDragging = false
        cropActiveHandle = nil
    }

    /// Bakes the current crop into the working image and keeps editing open.
    /// Only the final Apply commits and dismisses.
    private func applyCropNow() {
        guard let editor, hasCrop else { return }
        editor.applyCrop(cropRect)
        resetCrop()
        hasCommittedChange = true
        applyInitialZoom(canvas: canvasSize, imageSize: editor.base.size, force: true)
        flash("Crop applied")
    }

    private func cropHandle(at point: CGPoint, in crop: CGRect) -> CropHandle {
        guard hasCrop else { return .new }
        let threshold: CGFloat = 44
        let corners: [(CropHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: crop.minX, y: crop.minY)),
            (.topRight, CGPoint(x: crop.maxX, y: crop.minY)),
            (.bottomLeft, CGPoint(x: crop.minX, y: crop.maxY)),
            (.bottomRight, CGPoint(x: crop.maxX, y: crop.maxY))
        ]
        for (handle, corner) in corners {
            let dx = point.x - corner.x
            let dy = point.y - corner.y
            if (dx * dx + dy * dy).squareRoot() <= threshold { return handle }
        }
        if crop.insetBy(dx: -24, dy: -24).contains(point) { return .move }
        return .new
    }

    private func updatedCropRect(
        handle: CropHandle,
        initial: CGRect,
        translation: CGSize,
        frame: CGRect
    ) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return initial }
        let dx = translation.width / frame.width
        let dy = translation.height / frame.height
        let minSize: CGFloat = 0.08

        switch handle {
        case .move:
            let x = min(max(0, initial.minX + dx), 1 - initial.width)
            let y = min(max(0, initial.minY + dy), 1 - initial.height)
            return CGRect(x: x, y: y, width: initial.width, height: initial.height)

        case .topLeft:
            let x = min(max(0, initial.minX + dx), initial.maxX - minSize)
            let y = min(max(0, initial.minY + dy), initial.maxY - minSize)
            return CGRect(x: x, y: y, width: initial.maxX - x, height: initial.maxY - y)

        case .topRight:
            let maxX = max(min(1, initial.maxX + dx), initial.minX + minSize)
            let y = min(max(0, initial.minY + dy), initial.maxY - minSize)
            return CGRect(x: initial.minX, y: y, width: maxX - initial.minX, height: initial.maxY - y)

        case .bottomLeft:
            let x = min(max(0, initial.minX + dx), initial.maxX - minSize)
            let maxY = max(min(1, initial.maxY + dy), initial.minY + minSize)
            return CGRect(x: x, y: initial.minY, width: initial.maxX - x, height: maxY - initial.minY)

        case .bottomRight:
            let maxX = max(min(1, initial.maxX + dx), initial.minX + minSize)
            let maxY = max(min(1, initial.maxY + dy), initial.minY + minSize)
            return CGRect(x: initial.minX, y: initial.minY, width: maxX - initial.minX, height: maxY - initial.minY)

        case .new:
            return initial
        }
    }

    // MARK: - Coordinate convention
    //
    // `StickerGeometry` maps a canvas touch onto normalized 0...1 coordinates
    // with a TOP-LEFT origin, against the exact displayed image rect (letterbox,
    // zoom and pan included). `MaskEditor` (stroke, selectRectangle, selectLasso,
    // instanceID(at:), render(croppedTo:), applyCrop) uses the SAME top-left
    // convention, so no Y conversion is needed at this boundary.

    // MARK: - Geometry

    /// Fills the canvas at open so the image doesn't sit inside wide checkerboard
    /// margins, capped so extreme aspect ratios don't crop too aggressively.
    private func applyInitialZoom(canvas: CGSize, imageSize: CGSize, force: Bool = false) {
        guard force || !didSetInitialZoom,
              canvas.width > 0, canvas.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return }
        didSetInitialZoom = true
        let fit = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let fill = max(canvas.width / imageSize.width, canvas.height / imageSize.height)
        guard fit > 0 else { return }
        zoom = min(max(fill / fit, 1), 2)
        pan = .zero
    }

    private func cropFrame(frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + cropRect.minX * frame.width,
            y: frame.minY + cropRect.minY * frame.height,
            width: cropRect.width * frame.width,
            height: cropRect.height * frame.height
        )
    }

    private func canvasRect(_ normalized: CGRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + normalized.minX * frame.width,
            y: frame.minY + normalized.minY * frame.height,
            width: normalized.width * frame.width,
            height: normalized.height * frame.height
        )
    }

    private func cornerPoints(of crop: CGRect) -> [CGPoint] {
        [
            CGPoint(x: crop.minX, y: crop.minY),
            CGPoint(x: crop.maxX, y: crop.minY),
            CGPoint(x: crop.minX, y: crop.maxY),
            CGPoint(x: crop.maxX, y: crop.maxY)
        ]
    }

    /// VoiceOver value for the crop rect, in normalized percentages.
    private var cropAccessibilityValue: String {
        let x = Int((cropRect.minX * 100).rounded())
        let y = Int((cropRect.minY * 100).rounded())
        let width = Int((cropRect.width * 100).rounded())
        let height = Int((cropRect.height * 100).rounded())
        return "x \(x) percent, y \(y) percent, \(width) percent wide, \(height) percent tall"
    }

    /// VoiceOver-adjustable resize of the crop, kept centered and in bounds.
    private func adjustCrop(expanding: Bool) {
        let step: CGFloat = 0.05
        let delta = expanding ? step : -step
        let minSize: CGFloat = 0.1
        let newWidth = min(max(cropRect.width + delta, minSize), 1)
        let newHeight = min(max(cropRect.height + delta, minSize), 1)
        let x = min(max(0, cropRect.midX - newWidth / 2), 1 - newWidth)
        let y = min(max(0, cropRect.midY - newHeight / 2), 1 - newHeight)
        cropRect = CGRect(x: x, y: y, width: newWidth, height: newHeight)
    }

    // MARK: - Control layer

    private var controlLayer: some View {
        VStack(spacing: 12) {
            contextRow

            toolGrid

            Divider()

            actionBar
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.md)
        .padding(.bottom, DS.Space.xs)
        .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Divider() }
        .animation(reduceMotion ? nil : DS.Motion.standard, value: activeTool)
    }

    @ViewBuilder
    private var contextRow: some View {
        switch activeTool {
        case .brush, .erase:
            VStack(spacing: 6) {
                brushRow
                Text(activeTool == .brush
                     ? "Restore brings removed pixels back."
                     : "Erase removes pixels.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .rectangle, .lasso:
            VStack(spacing: 6) {
                modeToggle
                Text("Applies to Rectangle and Lasso · Keep restores pixels, Remove erases them.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .crop:
            VStack(spacing: 8) {
                Text("Frame the image, then Apply crop to bake it into the photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button("Reset") { resetCrop() }
                        .buttonStyle(.glass)
                        .frame(minHeight: 44)
                        .disabled(!hasCrop)
                        .accessibilityLabel("Reset crop")

                    Button("Apply crop") { applyCropNow() }
                        .buttonStyle(.glass)
                        .frame(minHeight: 44)
                        .disabled(!hasCrop)
                        .accessibilityLabel("Apply crop to the working image")
                }
            }

        case .aiCut:
            VStack(spacing: 8) {
                if hasLiftedSubject {
                    Text("Subject lifted. Refine with Restore, Erase, Rectangle, Lasso or Crop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Lift Another Subject") { showSubjectLift = true }
                        .buttonStyle(.glass)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Open the subject lift step again")
                } else {
                    Text("Intelligent Cut lifts subjects on-device with VisionKit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Lift Subject") { showSubjectLift = true }
                        .buttonStyle(.glass)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Open the subject lift step")
                }
            }

        case .original:
            Text("Brings back the whole image. Nothing is removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var brushRow: some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Slider(value: brushBinding, in: 0.02...0.3)
                .accessibilityLabel("Paint size")
                .accessibilityValue(Text(brushAccessibilityValue))

            Image(systemName: "circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DS.Space.xs)
    }

    // MARK: - Keep / Remove (equal-weight mode control)

    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeSegment(.keep)
            modeSegment(.remove)
        }
        .padding(2)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }

    private func modeSegment(_ mode: SelectionMode) -> some View {
        let selected = selectionMode == mode
        return Button {
            selectionMode = mode
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.footnote.weight(.semibold))
                Text(mode.title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background {
                if selected {
                    Capsule()
                        .fill(Color(uiColor: .systemBackground))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title) mode")
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    // MARK: - Tool grid

    private var toolGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                toolButton(.aiCut)
                toolButton(.rectangle)
                toolButton(.lasso)
                toolButton(.crop)
            }
            HStack(spacing: 8) {
                toolButton(.original)
                toolButton(.brush)
                toolButton(.erase)
            }
        }
    }

    private func toolButton(_ tool: Tool) -> some View {
        let selected = activeTool == tool
        return Button {
            select(tool)
        } label: {
            VStack(spacing: DS.Space.sm) {
                Image(systemName: tool.symbol)
                    .font(.title3)
                    .frame(width: 36, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                            .fill(selected ? Color(uiColor: .systemGray5) : Color.clear)
                    )

                Text(tool.title)
                    .font(DS.TextRole.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: DS.Space.sm) {
            Button("Cancel") { cancel() }
                .fontWeight(.medium)
                .foregroundStyle(DS.ColorRole.accent)
                .frame(minWidth: DS.minTapTarget, minHeight: DS.minTapTarget, alignment: .leading)

            Spacer(minLength: 0)

            Button {
                editor?.undo()
                hasCommittedChange = true
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.body.weight(.medium))
                    .frame(width: DS.minTapTarget, height: DS.minTapTarget)
            }
            .buttonStyle(.glass)
            .disabled(!(editor?.canUndo ?? false))
            .accessibilityLabel("Undo")

            Button {
                editor?.redo()
                hasCommittedChange = true
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.body.weight(.medium))
                    .frame(width: DS.minTapTarget, height: DS.minTapTarget)
            }
            .buttonStyle(.glass)
            .disabled(!(editor?.canRedo ?? false))
            .accessibilityLabel("Redo")

            Spacer(minLength: 0)

            Button("Apply") { apply() }
                .buttonStyle(.glassProminent)
                .disabled(!hasEdits || isSaving)
                .frame(minWidth: DS.minTapTarget, minHeight: DS.minTapTarget, alignment: .trailing)
                .accessibilityLabel("Apply changes")
        }
        .font(.body)
    }

    // MARK: - Tool state

    private var brushBinding: Binding<CGFloat> {
        Binding(
            get: { editor?.brushRadius ?? 0.08 },
            set: { editor?.brushRadius = $0 }
        )
    }

    private var brushAccessibilityValue: String {
        let percent = Int(((editor?.brushRadius ?? 0.08) * 100).rounded())
        return "\(percent) percent"
    }

    private func select(_ tool: Tool) {
        switch tool {
        case .aiCut:
            // Intelligent Cut is an action, not a paint mode: open the
            // VisionKit subject-lift step. Cancel leaves the editor untouched.
            guard !isSaving else { return }
            showSubjectLift = true

        case .original:
            activeTool = .original
            if let editor, hasCommittedChange {
                // setInstances([]) restores the whole image for both instance and
                // manual editors, and is an undoable step.
                editor.setInstances([])
                hasLiftedSubject = false
                hasCommittedChange = false
                flash("Whole image restored")
            }

        case .brush, .erase, .rectangle, .lasso, .crop:
            activeTool = tool
            lastPoint = nil
            selectionStart = nil
            selectionRect = nil
            lassoPoints = []
        }
    }

    // MARK: - Busy overlay

    private func busyOverlay(title: String, subtitle: String?) -> some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(spacing: DS.Space.md) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text(title)
                    .font(DS.TextRole.supporting.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                if let subtitle {
                    Text(subtitle)
                        .font(DS.TextRole.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.vertical, DS.Space.xl)
            .frame(maxWidth: 260)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            )
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    /// `StickerCreationStage.label` already carries the exact copy and the
    /// percentage for every determinate stage, `.compressing` included.
    private var applyProgressText: String {
        guard let stage = applyStage else { return "Preparing sticker…" }
        switch stage {
        case .loading: return "Preparing sticker…"
        case .extracting, .cutting, .compressing, .saving, .done: return stage.label
        }
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        isLoading = true
        defer { isLoading = false }

        guard let loaded = StickerSourceStore.image(for: source) else {
            loadErrorMessage = "Couldn't read this photo."
            return
        }
        let base = loaded.upNormalized() ?? loaded

        // No automatic cut-out: start on Original with everything kept. VisionKit
        // only runs when the user taps Intelligent Cut.
        let editor = MaskEditor(base: base, mask: nil, maxDimension: 1024)
        self.editor = editor
        activeTool = .original
        hasLiftedSubject = false
        hasCommittedChange = false
    }

    private func retry() {
        didLoad = false
        loadErrorMessage = nil
        isLoading = true
        Task { await load() }
    }

    // MARK: - Finish

    private func cancel() {
        dismiss()
    }

    private func apply() {
        guard let editor, !isSaving else { return }
        isSaving = true
        applyStage = .loading

        let crop = hasCrop ? cropRect : nil
        guard let image = editor.render(croppedTo: crop) else {
            isSaving = false
            applyStage = nil
            alertMessage = "Couldn't render the edited image."
            return
        }

        let source = self.source

        Task {
            do {
                // Encode off the main actor so the stage overlay can update.
                let sticker = try await Task.detached(priority: .userInitiated) {
                    try StickerFactory.encodeStatic(image, source: source) { stage in
                        Task { @MainActor in
                            applyStage = stage
                        }
                    }
                }.value
                successPulse += 1
                onDone(sticker)
                dismiss()
            } catch {
                isSaving = false
                applyStage = nil
                alertMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    // MARK: - Types

    private enum Tool: String, Identifiable, Equatable {
        case aiCut
        case rectangle
        case lasso
        case crop
        case original
        case brush
        case erase

        var id: String { rawValue }

        var title: String {
            switch self {
            case .aiCut: "Intelligent Cut"
            case .rectangle: "Rectangle"
            case .lasso: "Lasso"
            case .crop: "Crop"
            case .original: "Original"
            case .brush: "Restore"
            case .erase: "Erase"
            }
        }

        var symbol: String {
            switch self {
            case .aiCut: "person.crop.rectangle"
            case .rectangle: "rectangle.dashed"
            case .lasso: "lasso"
            case .crop: "crop"
            case .original: "photo"
            case .brush: "paintbrush.pointed"
            case .erase: "eraser"
            }
        }
    }

    private enum SelectionMode: Equatable {
        case keep
        case remove

        var title: String {
            switch self {
            case .keep: "Keep"
            case .remove: "Remove"
            }
        }

        var removing: Bool { self == .remove }

        var symbol: String {
            switch self {
            case .keep: "checkmark.circle"
            case .remove: "minus.circle"
            }
        }

        var color: Color {
            switch self {
            case .keep: .green
            case .remove: .red
            }
        }
    }

    private enum CropHandle: Equatable {
        case new
        case move
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }
}

/// Grey checkerboard that reads transparency in the canvas. Content layer.
private struct CheckerboardView: View {
    private let cell: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            let light = Color(uiColor: .systemGray5)
            let dark = Color(uiColor: .systemGray3)
            let columns = max(1, Int(ceil(size.width / cell)))
            let rows = max(1, Int(ceil(size.height / cell)))

            for row in 0..<rows {
                for column in 0..<columns {
                    let rect = CGRect(
                        x: CGFloat(column) * cell,
                        y: CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                    let color = (row + column).isMultiple(of: 2) ? light : dark
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}

// MARK: - Previews

private func previewEditorSource() -> StickerSource {
    .image(fileName: "preview.jpg")
}

#Preview("Light") {
    StickerEditorView(source: previewEditorSource()) { _ in }
}

#Preview("Dark") {
    StickerEditorView(source: previewEditorSource()) { _ in }
        .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    StickerEditorView(source: previewEditorSource()) { _ in }
        .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    StickerEditorView(source: previewEditorSource()) { _ in }
        .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    StickerEditorView(source: previewEditorSource()) { _ in }
        .frame(width: 430, height: 932)
}

