import SwiftUI
import UIKit

/// "Adjust" editor for a single still image.
///
/// A checkerboard canvas with pinch-to-zoom / drag-to-pan sits above a control
/// layer: a 2×3 tool grid and a plain-text action bar (Cancel · undo/redo ·
/// Apply). Editing is non-destructive through `MaskEditor`; nothing is removed
/// until the user asks for it — the default tool is Full (keep everything).
@MainActor
struct StickerEditorView: View {
    let source: StickerSource
    let onDone: (StickerItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var editor: MaskEditor?
    @State private var isLoading = true
    @State private var didLoad = false
    @State private var loadErrorMessage: String?

    @State private var activeTool: Tool = .full
    @State private var hasCommittedChange = false
    /// Mirrors the editor's background mode so switching to Full only counts
    /// as a change when something was actually removed.
    @State private var backgroundRemoved = false

    // Canvas transform
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var panning = false
    @State private var magnifying = false
    @State private var showZoomHint = true

    // Brush
    @State private var lastPoint: CGPoint?

    // Selection tools (normalized image coordinates, top-left origin)
    @State private var selectionStart: CGPoint?
    @State private var selectionRect: CGRect?
    @State private var lassoPoints: [CGPoint] = []

    // AI Cut
    @State private var isRemoving = false
    @State private var removalProgress: Double = 0

    @State private var alertMessage: String?

    private let maxZoom: CGFloat = 5

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if let editor {
                    canvas(editor)
                } else if isLoading {
                    ProgressView("Preparing photo…")
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Couldn't Open This Photo", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadErrorMessage ?? "Try choosing a different photo.")
                    } actions: {
                        Button("Try Again") { retry() }
                        Button("Cancel", role: .cancel) { dismiss() }
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
                if isRemoving {
                    removalOverlay
                }
            }
            .alert("Something went wrong", isPresented: alertBinding) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
        }
        .task { await load() }
    }

    // MARK: - Canvas

    private func canvas(_ editor: MaskEditor) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = imageFrame(canvas: size, imageSize: editor.base.size)

            ZStack {
                CheckerboardView()

                Image(uiImage: editor.preview)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                    .position(x: frame.midX, y: frame.midY)

                selectionOverlay(frame: frame)

                if showZoomHint && !isRemoving {
                    zoomHint
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(editor: editor, frame: frame, canvas: size))
            .simultaneousGesture(magnifyGesture(canvas: size, imageSize: editor.base.size))
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

    @ViewBuilder
    private func selectionOverlay(frame: CGRect) -> some View {
        if activeTool == .rectangle, let rect = selectionRect {
            let canvasRect = CGRect(
                x: frame.minX + rect.minX * frame.width,
                y: frame.minY + rect.minY * frame.height,
                width: rect.width * frame.width,
                height: rect.height * frame.height
            )
            ZStack {
                Rectangle().fill(Color.white.opacity(0.15))
                Rectangle().stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
            }
            .frame(width: max(canvasRect.width, 1), height: max(canvasRect.height, 1))
            .position(x: canvasRect.midX, y: canvasRect.midY)
            .allowsHitTesting(false)
        } else if activeTool == .lasso, lassoPoints.count >= 2 {
            ZStack {
                lassoPath(frame: frame).fill(Color.white.opacity(0.12))
                lassoPath(frame: frame).stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
            }
            .allowsHitTesting(false)
        }
    }

    private func lassoPath(frame: CGRect) -> Path {
        var path = Path()
        let points = lassoPoints.map { canvasPoint($0, in: frame) }
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
                case .full, .aiCut:
                    panCanvas(value: value, canvas: canvas, imageSize: editor.base.size)
                }
            }
            .onEnded { value in
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
                case .full, .aiCut:
                    panning = false
                    panStart = pan
                }
            }
    }

    private func magnifyGesture(canvas: CGSize, imageSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if showZoomHint { showZoomHint = false }
                if !magnifying {
                    magnifying = true
                    zoomStart = zoom
                    panStart = pan
                }
                zoom = min(max(zoomStart * value, 1), maxZoom)
                pan = clampedPan(pan, canvas: canvas, imageSize: imageSize)
            }
            .onEnded { _ in
                magnifying = false
                zoomStart = zoom
                panStart = pan
                pan = clampedPan(pan, canvas: canvas, imageSize: imageSize)
            }
    }

    private func draw(editor: MaskEditor, value: DragGesture.Value, frame: CGRect) {
        let point = normalized(value.location, in: frame)
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
        pan = clampedPan(candidate, canvas: canvas, imageSize: imageSize)
    }

    private func updateRectSelection(value: DragGesture.Value, frame: CGRect) {
        let start = selectionStart ?? normalized(value.startLocation, in: frame)
        selectionStart = start
        let current = normalized(value.location, in: frame)
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
        editor.selectRectangle(rect, removing: true)
        hasCommittedChange = true
    }

    private func updateLasso(value: DragGesture.Value, frame: CGRect) {
        let point = normalized(value.location, in: frame)
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
        editor.selectLasso(lassoPoints, removing: true)
        hasCommittedChange = true
    }

    // MARK: - Geometry mapping

    private func imageFrame(canvas: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              canvas.width > 0, canvas.height > 0 else { return .zero }
        let fit = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let width = imageSize.width * fit * zoom
        let height = imageSize.height * fit * zoom
        let centerX = canvas.width / 2 + pan.width
        let centerY = canvas.height / 2 + pan.height
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    private func clampedPan(_ value: CGSize, canvas: CGSize, imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              canvas.width > 0, canvas.height > 0 else { return value }
        let fit = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let maxX = max(0, (imageSize.width * fit * zoom - canvas.width) / 2)
        let maxY = max(0, (imageSize.height * fit * zoom - canvas.height) / 2)
        return CGSize(
            width: min(max(value.width, -maxX), maxX),
            height: min(max(value.height, -maxY), maxY)
        )
    }

    /// Touch → normalized 0...1 image coordinates, clamped to the image edges.
    private func normalized(_ location: CGPoint, in frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let x = (location.x - frame.minX) / frame.width
        let y = (location.y - frame.minY) / frame.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    private func canvasPoint(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
    }

    // MARK: - Control layer

    private var controlLayer: some View {
        VStack(spacing: 12) {
            if activeTool.isDrawing {
                brushRow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            toolGrid

            Divider()

            actionBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Color(uiColor: .systemBackground), ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy, value: activeTool)
    }

    private var brushRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)

            Slider(value: brushBinding, in: 0.02...0.3)
                .accessibilityLabel("Brush size")
                .accessibilityValue(Text(brushAccessibilityValue))

            Image(systemName: "circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var toolGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                toolButton(.aiCut)
                toolButton(.rectangle)
                toolButton(.lasso)
            }
            HStack(spacing: 8) {
                toolButton(.full)
                toolButton(.brush)
                toolButton(.erase)
            }
        }
    }

    private func toolButton(_ tool: Tool) -> some View {
        Button {
            select(tool)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 20))
                    .frame(width: 36, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(activeTool == tool ? Color(uiColor: .systemGray5) : .clear)
                    )

                Text(tool.title)
                    .font(.caption2)
                    .foregroundStyle(activeTool == tool ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(activeTool == tool ? .isSelected : AccessibilityTraits())
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button("Cancel") { cancel() }
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)

            Spacer(minLength: 0)

            Button {
                editor?.undo()
                hasCommittedChange = true
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .disabled(!(editor?.canUndo ?? false))
            .accessibilityLabel("Undo")

            Button {
                editor?.redo()
                hasCommittedChange = true
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .disabled(!(editor?.canRedo ?? false))
            .accessibilityLabel("Redo")

            Spacer(minLength: 0)

            Button("Apply") { apply() }
                .fontWeight(.semibold)
                .disabled(!hasCommittedChange || isRemoving)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
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
            runAICut()

        case .full:
            activeTool = .full
            if backgroundRemoved, let editor {
                editor.setBackgroundRemoved(false)
                backgroundRemoved = false
                hasCommittedChange = true
            }

        case .brush, .erase, .rectangle, .lasso:
            activeTool = tool
            lastPoint = nil
            selectionStart = nil
            selectionRect = nil
            lassoPoints = []
        }
    }

    // MARK: - AI Cut

    private func runAICut() {
        guard let editor, !isRemoving else { return }
        activeTool = .aiCut

        // Already lifted once: restore the stored subject mask instead of
        // paying for another Vision pass.
        if editor.hasSubject {
            if !backgroundRemoved {
                editor.setBackgroundRemoved(true)
                backgroundRemoved = true
                hasCommittedChange = true
            }
            return
        }

        isRemoving = true
        removalProgress = 0

        let base = editor.base
        let radius = editor.brushRadius

        Task {
            do {
                let extraction = try await BackgroundRemover.extractSubject(from: base) { value in
                    Task { @MainActor in
                        removalProgress = min(max(value, 0), 1)
                    }
                }
                let updated = MaskEditor(base: base, mask: extraction.mask, maxDimension: 1024)
                updated.brushRadius = radius
                self.editor = updated
                self.backgroundRemoved = true
                self.hasCommittedChange = true
                self.isRemoving = false
            } catch {
                self.isRemoving = false
                self.activeTool = .full
                self.alertMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't remove the background."
            }
        }
    }

    private var removalOverlay: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text(removalText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            )
        }
        .transition(.opacity)
    }

    private var removalText: String {
        if removalProgress > 0 {
            return "Removing background… \(Int((removalProgress * 100).rounded()))%"
        }
        return "Removing background…"
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

        // No automatic cut-out: start on Full with everything kept. Vision only
        // runs when the user taps AI Cut.
        let editor = MaskEditor(base: base, mask: nil, maxDimension: 1024)
        self.editor = editor
        activeTool = .full
        backgroundRemoved = false
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
        guard let editor else { return }
        guard let image = editor.render(croppedTo: nil) else {
            alertMessage = "Couldn't render the edited image."
            return
        }
        do {
            let sticker = try StickerFactory.encodeStatic(image, source: source)
            onDone(sticker)
            dismiss()
        } catch {
            alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    // MARK: - Tools

    private enum Tool: String, Identifiable, CaseIterable {
        case aiCut
        case rectangle
        case lasso
        case full
        case brush
        case erase

        var id: String { rawValue }

        var title: String {
            switch self {
            case .aiCut: "AI Cut"
            case .rectangle: "Rectangle"
            case .lasso: "Lasso"
            case .full: "Full"
            case .brush: "Brush"
            case .erase: "Erase"
            }
        }

        var symbol: String {
            switch self {
            case .aiCut: "person.crop.rectangle"
            case .rectangle: "rectangle.dashed"
            case .lasso: "lasso"
            case .full: "square.grid.3x3"
            case .brush: "paintbrush.pointed"
            case .erase: "eraser"
            }
        }

        var isDrawing: Bool { self == .brush || self == .erase }
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
