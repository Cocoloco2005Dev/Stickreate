import SwiftUI
import UIKit
import PhotosUI

/// Focused editor for a single still image, laid out like the iOS markup editor:
/// a square canvas on a checkerboard, a bottom tool row (Crop, Remove Background,
/// Erase, Restore), and a contextual row for the active tool. Cancel sits on the
/// left of the nav bar, Done (the single prominent action) on the right.
@MainActor
struct StickerEditorView: View {
    let item: PhotosPickerItem
    let onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var editor: MaskEditor?
    @State private var isLoading = true
    @State private var didLoad = false
    @State private var loadErrorMessage: String?

    private enum Tool: Equatable {
        case crop
        case erase
        case restore
    }

    @State private var activeTool: Tool?
    @State private var backgroundRemoved = false

    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var cropDragging = false
    @State private var cropActiveHandle: CropHandle?
    @State private var cropInitialRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    @State private var lastPoint: CGPoint?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Edit Sticker")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .bottom) {
                    if editor != nil {
                        bottomControls
                    }
                }
        }
        .task { await load() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let editor {
            GeometryReader { proxy in
                canvasSquare(editor: editor, available: proxy.size)
            }
            .padding(16)
        } else if isLoading {
            ProgressView("Preparing sticker…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Couldn't Open This Photo", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadErrorMessage ?? "Try choosing a different photo.")
            } actions: {
                Button("Try Again") { retry() }
                Button("Close") { dismiss() }
            }
        }
    }

    private func canvasSquare(editor: MaskEditor, available: CGSize) -> some View {
        let side = max(1, min(available.width, available.height))
        let imageSize = editor.base.size
        let scale = (imageSize.width > 0 && imageSize.height > 0)
            ? min(side / imageSize.width, side / imageSize.height)
            : 1
        let displaySize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (side - displaySize.width) / 2,
            y: (side - displaySize.height) / 2
        )

        return ZStack {
            CheckerboardView()

            Image(uiImage: editor.preview)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: side, height: side)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if activeTool == .crop {
                cropOverlay(origin: origin, displaySize: displaySize, canvasSize: side)
            }
        }
        .contentShape(Rectangle())
        .gesture(drawGesture(editor: editor, origin: origin, displaySize: displaySize))
        .position(x: available.width / 2, y: available.height / 2)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { cancel() }
        }

        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { finish() }
                .buttonStyle(.glassProminent)
                .disabled(editor == nil)
        }
    }

    // MARK: - Bottom controls (control layer)

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if showStatus {
                statusLine
            }
            if activeTool != nil {
                contextualRow
            }
            toolRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var showStatus: Bool {
        guard let editor else { return false }
        return !editor.hasSubject || (hasCrop && activeTool != .crop)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let editor {
            if !editor.hasSubject {
                Text("No subject detected — use Erase to clean up the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if hasCrop && activeTool != .crop {
                HStack(spacing: 8) {
                    Label("Cropped region applied", systemImage: "crop")
                    Spacer(minLength: 0)
                    Button("Reset") { resetCrop() }
                        .foregroundStyle(Color.accentColor)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var contextualRow: some View {
        if activeTool == .erase || activeTool == .restore {
            brushRow
        } else if activeTool == .crop {
            cropRow
        }
    }

    private var toolRow: some View {
        HStack(spacing: 8) {
            toolButton("Crop", symbol: "crop", active: activeTool == .crop) {
                toggleTool(.crop)
            }

            if editor?.hasSubject == true {
                toolButton(
                    "Remove Background",
                    symbol: backgroundRemoved ? "person.crop.rectangle" : "person.crop.rectangle.badge.plus",
                    active: backgroundRemoved
                ) {
                    toggleBackground()
                }
            }

            toolButton("Erase", symbol: "eraser", active: activeTool == .erase) {
                toggleTool(.erase)
            }

            toolButton("Restore", symbol: "paintbrush.pointed", active: activeTool == .restore) {
                toggleTool(.restore)
            }
        }
    }

    private func toolButton(
        _ title: String,
        symbol: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .tint(active ? Color.accentColor : nil)
        .accessibilityLabel(title)
        .accessibilityValue(active ? "on" : "off")
    }

    private var brushRow: some View {
        HStack(spacing: 12) {
            Slider(value: brushBinding, in: 0.02...0.3) {
                Text("Brush size")
            }
            .frame(minWidth: 80)
            .disabled(editor == nil)
            .accessibilityLabel("Brush size")
            .accessibilityValue(Text(brushAccessibilityValue))

            Button {
                editor?.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.glass)
            .disabled(!(editor?.canUndo ?? false))
            .accessibilityLabel("Undo")

            Button {
                editor?.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.glass)
            .disabled(editor == nil)
            .accessibilityLabel("Reset mask")
        }
    }

    private var cropRow: some View {
        HStack(spacing: 12) {
            Text("Drag inside to move · corners to resize")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button("Reset") { resetCrop() }
                .buttonStyle(.glass)
                .disabled(!hasCrop)
                .accessibilityLabel("Reset crop")

            Button("Apply crop") { activeTool = nil }
                .buttonStyle(.glass)
                .accessibilityLabel("Apply crop")
        }
    }

    // MARK: - Tool state

    private var hasCrop: Bool {
        !(cropRect.minX <= 0.001
            && cropRect.minY <= 0.001
            && cropRect.width >= 0.999
            && cropRect.height >= 0.999)
    }

    private func toggleTool(_ tool: Tool) {
        activeTool = activeTool == tool ? nil : tool
    }

    private func toggleBackground() {
        guard let editor else { return }
        backgroundRemoved.toggle()
        editor.setBackgroundRemoved(backgroundRemoved)
    }

    private func resetCrop() {
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        cropDragging = false
        cropActiveHandle = nil
    }

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

    // MARK: - Loading

    @MainActor
    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        isLoading = true
        defer { isLoading = false }

        do {
            let base = try await StickerFactory.loadUprightImage(from: item)
            // Background removal is best-effort: if it fails we keep every pixel
            // so the user can still erase manually.
            var mask: CGImage?
            if let extraction = try? await BackgroundRemover.extractSubject(from: base) {
                mask = extraction.mask
            }
            let editor = MaskEditor(base: base, mask: mask, maxDimension: 1024)
            self.editor = editor
            backgroundRemoved = editor.hasSubject
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    private func retry() {
        didLoad = false
        loadErrorMessage = nil
        isLoading = true
        Task { await load() }
    }

    // MARK: - Drawing

    private func drawGesture(editor: MaskEditor, origin: CGPoint, displaySize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard activeTool == .erase || activeTool == .restore else { return }
                guard let point = normalizedPoint(
                    value.location,
                    origin: origin,
                    displaySize: displaySize
                ) else { return }

                if lastPoint == nil {
                    editor.beginStroke()
                }
                editor.stroke(
                    from: lastPoint ?? point,
                    to: point,
                    restoring: activeTool == .restore
                )
                lastPoint = point
            }
            .onEnded { _ in
                if lastPoint != nil {
                    editor.endStroke()
                }
                lastPoint = nil
            }
    }

    /// Maps a touch in the square canvas to normalized 0...1 image coordinates.
    /// Returns `nil` when the touch lands on the letterbox area.
    private func normalizedPoint(
        _ location: CGPoint,
        origin: CGPoint,
        displaySize: CGSize
    ) -> CGPoint? {
        guard displaySize.width > 0, displaySize.height > 0 else { return nil }
        let x = (location.x - origin.x) / displaySize.width
        let y = (location.y - origin.y) / displaySize.height
        guard x >= -0.02, x <= 1.02, y >= -0.02, y <= 1.02 else { return nil }
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    // MARK: - Crop

    private func cropOverlay(origin: CGPoint, displaySize: CGSize, canvasSize: CGFloat) -> some View {
        let crop = CGRect(
            x: origin.x + cropRect.minX * displaySize.width,
            y: origin.y + cropRect.minY * displaySize.height,
            width: cropRect.width * displaySize.width,
            height: cropRect.height * displaySize.height
        )
        let corners = [
            CGPoint(x: crop.minX, y: crop.minY),
            CGPoint(x: crop.maxX, y: crop.minY),
            CGPoint(x: crop.minX, y: crop.maxY),
            CGPoint(x: crop.maxX, y: crop.maxY)
        ]

        return ZStack {
            // Shaded region outside the crop rect.
            Path { path in
                path.addRect(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
                path.addRect(crop)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: crop.width, height: crop.height)
                .position(x: crop.midX, y: crop.midY)
                .allowsHitTesting(false)

            ForEach(corners, id: \.self) { corner in
                Circle()
                    .fill(Color.white)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
                    .shadow(radius: 2)
                    .position(corner)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: canvasSize, height: canvasSize)
        .contentShape(Rectangle())
        .gesture(cropGesture(crop: crop, displaySize: displaySize))
    }

    private func cropGesture(crop: CGRect, displaySize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !cropDragging {
                    cropDragging = true
                    cropInitialRect = cropRect
                    cropActiveHandle = cropHandle(at: value.startLocation, in: crop)
                }
                guard let handle = cropActiveHandle else { return }
                cropRect = updatedCropRect(
                    handle: handle,
                    initial: cropInitialRect,
                    translation: value.translation,
                    displaySize: displaySize
                )
            }
            .onEnded { _ in
                cropDragging = false
                cropActiveHandle = nil
            }
    }

    private func cropHandle(at point: CGPoint, in rect: CGRect) -> CropHandle? {
        let threshold: CGFloat = 44
        let candidates: [(CropHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
        for (handle, corner) in candidates {
            let dx = point.x - corner.x
            let dy = point.y - corner.y
            if (dx * dx + dy * dy).squareRoot() <= threshold {
                return handle
            }
        }
        return rect.contains(point) ? .move : nil
    }

    private func updatedCropRect(
        handle: CropHandle,
        initial: CGRect,
        translation: CGSize,
        displaySize: CGSize
    ) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0 else { return initial }
        let dx = translation.width / displaySize.width
        let dy = translation.height / displaySize.height
        let minSize: CGFloat = 0.1

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
        }
    }

    // MARK: - Finish

    private func cancel() {
        // Exiting crop mode first is the natural escape hatch; otherwise discard.
        if activeTool == .crop {
            activeTool = nil
        } else {
            dismiss()
        }
    }

    private func finish() {
        guard let editor else {
            dismiss()
            return
        }
        let crop = hasCrop ? cropRect : nil
        if let image = editor.render(croppedTo: crop) {
            onDone(image)
        }
        dismiss()
    }

    private enum CropHandle {
        case move
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }
}

/// Opaque checkerboard that makes transparency in the sticker canvas readable.
/// Content layer — never glass.
private struct CheckerboardView: View {
    private let cell: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            let light = Color(uiColor: .systemBackground)
            let dark = Color(uiColor: .systemGray5)
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
