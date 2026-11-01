import CoreImage
import SwiftUI

/// One photo being retouched: the original, its analysis, the current
/// parameters and brush strokes, undo/redo, and preview rendering.
@MainActor
final class EditSession: ObservableObject {
    struct State: Equatable {
        var parameters: RetouchParameters
        var strokes: [BrushStroke]
    }

    enum Phase: Equatable { case analysing, ready, failed(String) }

    let original: CIImage
    /// Full-resolution source data, kept for metadata on export.
    let sourceData: Data?
    @Published private(set) var phase: Phase = .analysing
    @Published private(set) var analysis: FurAnalysis?
    @Published private(set) var state: State
    @Published private(set) var preview: CGImage?
    @Published private(set) var previewOriginal: CGImage?
    @Published var selectedTool: RetouchTool = .auto

    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var renderTask: Task<Void, Never>?
    private let previewImage: CIImage
    nonisolated static let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    static let previewLongEdge: CGFloat = 1600

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(image: CIImage, sourceData: Data?) {
        original = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        self.sourceData = sourceData
        state = State(parameters: .none, strokes: [])
        let e = original.extent
        let s = min(1, Self.previewLongEdge / max(e.width, e.height))
        previewImage = original.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        Task { await analyse() }
    }

    convenience init?(data: Data) {
        guard let img = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        self.init(image: img, sourceData: data)
    }

    private func analyse() async {
        let image = original
        do {
            let a = try await Task.detached(priority: .userInitiated) {
                try FurAnalyzer.analyze(image, context: EditSession.context)
            }.value
            analysis = a
            state = State(parameters: .auto(a.suggestion, strength: 0.8), strokes: [])
            phase = .ready
            previewOriginal = Self.context.createCGImage(previewImage, from: previewImage.extent)
            scheduleRender()
        } catch {
            phase = .failed("识别失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Editing

    /// Slider value 0...100 for the selected tool.
    func value(for tool: RetouchTool) -> Double { state.parameters[tool] * 100 }

    /// Call `beginChange()` when a slider drag starts so the whole drag is one undo step.
    func beginChange() {
        undoStack.append(state)
        redoStack.removeAll()
    }

    func setValue(_ v: Double, for tool: RetouchTool) {
        var p = state.parameters
        if tool == .auto, let a = analysis {
            p = .auto(a.suggestion, strength: v / 100)
        } else {
            p[tool] = v / 100
        }
        state.parameters = p
        scheduleRender()
    }

    func addStroke(_ s: BrushStroke) {
        beginChange()
        state.strokes.append(s)
        scheduleRender()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(state)
        state = prev
        scheduleRender()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        scheduleRender()
    }

    // MARK: - Rendering

    private func scheduleRender() {
        guard let analysis else { return }
        renderTask?.cancel()
        let input = previewImage, st = state
        renderTask = Task { [weak self] in
            let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let out = FurProcessor.render(input, analysis: analysis, parameters: st.parameters, strokes: st.strokes)
                return EditSession.context.createCGImage(out, from: out.extent)
            }.value
            guard !Task.isCancelled else { return }
            self?.preview = cg
        }
    }

    func maskOverlay(visible: Set<RetouchRegion>) -> CGImage? {
        guard let analysis else { return nil }
        let o = FurProcessor.maskOverlay(analysis: analysis, strokes: state.strokes, visible: visible, extent: previewImage.extent)
        return Self.context.createCGImage(o, from: o.extent)
    }

    /// Full-resolution result for export.
    func renderFull() async -> CIImage? {
        guard let analysis else { return nil }
        let img = original, st = state
        return await Task.detached(priority: .userInitiated) {
            FurProcessor.render(img, analysis: analysis, parameters: st.parameters, strokes: st.strokes)
        }.value
    }
}
