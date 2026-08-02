import AppKit

/// Drag-out shapes: line, rectangle, rounded rectangle, ellipse.
///
/// Every frame rolls the canvas back to the pre-drag snapshot and rasterises
/// the shape again, so what you see while dragging is byte-for-byte what you
/// get on release.
class ShapeTool: Tool {
    private var anchor: PixelPoint?
    private var lastDirty = PixelRect.zero

    var actionName: String { "Shape" }
    /// Shift makes rectangles square and ellipses circular; for the line tool
    /// it snaps to 45° instead.
    var constrainsToSquare: Bool { true }

    /// Rasterise the shape. Subclasses do the drawing and return the rect they
    /// dirtied.
    func drawShape(from a: PixelPoint, to b: PixelPoint, context: ToolContext) -> PixelRect {
        .zero
    }

    var lineNib: BrushStamp { BrushStamp.make(shape: .round, size: PaintSettings.shared.lineWidth) }

    override func mouseDown(at point: PixelPoint, context: ToolContext) {
        context.document.commitSelection()
        context.document.beginEdit()
        anchor = point
        lastDirty = drawShape(from: point, to: point, context: context)
        context.host.invalidate(lastDirty)
    }

    override func mouseDragged(to point: PixelPoint, context: ToolContext) {
        guard let anchor else { return }
        let target = constrained(point, from: anchor, context: context, square: constrainsToSquare)
        let previous = lastDirty
        context.document.revertToSnapshot(previous)
        lastDirty = drawShape(from: anchor, to: target, context: context)
        context.host.invalidate(previous.union(lastDirty))
    }

    override func mouseUp(at point: PixelPoint, context: ToolContext) {
        anchor = nil
        lastDirty = .zero
        context.document.commitEdit(actionName)
    }

    override func cancel(context: ToolContext) {
        anchor = nil
        lastDirty = .zero
        context.document.cancelEdit()
        context.host.invalidateAll()
    }

    /// Fill colour for the current style, or nil when the shape is outline-only.
    func fillColor(for context: ToolContext) -> Pixel? {
        switch context.settings.shapeStyle {
        case .outline: return nil
        case .filled: return context.paintColor
        case .outlineAndFill: return context.alternateColor
        }
    }
}

final class LineTool: ShapeTool {
    override var kind: ToolKind { .line }
    override var actionName: String { "Line" }
    override var constrainsToSquare: Bool { false }

    override func drawShape(from a: PixelPoint, to b: PixelPoint, context: ToolContext) -> PixelRect {
        let painter = Painter(context.image)
        painter.strokeLine(from: a, to: b, nib: lineNib, color: context.paintColor)
        return painter.dirty
    }
}

final class RectangleTool: ShapeTool {
    override var kind: ToolKind { .rectangle }
    override var actionName: String { "Rectangle" }

    override func drawShape(from a: PixelPoint, to b: PixelPoint, context: ToolContext) -> PixelRect {
        let rect = PixelRect.bounding(a, b)
        let painter = Painter(context.image)
        if let fill = fillColor(for: context) {
            Raster.rectangleFill(rect) { y, x0, x1 in painter.span(y, x0, x1, fill) }
        }
        if context.settings.shapeStyle.drawsOutline {
            Raster.rectangleOutline(rect, thickness: context.settings.lineWidth) { y, x0, x1 in
                painter.span(y, x0, x1, context.paintColor)
            }
        }
        return painter.dirty
    }
}

final class RoundedRectangleTool: ShapeTool {
    override var kind: ToolKind { .roundedRectangle }
    override var actionName: String { "Rounded Rectangle" }

    override func drawShape(from a: PixelPoint, to b: PixelPoint, context: ToolContext) -> PixelRect {
        let rect = PixelRect.bounding(a, b)
        let radius = Raster.defaultCornerRadius(for: rect)
        let painter = Painter(context.image)
        if let fill = fillColor(for: context) {
            Raster.roundedRectangleFill(in: rect, radius: radius) { y, x0, x1 in
                painter.span(y, x0, x1, fill)
            }
        }
        if context.settings.shapeStyle.drawsOutline {
            Raster.roundedRectangleOutline(in: rect, radius: radius,
                                           thickness: context.settings.lineWidth) { y, x0, x1 in
                painter.span(y, x0, x1, context.paintColor)
            }
        }
        return painter.dirty
    }
}

final class EllipseTool: ShapeTool {
    override var kind: ToolKind { .ellipse }
    override var actionName: String { "Ellipse" }

    override func drawShape(from a: PixelPoint, to b: PixelPoint, context: ToolContext) -> PixelRect {
        let rect = PixelRect.bounding(a, b)
        let painter = Painter(context.image)
        if let fill = fillColor(for: context) {
            Raster.ellipseFill(in: rect) { y, x0, x1 in painter.span(y, x0, x1, fill) }
        }
        if context.settings.shapeStyle.drawsOutline {
            Raster.ellipseOutline(in: rect, thickness: context.settings.lineWidth) { y, x0, x1 in
                painter.span(y, x0, x1, context.paintColor)
            }
        }
        return painter.dirty
    }
}

/// Paint's curve: draw a straight line first, then pull it twice into a cubic.
final class CurveTool: Tool {
    override var kind: ToolKind { .curve }
    override var isInProgress: Bool { stage != .idle }

    private enum Stage {
        case idle
        case draggingLine
        case awaitingFirstBend
        case draggingFirstBend
        case awaitingSecondBend
        case draggingSecondBend
    }

    private var stage: Stage = .idle
    private var start = PixelPoint.zero
    private var end = PixelPoint.zero
    private var control1 = PixelPoint.zero
    private var control2 = PixelPoint.zero
    private var lastDirty = PixelRect.zero

    override func mouseDown(at point: PixelPoint, context: ToolContext) {
        switch stage {
        case .idle:
            context.document.commitSelection()
            context.document.beginEdit()
            start = point
            end = point
            control1 = point
            control2 = point
            stage = .draggingLine
            redraw(context: context)
        case .awaitingFirstBend:
            stage = .draggingFirstBend
            control1 = point
            redraw(context: context)
        case .awaitingSecondBend:
            stage = .draggingSecondBend
            control2 = point
            redraw(context: context)
        default:
            break
        }
    }

    override func mouseDragged(to point: PixelPoint, context: ToolContext) {
        switch stage {
        case .draggingLine:
            end = context.shift ? Raster.constrainToAngle(from: start, to: point) : point
            control1 = start
            control2 = end
            redraw(context: context)
        case .draggingFirstBend:
            control1 = point
            redraw(context: context)
        case .draggingSecondBend:
            control2 = point
            redraw(context: context)
        default:
            break
        }
    }

    override func mouseUp(at point: PixelPoint, context: ToolContext) {
        switch stage {
        case .draggingLine:
            // A zero-length drag isn't a curve; throw it away.
            if start == end {
                stage = .idle
                context.document.cancelEdit()
                context.host.invalidateAll()
            } else {
                stage = .awaitingFirstBend
            }
        case .draggingFirstBend:
            stage = .awaitingSecondBend
        case .draggingSecondBend:
            finish(context: context)
        default:
            break
        }
    }

    override func finish(context: ToolContext) {
        guard stage != .idle else { return }
        stage = .idle
        lastDirty = .zero
        context.document.commitEdit("Curve")
    }

    override func cancel(context: ToolContext) {
        guard stage != .idle else { return }
        stage = .idle
        lastDirty = .zero
        context.document.cancelEdit()
        context.host.invalidateAll()
    }

    private func redraw(context: ToolContext) {
        let previous = lastDirty
        context.document.revertToSnapshot(previous)
        let painter = Painter(context.image)
        let nib = BrushStamp.make(shape: .round, size: context.settings.lineWidth)
        let color = context.paintColor
        var previousPoint: PixelPoint?
        Raster.cubicBezier(start, control1, control2, end) { x, y in
            let p = PixelPoint(x, y)
            if let prev = previousPoint {
                painter.strokeLine(from: prev, to: p, nib: nib, color: color)
            } else {
                painter.stamp(nib, at: p, color: color)
            }
            previousPoint = p
        }
        lastDirty = painter.dirty
        context.host.invalidate(previous.union(lastDirty))
    }
}

/// Click out vertices; double-click, press Return, or click the first vertex
/// again to close the shape.
final class PolygonTool: Tool {
    override var kind: ToolKind { .polygon }
    override var isInProgress: Bool { !points.isEmpty }

    private var points: [PixelPoint] = []
    private var cursor: PixelPoint?
    private var lastDirty = PixelRect.zero

    override func mouseDown(at point: PixelPoint, context: ToolContext) {
        if points.isEmpty {
            context.document.commitSelection()
            context.document.beginEdit()
            points = [point]
        } else if shouldClose(at: point, context: context) {
            close(context: context)
            return
        } else {
            points.append(point)
        }
        cursor = point
        redraw(context: context)
    }

    override func mouseDragged(to point: PixelPoint, context: ToolContext) {
        guard !points.isEmpty else { return }
        cursor = point
        redraw(context: context)
    }

    override func mouseMoved(to point: PixelPoint, context: ToolContext) {
        guard !points.isEmpty else { return }
        cursor = point
        redraw(context: context)
    }

    override func mouseUp(at point: PixelPoint, context: ToolContext) {
        guard !points.isEmpty else { return }
        // A press-and-drag places the vertex where the button came up.
        points[points.count - 1] = point
        cursor = point
        redraw(context: context)
    }

    override func doubleClick(at point: PixelPoint, context: ToolContext) -> Bool {
        guard points.count >= 2 else { return false }
        close(context: context)
        return true
    }

    override func finish(context: ToolContext) {
        guard !points.isEmpty else { return }
        if points.count >= 3 {
            close(context: context)
        } else {
            cancel(context: context)
        }
    }

    override func cancel(context: ToolContext) {
        guard !points.isEmpty else { return }
        points = []
        cursor = nil
        lastDirty = .zero
        context.document.cancelEdit()
        context.host.invalidateAll()
    }

    /// Closing by clicking near the first vertex needs a hit area that stays
    /// usable at any zoom, so the threshold is measured in screen points.
    private func shouldClose(at point: PixelPoint, context: ToolContext) -> Bool {
        guard points.count >= 2, let first = points.first else { return false }
        let slack = max(2, Int(6 / max(context.host.zoom, 0.25)))
        return abs(point.x - first.x) <= slack && abs(point.y - first.y) <= slack
    }

    private func close(context: ToolContext) {
        guard points.count >= 2 else { return cancel(context: context) }
        cursor = nil
        drawPolygon(closed: true, context: context)
        points = []
        lastDirty = .zero
        context.document.commitEdit("Polygon")
    }

    private func redraw(context: ToolContext) {
        drawPolygon(closed: false, context: context)
    }

    private func drawPolygon(closed: Bool, context: ToolContext) {
        let previous = lastDirty
        context.document.revertToSnapshot(previous)

        var path = points
        if !closed, let cursor, cursor != path.last { path.append(cursor) }

        let painter = Painter(context.image)
        if closed, path.count >= 3, let fill = fillColor(for: context) {
            Raster.polygonFill(path) { y, x0, x1 in painter.span(y, x0, x1, fill) }
        }
        if !closed || context.settings.shapeStyle.drawsOutline {
            let nib = BrushStamp.make(shape: .round, size: context.settings.lineWidth)
            let color = context.paintColor
            if path.count == 1 {
                painter.stamp(nib, at: path[0], color: color)
            } else {
                for i in 0 ..< (path.count - 1) {
                    painter.strokeLine(from: path[i], to: path[i + 1], nib: nib, color: color)
                }
                if closed, path.count > 2 {
                    painter.strokeLine(from: path[path.count - 1], to: path[0], nib: nib, color: color)
                }
            }
        }
        lastDirty = painter.dirty
        context.host.invalidate(previous.union(lastDirty))
    }

    private func fillColor(for context: ToolContext) -> Pixel? {
        switch context.settings.shapeStyle {
        case .outline: return nil
        case .filled: return context.paintColor
        case .outlineAndFill: return context.alternateColor
        }
    }
}
