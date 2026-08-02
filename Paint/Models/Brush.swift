import Foundation

/// The four nib shapes from Paint's brush box.
enum BrushShape: Int, CaseIterable {
    case round
    case square
    case forwardSlash
    case backSlash

    var displayName: String {
        switch self {
        case .round: return "Round"
        case .square: return "Square"
        case .forwardSlash: return "Forward slash"
        case .backSlash: return "Back slash"
        }
    }
}

/// A nib, precomputed as horizontal runs relative to the cursor.
///
/// Storing runs rather than individual points keeps a 64px round brush to a few
/// dozen `memset`s per stamp instead of three thousand pixel writes.
struct BrushStamp {
    struct Span {
        let dy: Int
        let dx0: Int
        let dx1: Int
    }

    let spans: [Span]
    let bounds: PixelRect

    // Stamps are rebuilt only when the shape or size changes, and every tool
    // reuses the same nib, so a tiny cache removes the work entirely.
    private static var cache: [Int: BrushStamp] = [:]

    static func make(shape: BrushShape, size: Int) -> BrushStamp {
        let clamped = max(1, min(size, 200))
        let key = shape.rawValue << 16 | clamped
        if let hit = cache[key] { return hit }
        let stamp = build(shape: shape, size: clamped)
        cache[key] = stamp
        return stamp
    }

    private static func build(shape: BrushShape, size d: Int) -> BrushStamp {
        // Even sizes put the extra pixel down and to the right, matching Paint.
        let origin = -((d - 1) / 2)
        let box = PixelRect(x: origin, y: origin, width: d, height: d)
        var spans: [Span] = []

        switch shape {
        case .square:
            for y in box.y ..< box.maxY {
                spans.append(Span(dy: y, dx0: box.x, dx1: box.maxX - 1))
            }
        case .round:
            if d <= 2 {
                for y in box.y ..< box.maxY {
                    spans.append(Span(dy: y, dx0: box.x, dx1: box.maxX - 1))
                }
            } else {
                Raster.ellipseFill(in: box) { y, x0, x1 in
                    spans.append(Span(dy: y, dx0: x0, dx1: x1))
                }
            }
        case .forwardSlash:
            var points: [PixelPoint] = []
            Raster.line(from: PixelPoint(box.x, box.maxY - 1), to: PixelPoint(box.maxX - 1, box.y)) {
                points.append(PixelPoint($0, $1))
            }
            spans = points.map { Span(dy: $0.y, dx0: $0.x, dx1: $0.x) }
        case .backSlash:
            var points: [PixelPoint] = []
            Raster.line(from: PixelPoint(box.x, box.y), to: PixelPoint(box.maxX - 1, box.maxY - 1)) {
                points.append(PixelPoint($0, $1))
            }
            spans = points.map { Span(dy: $0.y, dx0: $0.x, dx1: $0.x) }
        }

        if spans.isEmpty { spans = [Span(dy: 0, dx0: 0, dx1: 0)] }

        var bounds = PixelRect(x: spans[0].dx0, y: spans[0].dy, width: 1, height: 1)
        for s in spans {
            bounds = bounds.union(PixelRect(x: s.dx0, y: s.dy, width: s.dx1 - s.dx0 + 1, height: 1))
        }
        return BrushStamp(spans: spans, bounds: bounds)
    }

    /// Paints one impression at `p`, returning the rect it touched.
    @discardableResult
    func apply(to buffer: PixelBuffer, at p: PixelPoint, color: Pixel) -> PixelRect {
        var dirty = PixelRect.zero
        let opaque = color.a == 255
        for span in spans {
            let y = p.y + span.dy
            guard y >= 0, y < buffer.height else { continue }
            let x0 = max(0, p.x + span.dx0)
            let x1 = min(buffer.width - 1, p.x + span.dx1)
            guard x1 >= x0 else { continue }
            if opaque {
                (buffer.storage + y * buffer.width + x0).update(repeating: color.raw, count: x1 - x0 + 1)
            } else {
                for x in x0 ... x1 { buffer.blendPixel(x, y, color) }
            }
            dirty = dirty.union(PixelRect(x: x0, y: y, width: x1 - x0 + 1, height: 1))
        }
        return dirty
    }

    /// Drags the nib along a Bresenham line, the way every freehand stroke and
    /// thick shape edge is built.
    @discardableResult
    func stroke(on buffer: PixelBuffer, from a: PixelPoint, to b: PixelPoint, color: Pixel) -> PixelRect {
        var dirty = PixelRect.zero
        Raster.line(from: a, to: b) { x, y in
            dirty = dirty.union(apply(to: buffer, at: PixelPoint(x, y), color: color))
        }
        return dirty
    }

    /// The rect a stamp at `p` would cover, without painting anything — used to
    /// invalidate just enough of the view while the cursor moves.
    func coverage(at p: PixelPoint) -> PixelRect {
        bounds.offsetBy(dx: p.x, dy: p.y)
    }
}

/// The airbrush: random dots inside a circle, sprayed while the button is held.
enum Airbrush {
    @discardableResult
    static func spray(on buffer: PixelBuffer, at centre: PixelPoint, radius: Int, density: Int,
                      color: Pixel, using generator: inout SystemRandomNumberGenerator) -> PixelRect {
        var dirty = PixelRect.zero
        let r = max(1, radius)
        for _ in 0 ..< max(1, density) {
            // Rejection-sample the disc so the spray stays round and even.
            let angle = Double.random(in: 0 ..< (2 * .pi), using: &generator)
            let distance = Double.random(in: 0 ... 1, using: &generator).squareRoot() * Double(r)
            let x = centre.x + Int((cos(angle) * distance).rounded())
            let y = centre.y + Int((sin(angle) * distance).rounded())
            guard buffer.contains(x, y) else { continue }
            buffer.blendPixel(x, y, color)
            dirty = dirty.union(PixelRect(x: x, y: y, width: 1, height: 1))
        }
        return dirty
    }
}
