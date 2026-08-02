import AppKit

/// The bottom colour bar: the two active colours on the left, the 28-swatch
/// palette beside them.
///
/// Left-click sets the foreground, right-click sets the background, and a
/// double-click opens the colour panel to redefine that swatch — the same
/// gestures the original used.
final class PaletteView: NSView {

    private enum ColorTarget {
        case foreground
        case background
        case palette(Int)
    }

    private var colorTarget: ColorTarget = .foreground

    private let wellsOrigin = NSPoint(x: 12, y: 8)
    private let wellSize: CGFloat = 28
    private let wellOffset: CGFloat = 16
    private let swatchSize: CGFloat = 18
    private let swatchGap: CGFloat = 2

    private var gridOrigin: NSPoint {
        NSPoint(x: wellsOrigin.x + wellSize + wellOffset + 26, y: 8)
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 62)
    }

    override func draw(_ dirtyRect: NSRect) {
        let settings = PaintSettings.shared

        drawWell(rect: backgroundWellRect, color: settings.background, label: "Background")
        drawWell(rect: foregroundWellRect, color: settings.foreground, label: "Foreground")
        drawSwapGlyph()
        drawResetGlyph()

        for index in settings.palette.indices {
            let rect = swatchRect(index)
            guard rect.intersects(dirtyRect) else { continue }
            drawSwatch(rect: rect, color: settings.palette[index])
        }
    }

    // MARK: Geometry

    private var foregroundWellRect: NSRect {
        NSRect(x: wellsOrigin.x, y: wellsOrigin.y, width: wellSize, height: wellSize)
    }

    private var backgroundWellRect: NSRect {
        NSRect(x: wellsOrigin.x + wellOffset, y: wellsOrigin.y + wellOffset,
               width: wellSize, height: wellSize)
    }

    private var swapGlyphRect: NSRect {
        NSRect(x: wellsOrigin.x + wellSize + wellOffset + 3, y: wellsOrigin.y - 2, width: 14, height: 14)
    }

    private var resetGlyphRect: NSRect {
        NSRect(x: wellsOrigin.x - 3, y: wellsOrigin.y + wellSize + wellOffset - 10, width: 13, height: 13)
    }

    private func swatchRect(_ index: Int) -> NSRect {
        let column = index % Palette.columns
        let row = index / Palette.columns
        return NSRect(x: gridOrigin.x + CGFloat(column) * (swatchSize + swatchGap),
                      y: gridOrigin.y + CGFloat(row) * (swatchSize + swatchGap),
                      width: swatchSize, height: swatchSize)
    }

    // MARK: Painting

    private func drawWell(rect: NSRect, color: Pixel, label: String) {
        // A shadow lifts the two wells off the bar and shows which is in front.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        NSGraphicsContext.restoreGraphicsState()

        drawCheckerboard(in: rect, radius: 4)
        color.nsColor.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
        setAccessibilityLabel(label)
    }

    private func drawSwatch(rect: NSRect, color: Pixel) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        color.nsColor.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawCheckerboard(in rect: NSRect, radius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        NSColor.white.setFill()
        rect.fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        let tile: CGFloat = 6
        var y = rect.minY
        var rowIndex = 0
        while y < rect.maxY {
            var x = rect.minX + (rowIndex % 2 == 0 ? 0 : tile)
            while x < rect.maxX {
                NSRect(x: x, y: y, width: tile, height: tile).intersection(rect).fill()
                x += tile * 2
            }
            y += tile
            rowIndex += 1
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSwapGlyph() {
        guard let symbol = NSImage(systemSymbolName: "arrow.2.squarepath",
                                   accessibilityDescription: "Swap colours") else { return }
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)) ?? symbol
        configured.tinted(with: .secondaryLabelColor).draw(in: swapGlyphRect)
    }

    private func drawResetGlyph() {
        let rect = resetGlyphRect
        NSColor.white.setFill()
        let back = NSRect(x: rect.minX + 4, y: rect.minY + 4, width: 8, height: 8)
        NSBezierPath(rect: back).fill()
        NSColor.labelColor.withAlphaComponent(0.4).setStroke()
        NSBezierPath(rect: back).stroke()
        NSColor.black.setFill()
        let front = NSRect(x: rect.minX, y: rect.minY, width: 8, height: 8)
        NSBezierPath(rect: front).fill()
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if swapGlyphRect.insetBy(dx: -3, dy: -3).contains(point) {
            PaintSettings.shared.swapColors()
            return
        }
        if resetGlyphRect.insetBy(dx: -3, dy: -3).contains(point) {
            PaintSettings.shared.resetColors()
            return
        }
        if foregroundWellRect.contains(point) {
            openColorPanel(for: .foreground)
            return
        }
        if backgroundWellRect.contains(point) {
            openColorPanel(for: .background)
            return
        }
        if let index = swatchIndex(at: point) {
            if event.clickCount == 2 {
                openColorPanel(for: .palette(index))
            } else {
                PaintSettings.shared.foreground = PaintSettings.shared.palette[index]
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = swatchIndex(at: point) {
            PaintSettings.shared.background = PaintSettings.shared.palette[index]
        }
    }

    private func swatchIndex(at point: NSPoint) -> Int? {
        for index in PaintSettings.shared.palette.indices where swatchRect(index).contains(point) {
            return index
        }
        return nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        for index in PaintSettings.shared.palette.indices {
            addCursorRect(swatchRect(index), cursor: .pointingHand)
        }
        addCursorRect(foregroundWellRect, cursor: .pointingHand)
        addCursorRect(backgroundWellRect, cursor: .pointingHand)
    }

    // MARK: Colour panel

    func openForegroundColorPanel() { openColorPanel(for: .foreground) }
    func openBackgroundColorPanel() { openColorPanel(for: .background) }

    private func openColorPanel(for target: ColorTarget) {
        colorTarget = target
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = colorFor(target).nsColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    private func colorFor(_ target: ColorTarget) -> Pixel {
        switch target {
        case .foreground: return PaintSettings.shared.foreground
        case .background: return PaintSettings.shared.background
        case let .palette(index): return PaintSettings.shared.palette[index]
        }
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        let picked = Pixel(sender.color)
        switch colorTarget {
        case .foreground:
            PaintSettings.shared.foreground = picked
        case .background:
            PaintSettings.shared.background = picked
        case let .palette(index):
            var palette = PaintSettings.shared.palette
            guard palette.indices.contains(index) else { return }
            palette[index] = picked
            PaintSettings.shared.palette = palette
            // Editing a swatch also picks it, which is what you almost always
            // want next.
            PaintSettings.shared.foreground = picked
        }
    }
}
