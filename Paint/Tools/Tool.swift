import AppKit

/// What the canvas has to offer a tool. Keeping it behind a protocol means the
/// tools compile and reason about the document alone, with no view knowledge.
protocol ToolHost: AnyObject {
    var document: PaintDocument { get }
    var zoom: CGFloat { get }

    func invalidate(_ rect: PixelRect)
    func invalidateAll()
    func invalidateOverlay()
    func zoomIn(around point: PixelPoint)
    func zoomOut(around point: PixelPoint)
    func beginTextEditing(in rect: PixelRect)
    /// A tool asking to hand control back, e.g. the eyedropper reverting to
    /// whatever you were drawing with.
    func toolWantsToRevertToPreviousTool()
}

/// Non-destructive decoration drawn on top of the canvas while a tool is busy.
enum ToolPreview {
    case none
    case marquee(PixelRect)
    case lasso([PixelPoint])
}

struct ToolContext {
    unowned let host: ToolHost
    let document: PaintDocument
    let settings: PaintSettings
    let modifiers: NSEvent.ModifierFlags
    /// True when the gesture came from the right mouse button, which in Paint
    /// swaps the two active colours for the duration of the stroke.
    let isSecondary: Bool

    var image: PixelBuffer { document.image }
    var paintColor: Pixel { isSecondary ? settings.background : settings.foreground }
    var alternateColor: Pixel { isSecondary ? settings.foreground : settings.background }
    var shift: Bool { modifiers.contains(.shift) }
    var option: Bool { modifiers.contains(.option) }
}

/// Base class for every tool. Subclasses override only what they need.
class Tool {
    var kind: ToolKind { .pencil }

    /// Overlay to draw while the tool is mid-gesture.
    var preview: ToolPreview { .none }

    /// Airbrush-style tools keep painting while the button is held still.
    var wantsAutorepeat: Bool { false }

    /// True while a multi-step gesture (polygon, curve, text) is unfinished, so
    /// the canvas knows not to let anything else steal the interaction.
    var isInProgress: Bool { false }

    func mouseDown(at point: PixelPoint, context: ToolContext) {}
    func mouseDragged(to point: PixelPoint, context: ToolContext) {}
    func mouseUp(at point: PixelPoint, context: ToolContext) {}
    func mouseMoved(to point: PixelPoint, context: ToolContext) {}
    func autorepeat(at point: PixelPoint, context: ToolContext) {}

    /// Return true if the double-click was consumed (the polygon closing, say).
    func doubleClick(at point: PixelPoint, context: ToolContext) -> Bool { false }

    /// Escape: throw the gesture away.
    func cancel(context: ToolContext) {}

    /// Called before switching tools or saving: land whatever is in flight.
    func finish(context: ToolContext) {}

    func cursor(for context: ToolContext) -> NSCursor? { nil }

    // MARK: Shared helpers

    /// Applies Shift-constraint for the tools that support it.
    func constrained(_ point: PixelPoint, from anchor: PixelPoint, context: ToolContext,
                     square: Bool) -> PixelPoint {
        guard context.shift else { return point }
        return square
            ? Raster.constrainToSquare(from: anchor, to: point)
            : Raster.constrainToAngle(from: anchor, to: point)
    }

    /// Clamps to the canvas, so a drag that runs off the edge still behaves.
    func clamp(_ point: PixelPoint, to buffer: PixelBuffer) -> PixelPoint {
        PixelPoint(max(0, min(point.x, buffer.width - 1)),
                   max(0, min(point.y, buffer.height - 1)))
    }
}

/// Builds the tool object for a given toolbox entry.
enum ToolFactory {
    static func make(_ kind: ToolKind) -> Tool {
        switch kind {
        case .pencil: return PencilTool()
        case .brush: return BrushTool()
        case .eraser: return EraserTool()
        case .airbrush: return AirbrushTool()
        case .fill: return FillTool()
        case .pickColor: return PickColorTool()
        case .magnifier: return MagnifierTool()
        case .text: return TextTool()
        case .line: return LineTool()
        case .curve: return CurveTool()
        case .rectangle: return RectangleTool()
        case .roundedRectangle: return RoundedRectangleTool()
        case .ellipse: return EllipseTool()
        case .polygon: return PolygonTool()
        case .rectangleSelect: return RectangleSelectTool()
        case .freeFormSelect: return FreeFormSelectTool()
        }
    }
}
