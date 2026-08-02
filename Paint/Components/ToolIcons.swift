import AppKit

/// Toolbox glyphs. Most come from SF Symbols; the three that have no good
/// system equivalent — the bucket, the spray can and the rounded rectangle —
/// are drawn here as templates so they tint with the rest.
enum ToolIcons {
    private static var cache: [ToolKind: NSImage] = [:]

    static func image(for kind: ToolKind) -> NSImage {
        if let hit = cache[kind] { return hit }
        let image = build(kind)
        cache[kind] = image
        return image
    }

    private static func build(_ kind: ToolKind) -> NSImage {
        if let symbol = kind.symbolName,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: kind.title) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            return image.withSymbolConfiguration(config) ?? image
        }
        switch kind {
        case .fill: return bucket()
        case .airbrush: return sprayCan()
        case .roundedRectangle: return roundedRectangle()
        default: return NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil) ?? NSImage()
        }
    }

    private static func template(_ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func bucket() -> NSImage {
        template { _ in
            // Handle.
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 5, y: 6.5))
            handle.curve(to: NSPoint(x: 12.4, y: 6.5),
                         controlPoint1: NSPoint(x: 5.6, y: 0.8),
                         controlPoint2: NSPoint(x: 11.8, y: 0.8))
            handle.lineWidth = 1.3
            handle.stroke()

            // Body: a tapered tub sitting under an elliptical rim.
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 2.9, y: 7.2))
            body.line(to: NSPoint(x: 5.3, y: 15.4))
            body.curve(to: NSPoint(x: 11.2, y: 15.4),
                       controlPoint1: NSPoint(x: 7.2, y: 16.6),
                       controlPoint2: NSPoint(x: 9.3, y: 16.6))
            body.line(to: NSPoint(x: 13.6, y: 7.2))
            body.close()
            body.fill()

            let rim = NSBezierPath(ovalIn: NSRect(x: 2.9, y: 5.2, width: 10.7, height: 4))
            rim.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4.4, y: 6.1, width: 7.7, height: 2.3)).fill()
            NSColor.black.setFill()

            // A drip, so it reads as "pour" rather than "container".
            let drop = NSBezierPath()
            drop.move(to: NSPoint(x: 15.4, y: 8.6))
            drop.curve(to: NSPoint(x: 15.4, y: 14.2),
                       controlPoint1: NSPoint(x: 17.6, y: 11.6),
                       controlPoint2: NSPoint(x: 17.4, y: 14.2))
            drop.curve(to: NSPoint(x: 15.4, y: 8.6),
                       controlPoint1: NSPoint(x: 13.4, y: 14.2),
                       controlPoint2: NSPoint(x: 13.2, y: 11.6))
            drop.fill()
        }
    }

    private static func sprayCan() -> NSImage {
        template { _ in
            NSBezierPath(roundedRect: NSRect(x: 3.4, y: 6.4, width: 6.2, height: 9.6),
                         xRadius: 1.6, yRadius: 1.6).fill()
            NSBezierPath(rect: NSRect(x: 5.5, y: 3.6, width: 2, height: 2.9)).fill()
            NSBezierPath(roundedRect: NSRect(x: 4.9, y: 2.4, width: 3.2, height: 1.5),
                         xRadius: 0.6, yRadius: 0.6).fill()

            // Puff of spray.
            let dots: [(CGFloat, CGFloat, CGFloat)] = [
                (11.6, 4.2, 0.85), (14.0, 5.6, 0.7), (12.3, 7.4, 0.95),
                (15.2, 8.6, 0.7), (11.9, 10.4, 0.8), (14.3, 11.6, 0.62),
            ]
            for (x, y, r) in dots {
                NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
            }
        }
    }

    private static func roundedRectangle() -> NSImage {
        template { _ in
            let path = NSBezierPath(roundedRect: NSRect(x: 2.6, y: 4.6, width: 12.8, height: 8.8),
                                    xRadius: 3, yRadius: 3)
            path.lineWidth = 1.4
            path.stroke()
        }
    }
}
