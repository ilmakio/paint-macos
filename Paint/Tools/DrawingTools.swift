import AppKit

/// Shared behaviour for the freehand tools: drag the nib along the pointer,
/// bridging each mouse event to the last with a Bresenham line so fast strokes
/// stay continuous.
class FreehandTool: Tool {
    private var lastPoint: PixelPoint?
    private var anchor: PixelPoint?
    /// Shift at press time locks the whole stroke to a straight 45° line.
    private var straightMode = false
    private var straightDirty = PixelRect.zero

    var actionName: String { "Draw" }

    func stamp(for context: ToolContext) -> BrushStamp {
        context.settings.currentStamp()
    }

    func color(for context: ToolContext) -> Pixel {
        context.paintColor
    }

    override func mouseDown(at point: PixelPoint, context: ToolContext) {
        context.document.commitSelection()
        context.document.beginEdit()
        anchor = point
        lastPoint = point
        straightMode = context.shift
        straightDirty = .zero

        let dirty = stamp(for: context).apply(to: context.image, at: point, color: color(for: context))
        straightDirty = dirty
        context.host.invalidate(dirty)
    }

    override func mouseDragged(to point: PixelPoint, context: ToolContext) {
        guard let anchor else { return }
        let nib = stamp(for: context)
        let paint = color(for: context)

        if straightMode {
            // Redraw the whole line each time so the preview is the result.
            let target = Raster.constrainToAngle(from: anchor, to: point)
            let previous = straightDirty
            context.document.revertToSnapshot(previous)
            let dirty = nib.stroke(on: context.image, from: anchor, to: target, color: paint)
            straightDirty = dirty
            context.host.invalidate(previous.union(dirty))
            lastPoint = target
        } else {
            guard let last = lastPoint else { return }
            let dirty = nib.stroke(on: context.image, from: last, to: point, color: paint)
            lastPoint = point
            context.host.invalidate(dirty)
        }
    }

    override func mouseUp(at point: PixelPoint, context: ToolContext) {
        lastPoint = nil
        anchor = nil
        straightMode = false
        context.document.commitEdit(actionName)
    }

    override func cancel(context: ToolContext) {
        lastPoint = nil
        anchor = nil
        straightMode = false
        context.document.cancelEdit()
        context.host.invalidateAll()
    }
}

/// One-pixel-hard nib. Size is honoured, but the edges are never softened —
/// this is the tool you reach for when every pixel has to be deliberate.
final class PencilTool: FreehandTool {
    override var kind: ToolKind { .pencil }
    override var actionName: String { "Pencil" }
}

final class BrushTool: FreehandTool {
    override var kind: ToolKind { .brush }
    override var actionName: String { "Brush" }
}

/// Lays down the background colour. Right-dragging turns it into Paint's
/// colour eraser, which only replaces the foreground colour and leaves
/// everything else untouched.
final class EraserTool: FreehandTool {
    override var kind: ToolKind { .eraser }
    override var actionName: String { "Eraser" }

    private var colorEraseMode = false

    override func color(for context: ToolContext) -> Pixel {
        context.settings.background
    }

    override func mouseDown(at point: PixelPoint, context: ToolContext) {
        colorEraseMode = context.isSecondary
        if colorEraseMode {
            context.document.commitSelection()
            context.document.beginEdit()
            eraseColor(at: point, from: point, context: context)
        } else {
            super.mouseDown(at: point, context: context)
        }
    }

    override func mouseDragged(to point: PixelPoint, context: ToolContext) {
        if colorEraseMode {
            eraseColor(at: point, from: lastColorErasePoint ?? point, context: context)
        } else {
            super.mouseDragged(to: point, context: context)
        }
    }

    override func mouseUp(at point: PixelPoint, context: ToolContext) {
        if colorEraseMode {
            colorEraseMode = false
            lastColorErasePoint = nil
            context.document.commitEdit("Color Eraser")
        } else {
            super.mouseUp(at: point, context: context)
        }
    }

    private var lastColorErasePoint: PixelPoint?

    private func eraseColor(at point: PixelPoint, from previous: PixelPoint, context: ToolContext) {
        let nib = context.settings.currentStamp()
        var dirty = PixelRect.zero
        Raster.line(from: previous, to: point) { x, y in
            let area = nib.coverage(at: PixelPoint(x, y))
            let changed = FloodFill.replaceColor(context.image, in: area,
                                                 from: context.settings.foreground,
                                                 to: context.settings.background)
            dirty = dirty.union(changed)
        }
        lastColorErasePoint = point
        context.host.invalidate(dirty)
    }
}

/// Random dots inside a disc, refreshed on a timer so holding still keeps
/// building up density — just like the original.
final class AirbrushTool: Tool {
    override var kind: ToolKind { .airbrush }
    override var wantsAutorepeat: Bool { true }

    private var rng = SystemRandomNumberGenerator()
    private var lastPoint: PixelPoint?

    override func mouseDown(at point: PixelPoint, context: ToolContext) {
        context.document.commitSelection()
        context.document.beginEdit()
        lastPoint = point
        spray(at: point, context: context)
    }

    override func mouseDragged(to point: PixelPoint, context: ToolContext) {
        // Spray along the travelled segment so a quick swipe leaves a trail
        // rather than two disconnected puffs.
        if let last = lastPoint {
            var dirty = PixelRect.zero
            Raster.line(from: last, to: point) { x, y in
                dirty = dirty.union(Airbrush.spray(on: context.image, at: PixelPoint(x, y),
                                                   radius: context.settings.airbrushRadius,
                                                   density: max(1, context.settings.airbrushDensity / 4),
                                                   color: context.paintColor, using: &rng))
            }
            context.host.invalidate(dirty)
        }
        lastPoint = point
    }

    override func autorepeat(at point: PixelPoint, context: ToolContext) {
        spray(at: point, context: context)
    }

    override func mouseUp(at point: PixelPoint, context: ToolContext) {
        lastPoint = nil
        context.document.commitEdit("Airbrush")
    }

    override func cancel(context: ToolContext) {
        lastPoint = nil
        context.document.cancelEdit()
        context.host.invalidateAll()
    }

    private func spray(at point: PixelPoint, context: ToolContext) {
        let dirty = Airbrush.spray(on: context.image, at: point,
                                   radius: context.settings.airbrushRadius,
                                   density: context.settings.airbrushDensity,
                                   color: context.paintColor, using: &rng)
        context.host.invalidate(dirty)
    }
}

/// The bucket.
final class FillTool: Tool {
    override var kind: ToolKind { .fill }

    override func mouseDown(at point: PixelPoint, context: ToolContext) {
        guard context.image.contains(point.x, point.y) else { return }
        context.document.commitSelection()
        context.document.beginEdit()
        let dirty = FloodFill.fill(context.image, from: point, with: context.paintColor,
                                   tolerance: context.settings.fillTolerance)
        context.host.invalidate(dirty)
        context.document.commitEdit("Fill With Color")
    }
}

/// Eyedropper. Left picks the foreground colour, right picks the background,
/// then Paint hands you back the tool you were using.
final class PickColorTool: Tool {
    override var kind: ToolKind { .pickColor }

    override func mouseDown(at point: PixelPoint, context: ToolContext) {
        pick(at: point, context: context)
    }

    override func mouseDragged(to point: PixelPoint, context: ToolContext) {
        pick(at: point, context: context)
    }

    override func mouseUp(at point: PixelPoint, context: ToolContext) {
        context.host.toolWantsToRevertToPreviousTool()
    }

    private func pick(at point: PixelPoint, context: ToolContext) {
        // Sample what is on screen, so picking off a floating selection works.
        let source = context.document.flattenedImage()
        guard let picked = source.pixel(point.x, point.y) else { return }
        if context.isSecondary {
            context.settings.background = picked.straight
        } else {
            context.settings.foreground = picked.straight
        }
    }
}

/// Click to zoom in, right-click (or Option-click) to zoom back out.
final class MagnifierTool: Tool {
    override var kind: ToolKind { .magnifier }

    override func mouseDown(at point: PixelPoint, context: ToolContext) {
        if context.isSecondary || context.option {
            context.host.zoomOut(around: point)
        } else {
            context.host.zoomIn(around: point)
        }
    }
}
