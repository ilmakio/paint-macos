import AppKit

protocol CanvasViewDelegate: AnyObject {
    func canvasView(_ view: CanvasView, didMoveCursorTo point: PixelPoint?)
    func canvasViewDidChangeZoom(_ view: CanvasView)
    /// Live width × height readout while a shape or selection is being dragged.
    func canvasView(_ view: CanvasView, didUpdateDragSize size: PixelRect?)
    func canvasViewDidRequestToolRevert(_ view: CanvasView)
}

/// The drawing surface: mirrors the document's pixels on screen, routes mouse
/// events to the active tool, and hosts the selection and text overlays.
final class CanvasView: NSView, ToolHost, PaintDocumentObserver {

    // MARK: Configuration

    static let zoomLevels: [CGFloat] = [0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32]
    /// Room on the right and bottom for the canvas resize grips.
    private let gripMargin: CGFloat = 14
    private let gripSize: CGFloat = 8

    // MARK: State

    let document: PaintDocument
    weak var delegate: CanvasViewDelegate?

    private(set) var zoom: CGFloat = 1

    private(set) var tool: Tool
    private var settings: PaintSettings { .shared }

    private var cachedImage: CGImage?
    private var cachedSelectionImage: CGImage?

    private var lastOverlayBounds: NSRect = .zero
    private var hoverPixel: PixelPoint?
    private var lastNibRect: NSRect = .zero

    private var antsPhase: CGFloat = 0
    private var antsTimer: Timer?
    private var autorepeatTimer: Timer?
    private var autorepeatPoint: PixelPoint = .zero
    private var autorepeatSecondary = false

    private var activeButtonIsSecondary = false
    private var isTracking = false

    private var spaceDown = false
    private var panOrigin: NSPoint?

    private enum CanvasGrip { case right, bottom, corner }
    private var activeGrip: CanvasGrip?
    private var gripPreviewSize: PixelRect?

    private var textEditor: NSTextView?
    private var textEditRect: PixelRect?

    // MARK: Init

    init(document: PaintDocument) {
        self.document = document
        self.tool = ToolFactory.make(PaintSettings.shared.tool)
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        wantsLayer = true
        document.addObserver(self)
        updateFrameSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        antsTimer?.invalidate()
        autorepeatTimer?.invalidate()
        document.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    // MARK: - Geometry

    var imageSize: NSSize {
        NSSize(width: CGFloat(document.image.width), height: CGFloat(document.image.height))
    }

    var scaledImageSize: NSSize {
        NSSize(width: (imageSize.width * zoom).rounded(), height: (imageSize.height * zoom).rounded())
    }

    private var imageRect: NSRect {
        NSRect(origin: .zero, size: scaledImageSize)
    }

    func updateFrameSize() {
        let size = scaledImageSize
        setFrameSize(NSSize(width: size.width + gripMargin, height: size.height + gripMargin))
        needsDisplay = true
    }

    func viewRect(for rect: PixelRect) -> NSRect {
        NSRect(x: CGFloat(rect.x) * zoom, y: CGFloat(rect.y) * zoom,
               width: CGFloat(rect.width) * zoom, height: CGFloat(rect.height) * zoom)
    }

    func pixel(at viewPoint: NSPoint) -> PixelPoint {
        PixelPoint(Int(floor(viewPoint.x / zoom)), Int(floor(viewPoint.y / zoom)))
    }

    private func pixel(for event: NSEvent) -> PixelPoint {
        pixel(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: - Tool plumbing

    private func context(secondary: Bool, modifiers: NSEvent.ModifierFlags = []) -> ToolContext {
        ToolContext(host: self, document: document, settings: settings,
                    modifiers: modifiers, isSecondary: secondary)
    }

    func setTool(_ kind: ToolKind) {
        guard tool.kind != kind else { return }
        tool.finish(context: context(secondary: false))
        endTextEditing(commit: true)
        tool = ToolFactory.make(kind)
        invalidateOverlay()
        window?.invalidateCursorRects(for: self)
        delegate?.canvasView(self, didUpdateDragSize: nil)
    }

    /// Lands whatever the current tool has in flight — before saving, undoing,
    /// or closing the window.
    func finishCurrentTool() {
        tool.finish(context: context(secondary: false))
        endTextEditing(commit: true)
        invalidateOverlay()
    }

    // MARK: - ToolHost

    func invalidate(_ rect: PixelRect) {
        guard !rect.isEmpty else { return }
        cachedImage = nil
        setNeedsDisplay(viewRect(for: rect).insetBy(dx: -2, dy: -2))
    }

    func invalidateAll() {
        cachedImage = nil
        cachedSelectionImage = nil
        needsDisplay = true
    }

    func invalidateOverlay() {
        cachedSelectionImage = nil
        let bounds = overlayBounds()
        let union = lastOverlayBounds.union(bounds)
        lastOverlayBounds = bounds
        if union.isEmpty {
            needsDisplay = true
        } else {
            setNeedsDisplay(union.insetBy(dx: -4, dy: -4))
        }
        updateAntsTimer()
    }

    func zoomIn(around point: PixelPoint) {
        guard let next = CanvasView.zoomLevels.first(where: { $0 > zoom }) else { return }
        setZoom(next, anchor: point)
    }

    func zoomOut(around point: PixelPoint) {
        guard let next = CanvasView.zoomLevels.last(where: { $0 < zoom }) else { return }
        setZoom(next, anchor: point)
    }

    func toolWantsToRevertToPreviousTool() {
        delegate?.canvasViewDidRequestToolRevert(self)
    }

    // MARK: - Zoom

    func setZoom(_ newZoom: CGFloat, anchor: PixelPoint? = nil) {
        let clamped = max(CanvasView.zoomLevels.first!, min(CanvasView.zoomLevels.last!, newZoom))
        guard clamped != zoom else { return }

        let clip = enclosingScrollView?.contentView
        let anchorPixel = anchor ?? centrePixel()
        // Remember where the anchor sits inside the window so it stays put.
        let anchorBefore = clip.map {
            convert(NSPoint(x: CGFloat(anchorPixel.x) * zoom, y: CGFloat(anchorPixel.y) * zoom), to: $0)
        }

        zoom = clamped
        updateFrameSize()
        invalidateAll()

        if let clip, let anchorBefore {
            let anchorNow = convert(NSPoint(x: CGFloat(anchorPixel.x) * zoom,
                                            y: CGFloat(anchorPixel.y) * zoom), to: clip)
            var origin = clip.bounds.origin
            origin.x += anchorNow.x - anchorBefore.x
            origin.y += anchorNow.y - anchorBefore.y
            clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        delegate?.canvasViewDidChangeZoom(self)
    }

    private func centrePixel() -> PixelPoint {
        guard let clip = enclosingScrollView?.contentView else {
            return PixelPoint(document.image.width / 2, document.image.height / 2)
        }
        let visible = convert(clip.documentVisibleRect, from: clip)
        return pixel(at: NSPoint(x: visible.midX, y: visible.midY))
    }

    /// Picks the largest zoom level that shows the whole image.
    func zoomToFit() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let available = clip.bounds.insetBy(dx: 24, dy: 24).size
        guard available.width > 0, available.height > 0 else { return }
        let raw = min(available.width / imageSize.width, available.height / imageSize.height)
        let level = CanvasView.zoomLevels.last(where: { $0 <= raw }) ?? CanvasView.zoomLevels.first!
        setZoom(level)
    }

    override func magnify(with event: NSEvent) {
        let target = zoom * (1 + event.magnification)
        let anchor = pixel(for: event)
        // Snap to the nearest discrete level so pixels stay on whole numbers.
        let level = CanvasView.zoomLevels.min(by: { abs($0 - target) < abs($1 - target) })
        if let level, level != zoom { setZoom(level, anchor: anchor) }
    }

    /// Accumulated ⌘-scroll travel, so a trackpad's stream of tiny deltas steps
    /// one zoom level at a time instead of racing to 32× in a flick.
    private var zoomScrollTravel: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            zoomScrollTravel = 0
            super.scrollWheel(with: event)
            return
        }
        if event.phase == .began { zoomScrollTravel = 0 }

        var delta = event.scrollingDeltaY
        // A notched wheel reports whole lines; a trackpad reports pixels.
        if !event.hasPreciseScrollingDeltas { delta *= 10 }
        zoomScrollTravel += delta

        let step: CGFloat = 30
        while abs(zoomScrollTravel) >= step {
            // Re-read the pixel under the cursor each step: the last zoom moved
            // the canvas, so the anchor from before is stale.
            let anchor = pixel(for: event)
            if zoomScrollTravel > 0 {
                zoomScrollTravel -= step
                zoomIn(around: anchor)
            } else {
                zoomScrollTravel += step
                zoomOut(around: anchor)
            }
        }
    }

    // MARK: - Document observation

    func paintDocument(_ document: PaintDocument, didChangeImageIn rect: PixelRect) {
        invalidate(rect)
    }

    func paintDocumentDidChangeSelection(_ document: PaintDocument) {
        cachedSelectionImage = nil
        invalidateOverlay()
        delegate?.canvasView(self, didUpdateDragSize: document.selection?.rect)
    }

    func paintDocumentDidChangeCanvasSize(_ document: PaintDocument) {
        cachedImage = nil
        cachedSelectionImage = nil
        updateFrameSize()
        needsDisplay = true
        delegate?.canvasViewDidChangeZoom(self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)

        let image = imageRect
        drawCheckerboard(in: image.intersection(dirtyRect), ctx: ctx)

        if let cg = currentImage() {
            ctx.saveGState()
            ctx.clip(to: dirtyRect)
            ctx.translateBy(x: 0, y: image.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: NSRect(origin: .zero, size: image.size))
            ctx.restoreGState()
        }

        drawFloatingSelection(ctx: ctx, dirtyRect: dirtyRect)
        drawGrid(ctx: ctx, dirtyRect: dirtyRect)

        ctx.setShouldAntialias(true)
        drawCanvasBorder(ctx: ctx)
        drawToolPreview(ctx: ctx)
        drawSelectionChrome(ctx: ctx)
        drawNibPreview(ctx: ctx)
        drawGrips(ctx: ctx)
    }

    private func currentImage() -> CGImage? {
        if cachedImage == nil { cachedImage = document.image.makeCGImage() }
        return cachedImage
    }

    private func drawCheckerboard(in rect: NSRect, ctx: CGContext) {
        guard !rect.isEmpty else { return }
        let light = NSColor(white: 1.0, alpha: 1).cgColor
        let dark = NSColor(white: 0.86, alpha: 1).cgColor
        let tile: CGFloat = 8
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setFillColor(light)
        ctx.fill(rect)
        ctx.setFillColor(dark)
        var y = (rect.minY / tile).rounded(.down) * tile
        while y < rect.maxY {
            var x = (rect.minX / tile).rounded(.down) * tile
            while x < rect.maxX {
                let odd = (Int(x / tile) + Int(y / tile)) % 2 == 1
                if odd { ctx.fill(NSRect(x: x, y: y, width: tile, height: tile)) }
                x += tile
            }
            y += tile
        }
        ctx.restoreGState()
    }

    private func drawFloatingSelection(ctx: CGContext, dirtyRect: NSRect) {
        guard let selection = document.selection,
              selection.isFloating || selection.sourceRect == nil
        else { return }

        if cachedSelectionImage == nil {
            let source: PixelBuffer
            if settings.transparentSelection {
                // Punch out the background colour so what is drawn matches what
                // will be stamped down.
                let copy = selection.buffer.copy()
                let bg = settings.background
                for i in 0 ..< copy.count where copy.storage[i] == bg.raw {
                    copy.storage[i] = Pixel.transparent.raw
                }
                source = copy
            } else {
                source = selection.buffer
            }
            cachedSelectionImage = source.makeCGImage()
        }
        guard let cg = cachedSelectionImage else { return }

        let rect = viewRect(for: selection.rect)
        guard rect.intersects(dirtyRect) else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: NSRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private func drawGrid(ctx: CGContext, dirtyRect: NSRect) {
        guard settings.showGrid, zoom >= 4 else { return }
        let area = imageRect.intersection(dirtyRect)
        guard !area.isEmpty else { return }

        ctx.saveGState()
        ctx.setStrokeColor(CanvasChrome.gridLine.cgColor)
        ctx.setLineWidth(1 / (window?.backingScaleFactor ?? 2))
        let path = CGMutablePath()
        var x = (area.minX / zoom).rounded(.down) * zoom
        while x <= area.maxX {
            path.move(to: CGPoint(x: x, y: area.minY))
            path.addLine(to: CGPoint(x: x, y: area.maxY))
            x += zoom
        }
        var y = (area.minY / zoom).rounded(.down) * zoom
        while y <= area.maxY {
            path.move(to: CGPoint(x: area.minX, y: y))
            path.addLine(to: CGPoint(x: area.maxX, y: y))
            y += zoom
        }
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawCanvasBorder(ctx: CGContext) {
        ctx.setStrokeColor(CanvasChrome.canvasBorder.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(imageRect.insetBy(dx: -0.5, dy: -0.5))
    }

    private func drawToolPreview(ctx: CGContext) {
        switch tool.preview {
        case .none:
            break
        case let .marquee(rect):
            strokeAnts(around: CGPath(rect: viewRect(for: rect), transform: nil), ctx: ctx)
        case let .lasso(points):
            guard points.count >= 2 else { break }
            let path = CGMutablePath()
            path.move(to: centreOfPixel(points[0]))
            for p in points.dropFirst() { path.addLine(to: centreOfPixel(p)) }
            path.closeSubpath()
            strokeAnts(around: path, ctx: ctx)
        }
    }

    private func centreOfPixel(_ p: PixelPoint) -> CGPoint {
        CGPoint(x: (CGFloat(p.x) + 0.5) * zoom, y: (CGFloat(p.y) + 0.5) * zoom)
    }

    private func drawSelectionChrome(ctx: CGContext) {
        guard let selection = document.selection else { return }
        let rect = viewRect(for: selection.rect)
        strokeAnts(around: CGPath(rect: rect, transform: nil), ctx: ctx)

        // Grab handles, only once there is room to show them.
        guard rect.width >= 12, rect.height >= 12 else { return }
        for handle in SelectionHandle.allCases {
            let centre = handle.position(in: selection.rect)
            let point = CGPoint(x: CGFloat(centre.x) * zoom, y: CGFloat(centre.y) * zoom)
            let box = NSRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// The two-tone dashed outline everyone recognises as "this is selected".
    private func strokeAnts(around path: CGPath, ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineDash(phase: antsPhase, lengths: [4, 4])
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Outlines the exact footprint the nib will cover, so a 30px brush is not
    /// a guess.
    private func drawNibPreview(ctx: CGContext) {
        guard let hoverPixel, !isTracking,
              tool.kind.usesSize, settings.sizeForCurrentTool > 2,
              document.selection == nil
        else { return }

        let rect: NSRect
        if tool.kind == .airbrush {
            let r = CGFloat(settings.airbrushRadius)
            rect = NSRect(x: (CGFloat(hoverPixel.x) - r) * zoom, y: (CGFloat(hoverPixel.y) - r) * zoom,
                          width: r * 2 * zoom, height: r * 2 * zoom)
        } else {
            rect = viewRect(for: settings.currentStamp().coverage(at: hoverPixel))
        }
        guard imageRect.intersects(rect) else { return }

        ctx.saveGState()
        ctx.setLineWidth(1)
        let isRound = tool.kind == .airbrush
            || (tool.kind == .brush && settings.brushShape == .round)
            || (!tool.kind.usesBrushShape && tool.kind != .pencil && tool.kind != .eraser)
        let path: CGPath = isRound
            ? CGPath(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5), transform: nil)
            : CGPath(rect: rect.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Canvas resize grips

    private func gripRect(_ grip: CanvasGrip) -> NSRect {
        let size = gripPreviewSize.map { NSSize(width: CGFloat($0.width) * zoom, height: CGFloat($0.height) * zoom) }
            ?? scaledImageSize
        let inset = gripSize / 2
        switch grip {
        case .right:
            return NSRect(x: size.width + 2, y: size.height / 2 - inset, width: gripSize, height: gripSize)
        case .bottom:
            return NSRect(x: size.width / 2 - inset, y: size.height + 2, width: gripSize, height: gripSize)
        case .corner:
            return NSRect(x: size.width + 2, y: size.height + 2, width: gripSize, height: gripSize)
        }
    }

    private func drawGrips(ctx: CGContext) {
        if let preview = gripPreviewSize {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.stroke(NSRect(x: 0, y: 0, width: CGFloat(preview.width) * zoom,
                              height: CGFloat(preview.height) * zoom).insetBy(dx: -0.5, dy: -0.5))
            ctx.restoreGState()
        }
        for grip in [CanvasGrip.right, .bottom, .corner] {
            let rect = gripRect(grip)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(NSColor(white: 0.35, alpha: 1).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func grip(at point: NSPoint) -> CanvasGrip? {
        for grip in [CanvasGrip.corner, .right, .bottom]
        where gripRect(grip).insetBy(dx: -3, dy: -3).contains(point) {
            return grip
        }
        return nil
    }

    // MARK: - Overlay bookkeeping

    private func overlayBounds() -> NSRect {
        var bounds = NSRect.zero
        if let selection = document.selection {
            bounds = bounds.union(viewRect(for: selection.rect).insetBy(dx: -8, dy: -8))
        }
        switch tool.preview {
        case .none:
            break
        case let .marquee(rect):
            bounds = bounds.union(viewRect(for: rect).insetBy(dx: -4, dy: -4))
        case let .lasso(points):
            guard let first = points.first else { break }
            var r = PixelRect(x: first.x, y: first.y, width: 1, height: 1)
            for p in points { r = r.union(PixelRect(x: p.x, y: p.y, width: 1, height: 1)) }
            bounds = bounds.union(viewRect(for: r).insetBy(dx: -4, dy: -4))
        }
        return bounds
    }

    private func updateAntsTimer() {
        let needsAnts = document.selection != nil || !isNoPreview(tool.preview)
        if needsAnts, antsTimer == nil {
            let timer = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.antsPhase = self.antsPhase.truncatingRemainder(dividingBy: 8) + 1
                let bounds = self.overlayBounds()
                if !bounds.isEmpty { self.setNeedsDisplay(bounds.insetBy(dx: -4, dy: -4)) }
            }
            RunLoop.main.add(timer, forMode: .common)
            antsTimer = timer
        } else if !needsAnts {
            antsTimer?.invalidate()
            antsTimer = nil
        }
    }

    private func isNoPreview(_ preview: ToolPreview) -> Bool {
        if case .none = preview { return true }
        return false
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        handleMouseDown(event, secondary: false)
    }

    override func rightMouseDown(with event: NSEvent) {
        handleMouseDown(event, secondary: true)
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouseDragged(event, secondary: false)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handleMouseDragged(event, secondary: true)
    }

    override func mouseUp(with event: NSEvent) {
        handleMouseUp(event, secondary: false)
    }

    override func rightMouseUp(with event: NSEvent) {
        handleMouseUp(event, secondary: true)
    }

    private func handleMouseDown(_ event: NSEvent, secondary: Bool) {
        window?.makeFirstResponder(self)

        // Space-drag pans, which beats reaching for the scrollbars at 16×.
        if spaceDown {
            panOrigin = convert(event.locationInWindow, from: nil)
            return
        }

        let local = convert(event.locationInWindow, from: nil)
        if let grip = grip(at: local) {
            endTextEditing(commit: true)
            activeGrip = grip
            gripPreviewSize = PixelRect(x: 0, y: 0, width: document.image.width, height: document.image.height)
            needsDisplay = true
            return
        }

        // Clicking away from an active text box commits it, matching Paint.
        if textEditor != nil {
            endTextEditing(commit: true)
            if tool.kind != .text { return }
        }

        let point = pixel(for: event)

        if event.clickCount == 2,
           tool.doubleClick(at: point, context: context(secondary: secondary, modifiers: event.modifierFlags)) {
            isTracking = false
            invalidateOverlay()
            return
        }

        isTracking = true
        activeButtonIsSecondary = secondary
        tool.mouseDown(at: point, context: context(secondary: secondary, modifiers: event.modifierFlags))
        invalidateOverlay()
        reportDragSize(from: point, to: point)

        if tool.wantsAutorepeat {
            autorepeatPoint = point
            autorepeatSecondary = secondary
            startAutorepeat()
        }
    }

    private func handleMouseDragged(_ event: NSEvent, secondary: Bool) {
        if let panOrigin {
            let now = convert(event.locationInWindow, from: nil)
            scrollBy(dx: panOrigin.x - now.x, dy: panOrigin.y - now.y)
            return
        }

        let point = pixel(for: event)
        hoverPixel = point
        delegate?.canvasView(self, didMoveCursorTo: point)

        if let grip = activeGrip {
            updateGripDrag(grip, to: point)
            return
        }
        guard isTracking else { return }

        autorepeatPoint = point
        tool.mouseDragged(to: point, context: context(secondary: secondary, modifiers: event.modifierFlags))
        invalidateOverlay()
        reportDragSize(from: nil, to: point)
        autoscroll(with: event)
    }

    private func handleMouseUp(_ event: NSEvent, secondary: Bool) {
        if panOrigin != nil {
            panOrigin = nil
            return
        }
        stopAutorepeat()

        if let grip = activeGrip {
            finishGripDrag(grip)
            return
        }
        guard isTracking else { return }
        isTracking = false

        tool.mouseUp(at: pixel(for: event),
                     context: context(secondary: secondary, modifiers: event.modifierFlags))
        invalidateOverlay()
        delegate?.canvasView(self, didUpdateDragSize: document.selection?.rect)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = pixel(for: event)
        updateHover(point)
        guard !isTracking else { return }
        tool.mouseMoved(to: point, context: context(secondary: false, modifiers: event.modifierFlags))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(pixel(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        hoverPixel = nil
        if !lastNibRect.isEmpty { setNeedsDisplay(lastNibRect.insetBy(dx: -3, dy: -3)) }
        lastNibRect = .zero
        delegate?.canvasView(self, didMoveCursorTo: nil)
    }

    private func updateHover(_ point: PixelPoint) {
        hoverPixel = point
        delegate?.canvasView(self, didMoveCursorTo:
            document.image.contains(point.x, point.y) ? point : nil)

        guard tool.kind.usesSize, settings.sizeForCurrentTool > 2 else {
            if !lastNibRect.isEmpty {
                setNeedsDisplay(lastNibRect.insetBy(dx: -3, dy: -3))
                lastNibRect = .zero
            }
            return
        }
        let rect: NSRect
        if tool.kind == .airbrush {
            let r = CGFloat(settings.airbrushRadius)
            rect = NSRect(x: (CGFloat(point.x) - r) * zoom, y: (CGFloat(point.y) - r) * zoom,
                          width: r * 2 * zoom, height: r * 2 * zoom)
        } else {
            rect = viewRect(for: settings.currentStamp().coverage(at: point))
        }
        if rect != lastNibRect {
            setNeedsDisplay(lastNibRect.union(rect).insetBy(dx: -3, dy: -3))
            lastNibRect = rect
        }
    }

    private func reportDragSize(from start: PixelPoint?, to point: PixelPoint) {
        if let selection = document.selection {
            delegate?.canvasView(self, didUpdateDragSize: selection.rect)
        } else if case let .marquee(rect) = tool.preview {
            delegate?.canvasView(self, didUpdateDragSize: rect)
        } else {
            delegate?.canvasView(self, didUpdateDragSize: nil)
        }
    }

    private func scrollBy(dx: CGFloat, dy: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        var origin = clip.bounds.origin
        origin.x += dx
        origin.y += dy
        clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: Autorepeat (airbrush)

    private func startAutorepeat() {
        stopAutorepeat()
        let timer = Timer(timeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
            guard let self, self.isTracking else { return }
            self.tool.autorepeat(at: self.autorepeatPoint,
                                 context: self.context(secondary: self.autorepeatSecondary))
        }
        RunLoop.main.add(timer, forMode: .common)
        autorepeatTimer = timer
    }

    private func stopAutorepeat() {
        autorepeatTimer?.invalidate()
        autorepeatTimer = nil
    }

    // MARK: Canvas grips

    private func updateGripDrag(_ grip: CanvasGrip, to point: PixelPoint) {
        var width = document.image.width
        var height = document.image.height
        if grip == .right || grip == .corner { width = max(1, point.x + 1) }
        if grip == .bottom || grip == .corner { height = max(1, point.y + 1) }
        gripPreviewSize = PixelRect(x: 0, y: 0, width: width, height: height)
        delegate?.canvasView(self, didUpdateDragSize: gripPreviewSize)
        needsDisplay = true
    }

    private func finishGripDrag(_ grip: CanvasGrip) {
        defer {
            activeGrip = nil
            gripPreviewSize = nil
            needsDisplay = true
        }
        guard let size = gripPreviewSize,
              size.width != document.image.width || size.height != document.image.height
        else { return }
        document.resizeCanvas(toWidth: size.width, height: size.height)
        delegate?.canvasView(self, didUpdateDragSize: nil)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // space
            if !spaceDown {
                spaceDown = true
                NSCursor.openHand.push()
            }
            return
        }

        switch event.specialKey {
        case .some(.delete), .some(.backspace), .some(.deleteForward):
            if document.selection != nil {
                document.deleteSelection()
                return
            }
        case .some(.carriageReturn), .some(.enter):
            if tool.isInProgress {
                tool.finish(context: context(secondary: false))
                invalidateOverlay()
                return
            }
            if textEditor != nil { endTextEditing(commit: true); return }
        case .some(.leftArrow), .some(.rightArrow), .some(.upArrow), .some(.downArrow):
            if nudgeSelection(event) { return }
        default:
            break
        }

        if event.keyCode == 53 { // escape
            if textEditor != nil {
                endTextEditing(commit: false)
            } else {
                tool.cancel(context: context(secondary: false))
                invalidateOverlay()
            }
            return
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            if spaceDown {
                spaceDown = false
                NSCursor.pop()
            }
            return
        }
        super.keyUp(with: event)
    }

    private func nudgeSelection(_ event: NSEvent) -> Bool {
        guard let selection = document.selection, let key = event.specialKey else { return false }
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        var dx = 0, dy = 0
        switch key {
        case .leftArrow: dx = -step
        case .rightArrow: dx = step
        case .upArrow: dy = -step
        case .downArrow: dy = step
        default: return false
        }
        document.floatSelectionIfNeeded()
        selection.origin = PixelPoint(selection.origin.x + dx, selection.origin.y + dy)
        document.notifySelectionChanged()
        invalidateOverlay()
        return true
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        let cursor: NSCursor = spaceDown ? .openHand : tool.kind.cursor
        addCursorRect(imageRect, cursor: cursor)
        for grip in [CanvasGrip.right, .bottom, .corner] {
            let rect = gripRect(grip).insetBy(dx: -3, dy: -3)
            let c: NSCursor = grip == .bottom ? .resizeUpDown : (grip == .right ? .resizeLeftRight : .crosshair)
            addCursorRect(rect, cursor: c)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    // MARK: - Text editing

    func beginTextEditing(in rect: PixelRect) {
        endTextEditing(commit: true)

        let frame = viewRect(for: rect)
        let editor = NSTextView(frame: frame)
        editor.isRichText = false
        editor.drawsBackground = false
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.containerSize = NSSize(width: frame.width, height: frame.height)
        editor.textContainer?.widthTracksTextView = true
        editor.font = scaledFont()
        editor.textColor = settings.foreground.nsColor
        editor.insertionPointColor = settings.foreground.nsColor
        editor.allowsUndo = true

        addSubview(editor)
        textEditor = editor
        textEditRect = rect
        window?.makeFirstResponder(editor)
        setNeedsDisplay(frame.insetBy(dx: -4, dy: -4))
    }

    var isEditingText: Bool { textEditor != nil }

    /// Re-applies the current font and colour to a live text box.
    func refreshTextEditorAttributes() {
        guard let textEditor else { return }
        textEditor.font = scaledFont()
        textEditor.textColor = settings.foreground.nsColor
        textEditor.insertionPointColor = settings.foreground.nsColor
    }

    private func scaledFont() -> NSFont {
        let base = settings.currentFont()
        return NSFont(descriptor: base.fontDescriptor, size: base.pointSize * zoom) ?? base
    }

    func endTextEditing(commit: Bool) {
        guard let editor = textEditor, let rect = textEditRect else { return }
        let text = editor.string
        textEditor = nil
        textEditRect = nil
        editor.removeFromSuperview()
        if window?.firstResponder === editor { window?.makeFirstResponder(self) }

        guard commit, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setNeedsDisplay(viewRect(for: rect).insetBy(dx: -4, dy: -4))
            return
        }

        document.beginEdit()
        renderText(text, in: rect)
        document.commitEdit("Text")
        invalidate(rect)
    }

    private func renderText(_ text: String, in rect: PixelRect) {
        let buffer = document.image
        guard let cg = buffer.makeContext() else { return }

        // The bitmap's first row is the top one, while Quartz counts from the
        // bottom — flip so the text lands where the box was drawn.
        cg.saveGState()
        cg.translateBy(x: 0, y: CGFloat(buffer.height))
        cg.scaleBy(x: 1, y: -1)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

        if !settings.transparentSelection {
            settings.background.nsColor.setFill()
            rect.cgRect.fill()
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: settings.currentFont(),
            .foregroundColor: settings.foreground.nsColor,
        ]
        if settings.fontUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        (text as NSString).draw(in: rect.cgRect, withAttributes: attributes)

        NSGraphicsContext.current = previous
        cg.restoreGState()
    }
}
