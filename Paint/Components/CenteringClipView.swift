import AppKit

/// Keeps the canvas centred while it is smaller than the window, instead of
/// pinning it to a corner the way a plain clip view would.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let container = documentView else { return rect }
        let content = container.frame

        if rect.width > content.width {
            rect.origin.x = (content.width - rect.width) / 2
        }
        if rect.height > content.height {
            rect.origin.y = (content.height - rect.height) / 2
        }
        return rect
    }
}

/// A container that lays its content out from the top down. Without this, a
/// scroll view whose content is shorter than the clip view parks it at the
/// bottom — which is how the toolbox ended up floating mid-sidebar.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The neutral surround the canvas floats on.
enum CanvasChrome {
    static let backdrop = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.62, alpha: 1)
    }

    static let canvasBorder = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.35, alpha: 1) : NSColor(white: 0.35, alpha: 1)
    }

    /// Deliberately not appearance-aware: the grid sits on the *artwork*, which
    /// is usually white whatever the system theme is. A mid grey stays visible
    /// over light and dark pixels alike.
    static let gridLine = NSColor(white: 0.5, alpha: 0.55)
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
