import AppKit

/// Shared move/stretch behaviour for both selection tools. Subclasses only
/// have to say how a *new* selection is drawn out.
class SelectionToolBase: Tool {
    private enum Drag {
        case none
        case creating
        case moving(grabX: Int, grabY: Int)
        case resizing(handle: SelectionHandle, startRect: PixelRect)
    }

    private var drag: Drag = .none

    /// Subclass hooks.
    func beginCreating(at point: PixelPoint, context: ToolContext) {}
    func continueCreating(to point: PixelPoint, context: ToolContext) {}
    func finishCreating(at point: PixelPoint, context: ToolContext) {}
    func cancelCreating(context: ToolContext) {}

    override func mouseDown(at point: PixelPoint, context: ToolContext) {
        if let selection = context.document.selection {
            if let handle = hitHandle(point, in: selection.rect, zoom: context.host.zoom) {
                context.document.floatSelectionIfNeeded()
                drag = .resizing(handle: handle, startRect: selection.rect)
                return
            }
            if selection.rect.contains(point) {
                // Option-drag leaves the original behind, the familiar
                // "duplicate as you drag" gesture.
                if context.option, !selection.isFloating {
                    selection.isFloating = true
                    selection.sourceRect = nil
                }
                drag = .moving(grabX: point.x - selection.rect.x, grabY: point.y - selection.rect.y)
                return
            }
            context.document.commitSelection()
        }
        drag = .creating
        beginCreating(at: point, context: context)
    }

    override func mouseDragged(to point: PixelPoint, context: ToolContext) {
        switch drag {
        case .creating:
            continueCreating(to: point, context: context)
        case let .moving(grabX, grabY):
            guard let selection = context.document.selection else { return }
            context.document.floatSelectionIfNeeded()
            var origin = PixelPoint(point.x - grabX, point.y - grabY)
            if context.shift {
                // Lock the drag to one axis.
                let from = selection.rect.origin
                if abs(origin.x - from.x) > abs(origin.y - from.y) {
                    origin.y = from.y
                } else {
                    origin.x = from.x
                }
            }
            guard origin != selection.origin else { return }
            selection.origin = origin
            context.document.notifySelectionChanged()
            context.host.invalidateOverlay()
        case let .resizing(handle, startRect):
            guard let selection = context.document.selection else { return }
            let rect = resized(startRect, handle: handle, to: point)
            guard rect.width != selection.rect.width
                || rect.height != selection.rect.height
                || rect.origin != selection.origin else { return }
            selection.resize(toWidth: rect.width, height: rect.height)
            selection.origin = rect.origin
            context.document.notifySelectionChanged()
            context.host.invalidateOverlay()
        case .none:
            break
        }
    }

    override func mouseUp(at point: PixelPoint, context: ToolContext) {
        if case .creating = drag {
            finishCreating(at: point, context: context)
        }
        drag = .none
    }

    override func cancel(context: ToolContext) {
        if case .creating = drag { cancelCreating(context: context) }
        drag = .none
        context.document.commitSelection()
        context.host.invalidateAll()
    }

    override func finish(context: ToolContext) {
        if case .creating = drag { cancelCreating(context: context) }
        drag = .none
        context.document.commitSelection()
    }

    override func cursor(for context: ToolContext) -> NSCursor? {
        nil
    }

    /// Handles are sized in screen points, so they stay grabbable at 8× zoom
    /// and at 25%.
    ///
    /// Two guards keep a small selection draggable: handles are only live once
    /// the canvas actually draws them, and the grab radius never grows past a
    /// third of the box — otherwise the corners would meet in the middle and
    /// every click would resize instead of move.
    func hitHandle(_ point: PixelPoint, in rect: PixelRect, zoom: CGFloat) -> SelectionHandle? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard CGFloat(rect.width) * zoom >= 12, CGFloat(rect.height) * zoom >= 12 else { return nil }
        let screenSlack = max(1, Int((6 / max(zoom, 0.1)).rounded(.up)))
        let slack = min(screenSlack, max(1, min(rect.width, rect.height) / 3))
        for handle in SelectionHandle.allCases {
            let centre = handle.position(in: rect)
            if abs(point.x - centre.x) <= slack && abs(point.y - centre.y) <= slack {
                return handle
            }
        }
        return nil
    }

    private func resized(_ start: PixelRect, handle: SelectionHandle, to point: PixelPoint) -> PixelRect {
        var left = start.x, top = start.y, right = start.maxX, bottom = start.maxY
        if handle.movesLeftEdge { left = min(point.x, right - 1) }
        if handle.movesRightEdge { right = max(point.x, left + 1) }
        if handle.movesTopEdge { top = min(point.y, bottom - 1) }
        if handle.movesBottomEdge { bottom = max(point.y, top + 1) }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// The rectangular marquee.
final class RectangleSelectTool: SelectionToolBase {
    override var kind: ToolKind { .rectangleSelect }

    private var anchor: PixelPoint?
    private var current: PixelRect?

    override var preview: ToolPreview {
        if let current { return .marquee(current) }
        return .none
    }

    override func beginCreating(at point: PixelPoint, context: ToolContext) {
        anchor = clamp(point, to: context.image)
        current = nil
        context.host.invalidateOverlay()
    }

    override func continueCreating(to point: PixelPoint, context: ToolContext) {
        guard let anchor else { return }
        var target = clamp(point, to: context.image)
        if context.shift { target = Raster.constrainToSquare(from: anchor, to: target) }
        current = PixelRect.bounding(anchor, clamp(target, to: context.image))
        context.host.invalidateOverlay()
    }

    override func finishCreating(at point: PixelPoint, context: ToolContext) {
        defer {
            anchor = nil
            current = nil
            context.host.invalidateOverlay()
        }
        guard let rect = current, rect.width > 1 || rect.height > 1 else { return }
        guard let selection = Selection.rectangular(from: context.image, rect: rect) else { return }
        context.document.setSelection(selection)
    }

    override func cancelCreating(context: ToolContext) {
        anchor = nil
        current = nil
        context.host.invalidateOverlay()
    }
}

/// The lasso. Points are collected as you drag and closed automatically on
/// release.
final class FreeFormSelectTool: SelectionToolBase {
    override var kind: ToolKind { .freeFormSelect }

    private var path: [PixelPoint] = []

    override var preview: ToolPreview {
        path.count >= 2 ? .lasso(path) : .none
    }

    override func beginCreating(at point: PixelPoint, context: ToolContext) {
        path = [clamp(point, to: context.image)]
        context.host.invalidateOverlay()
    }

    override func continueCreating(to point: PixelPoint, context: ToolContext) {
        let p = clamp(point, to: context.image)
        // Skip duplicates so the polygon fill doesn't choke on zero-length edges.
        if p != path.last { path.append(p) }
        context.host.invalidateOverlay()
    }

    override func finishCreating(at point: PixelPoint, context: ToolContext) {
        defer {
            path = []
            context.host.invalidateOverlay()
        }
        guard path.count >= 3 else { return }
        guard let selection = Selection.freeForm(from: context.image, points: path) else { return }
        context.document.setSelection(selection)
    }

    override func cancelCreating(context: ToolContext) {
        path = []
        context.host.invalidateOverlay()
    }
}

/// Drags out a box and hands off to the canvas's live text editor.
final class TextTool: Tool {
    override var kind: ToolKind { .text }

    private var anchor: PixelPoint?
    private var current: PixelRect?

    override var preview: ToolPreview {
        if let current { return .marquee(current) }
        return .none
    }

    override func mouseDown(at point: PixelPoint, context: ToolContext) {
        context.document.commitSelection()
        anchor = clamp(point, to: context.image)
        current = nil
        context.host.invalidateOverlay()
    }

    override func mouseDragged(to point: PixelPoint, context: ToolContext) {
        guard let anchor else { return }
        current = PixelRect.bounding(anchor, clamp(point, to: context.image))
        context.host.invalidateOverlay()
    }

    override func mouseUp(at point: PixelPoint, context: ToolContext) {
        defer {
            anchor = nil
            current = nil
            context.host.invalidateOverlay()
        }
        guard let anchor else { return }
        var rect = current ?? PixelRect(x: anchor.x, y: anchor.y, width: 0, height: 0)
        // A plain click gets a sensible default box instead of nothing.
        if rect.width < 8 || rect.height < 8 {
            let height = max(24, Int(context.settings.fontSize * 1.6))
            rect = PixelRect(x: anchor.x, y: anchor.y, width: 260, height: height)
        }
        let clipped = rect.intersection(context.image.bounds)
        guard clipped.width >= 8, clipped.height >= 8 else { return }
        context.host.beginTextEditing(in: clipped)
    }

    override func cancel(context: ToolContext) {
        anchor = nil
        current = nil
        context.host.invalidateOverlay()
    }
}
