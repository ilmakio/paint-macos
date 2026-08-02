import AppKit

extension NSImage {
    /// Recolours a template image — used to make a selected tool's glyph read
    /// against the accent-filled background.
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.set()
            self.draw(in: rect)
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A single toolbox cell: glyph, hover highlight, and an accent fill when it is
/// the active tool.
final class ToolButton: NSControl {
    let kind: ToolKind

    var isSelected: Bool = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    private var isHovering = false {
        didSet { if isHovering != oldValue { needsDisplay = true } }
    }

    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    init(kind: ToolKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = kind.helpText
        setAccessibilityLabel(kind.title)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)

        if isSelected {
            NSColor.controlAccentColor.setFill()
            path.fill()
        } else if isPressed {
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            path.fill()
        } else if isHovering {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            path.fill()
        }

        let glyph = ToolIcons.image(for: kind)
        let tint: NSColor = isSelected ? .white : .labelColor
        let tinted = glyph.tinted(with: tint)
        let size = glyph.size
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        tinted.draw(in: NSRect(origin: origin, size: size))
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        // Track the press so dragging off the button cancels it, like a real
        // AppKit control.
        var keepGoing = true
        while keepGoing {
            guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            switch next.type {
            case .leftMouseDragged:
                isPressed = inside
            case .leftMouseUp:
                keepGoing = false
                isPressed = false
                if inside { sendAction(action, to: target) }
            default:
                keepGoing = false
            }
        }
        isPressed = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func accessibilityValue() -> Any? { isSelected }
    override func isAccessibilityElement() -> Bool { true }
}
