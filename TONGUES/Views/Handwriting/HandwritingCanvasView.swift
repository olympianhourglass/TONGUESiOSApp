import PencilKit
import SwiftUI
import Combine

// Thin PencilKit wrapper for the practice rectangle. Accepts both finger and
// Apple Pencil (`drawingPolicy = .anyInput`) and reports each finished stroke
// as a polyline of view-coordinate points. The parent decides — per tier —
// whether to keep the stroke (`accept`) or roll it back (`removeLastStroke`).
final class HandwritingCanvasController: ObservableObject {
    fileprivate weak var canvas: PKCanvasView?
    // How many strokes the parent has already handled; guards the
    // end-of-stroke callback against re-firing on programmatic edits.
    fileprivate var processedCount = 0

    /// Wipe all ink and reset bookkeeping (used on advance / manual clear).
    func clear() {
        canvas?.drawing = PKDrawing()
        processedCount = 0
    }

    /// Keep every stroke currently on the canvas (advance the processed mark).
    func acceptCurrent() {
        processedCount = canvas?.drawing.strokes.count ?? processedCount
    }

    /// Drop the most recent stroke — used when a stroke fails validation.
    func removeLastStroke() {
        guard let canvas, !canvas.drawing.strokes.isEmpty else { return }
        var strokes = canvas.drawing.strokes
        strokes.removeLast()
        canvas.drawing = PKDrawing(strokes: strokes)
        processedCount = strokes.count
    }

    /// Every stroke currently on the canvas, as view-coordinate polylines.
    func allStrokePoints() -> [[CGPoint]] {
        guard let canvas else { return [] }
        return canvas.drawing.strokes.map(Self.points(of:))
    }

    var isEmpty: Bool { canvas?.drawing.strokes.isEmpty ?? true }

    static func points(of stroke: PKStroke) -> [CGPoint] {
        let path = stroke.path
        guard path.count > 0 else { return [] }
        var pts: [CGPoint] = []
        pts.reserveCapacity(path.count)
        for i in 0..<path.count {
            pts.append(path[i].location.applying(stroke.transform))
        }
        return pts
    }
}

struct HandwritingCanvasView: UIViewRepresentable {
    @ObservedObject var controller: HandwritingCanvasController
    var strokeColor: UIColor
    var lineWidth: CGFloat = 9
    /// (justFinishedStroke, allStrokesOnCanvas) — both in view coordinates.
    var onStrokeEnd: ([CGPoint], [[CGPoint]]) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: strokeColor, width: lineWidth)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.bouncesZoom = false
        canvas.delegate = context.coordinator
        controller.canvas = canvas
        context.coordinator.controller = controller
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.tool = PKInkingTool(.pen, color: strokeColor, width: lineWidth)
        context.coordinator.onStrokeEnd = onStrokeEnd
        context.coordinator.controller = controller
        controller.canvas = canvas
    }

    func makeCoordinator() -> Coordinator { Coordinator(onStrokeEnd: onStrokeEnd) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onStrokeEnd: ([CGPoint], [[CGPoint]]) -> Void
        weak var controller: HandwritingCanvasController?

        init(onStrokeEnd: @escaping ([CGPoint], [[CGPoint]]) -> Void) {
            self.onStrokeEnd = onStrokeEnd
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard let controller else { return }
            let strokes = canvasView.drawing.strokes
            guard strokes.count > controller.processedCount, let last = strokes.last else { return }
            let lastPoints = HandwritingCanvasController.points(of: last)
            let allPoints = strokes.map(HandwritingCanvasController.points(of:))
            onStrokeEnd(lastPoints, allPoints)
        }
    }
}
