import Foundation

/// Pure integer rasterisation. Nothing here touches a buffer directly — every
/// routine reports the pixels it wants via a callback, so the same geometry can
/// paint the canvas, build a selection mask, or feed a preview overlay.
enum Raster {

    /// A horizontal run of pixels, inclusive on both ends.
    typealias SpanSink = (_ y: Int, _ x0: Int, _ x1: Int) -> Void
    typealias PointSink = (_ x: Int, _ y: Int) -> Void

    // MARK: - Lines

    /// Bresenham. 8-connected, exactly like Paint's 1px line — which is also
    /// why a diagonal hairline can leak the bucket, same as the original.
    static func line(from a: PixelPoint, to b: PixelPoint, plot: PointSink) {
        var x0 = a.x, y0 = a.y
        let x1 = b.x, y1 = b.y
        let dx = abs(x1 - x0)
        let dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1
        let sy = y0 < y1 ? 1 : -1
        var err = dx + dy

        while true {
            plot(x0, y0)
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy {
                if x0 == x1 { break }
                err += dy
                x0 += sx
            }
            if e2 <= dx {
                if y0 == y1 { break }
                err += dx
                y0 += sy
            }
        }
    }

    /// Cubic Bézier, flattened into short line segments. The segment count
    /// tracks the control polygon's length so long curves stay smooth.
    static func cubicBezier(_ p0: PixelPoint, _ c1: PixelPoint, _ c2: PixelPoint, _ p3: PixelPoint,
                            plot: PointSink) {
        let approxLength = distance(p0, c1) + distance(c1, c2) + distance(c2, p3)
        let steps = max(8, min(2048, Int(approxLength)))
        var previous = p0
        for i in 1 ... steps {
            let t = Double(i) / Double(steps)
            let mt = 1 - t
            let w0 = mt * mt * mt
            let w1 = 3 * mt * mt * t
            let w2 = 3 * mt * t * t
            let w3 = t * t * t
            let x = w0 * Double(p0.x) + w1 * Double(c1.x) + w2 * Double(c2.x) + w3 * Double(p3.x)
            let y = w0 * Double(p0.y) + w1 * Double(c1.y) + w2 * Double(c2.y) + w3 * Double(p3.y)
            let point = PixelPoint(Int(x.rounded()), Int(y.rounded()))
            if point != previous {
                line(from: previous, to: point, plot: plot)
                previous = point
            }
        }
        if previous != p3 { line(from: previous, to: p3, plot: plot) }
    }

    private static func distance(_ a: PixelPoint, _ b: PixelPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Rectangles

    static func rectangleFill(_ rect: PixelRect, span: SpanSink) {
        guard !rect.isEmpty else { return }
        for y in rect.y ..< rect.maxY {
            span(y, rect.x, rect.maxX - 1)
        }
    }

    static func rectangleOutline(_ rect: PixelRect, thickness: Int, span: SpanSink) {
        guard !rect.isEmpty else { return }
        let t = max(1, min(thickness, min(rect.width, rect.height)))
        // Top and bottom bands run full width; the sides fill what is left.
        for y in rect.y ..< min(rect.y + t, rect.maxY) {
            span(y, rect.x, rect.maxX - 1)
        }
        for y in max(rect.maxY - t, rect.y + t) ..< rect.maxY {
            span(y, rect.x, rect.maxX - 1)
        }
        let innerTop = rect.y + t
        let innerBottom = rect.maxY - t
        guard innerTop < innerBottom else { return }
        for y in innerTop ..< innerBottom {
            span(y, rect.x, min(rect.x + t - 1, rect.maxX - 1))
            span(y, max(rect.maxX - t, rect.x), rect.maxX - 1)
        }
    }

    // MARK: - Ellipses

    /// Horizontal extent of the ellipse inscribed in `rect`, for one scanline.
    /// Returns nil when the row misses the ellipse entirely.
    private static func ellipseSpan(in rect: PixelRect, y: Int) -> (Int, Int)? {
        guard !rect.isEmpty else { return nil }
        let cx = Double(rect.x) + Double(rect.width) / 2
        let cy = Double(rect.y) + Double(rect.height) / 2
        let rx = Double(rect.width) / 2
        let ry = Double(rect.height) / 2
        let dy = (Double(y) + 0.5 - cy) / ry
        let inside = 1 - dy * dy
        guard inside >= 0 else { return nil }
        let dx = inside.squareRoot() * rx
        let x0 = Int((cx - dx - 0.5).rounded(.up))
        let x1 = Int((cx + dx - 0.5).rounded(.down))
        guard x1 >= x0 else {
            // A sliver thinner than one pixel still deserves a pixel.
            let single = Int((cx - 0.5).rounded())
            return (single, single)
        }
        return (x0, x1)
    }

    static func ellipseFill(in rect: PixelRect, span: SpanSink) {
        guard !rect.isEmpty else { return }
        for y in rect.y ..< rect.maxY {
            if let (x0, x1) = ellipseSpan(in: rect, y: y) { span(y, x0, x1) }
        }
    }

    /// The ring between the ellipse and the same ellipse inset by `thickness`.
    ///
    /// Because both are nested convex shapes, consecutive rows of the ring
    /// always overlap horizontally, so the outline comes out 4-connected — the
    /// bucket cannot leak through it.
    static func ellipseOutline(in rect: PixelRect, thickness: Int, span: SpanSink) {
        guard !rect.isEmpty else { return }
        let t = max(1, thickness)
        let inner = rect.insetBy(t)
        guard !inner.isEmpty else {
            ellipseFill(in: rect, span: span)
            return
        }
        for y in rect.y ..< rect.maxY {
            guard let (ox0, ox1) = ellipseSpan(in: rect, y: y) else { continue }
            guard y >= inner.y, y < inner.maxY, let (ix0, ix1) = ellipseSpan(in: inner, y: y) else {
                span(y, ox0, ox1)
                continue
            }
            if ix0 - 1 >= ox0 { span(y, ox0, ix0 - 1) }
            if ox1 >= ix1 + 1 { span(y, ix1 + 1, ox1) }
        }
    }

    // MARK: - Rounded rectangles

    /// Leftmost pixel of a rounded rect on one scanline; the shape is symmetric
    /// so the right edge mirrors it.
    private static func roundedInset(_ rect: PixelRect, radius: Int, y: Int) -> Int? {
        guard !rect.isEmpty else { return nil }
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        guard r > 0 else { return 0 }
        let cy = Double(y) + 0.5
        let topCentre = Double(rect.y + r)
        let bottomCentre = Double(rect.maxY - r)
        var dy = 0.0
        if cy < topCentre {
            dy = topCentre - cy
        } else if cy > bottomCentre {
            dy = cy - bottomCentre
        } else {
            return 0
        }
        let rr = Double(r)
        let inside = rr * rr - dy * dy
        guard inside >= 0 else { return nil }
        let dx = rr - inside.squareRoot()
        return max(0, Int((dx - 0.5).rounded(.up)))
    }

    static func roundedRectangleFill(in rect: PixelRect, radius: Int, span: SpanSink) {
        guard !rect.isEmpty else { return }
        for y in rect.y ..< rect.maxY {
            guard let inset = roundedInset(rect, radius: radius, y: y) else { continue }
            let x0 = rect.x + inset
            let x1 = rect.maxX - 1 - inset
            if x1 >= x0 { span(y, x0, x1) }
        }
    }

    static func roundedRectangleOutline(in rect: PixelRect, radius: Int, thickness: Int, span: SpanSink) {
        guard !rect.isEmpty else { return }
        let t = max(1, thickness)
        let inner = rect.insetBy(t)
        guard !inner.isEmpty else {
            roundedRectangleFill(in: rect, radius: radius, span: span)
            return
        }
        let innerRadius = max(0, radius - t)
        for y in rect.y ..< rect.maxY {
            guard let outerInset = roundedInset(rect, radius: radius, y: y) else { continue }
            let ox0 = rect.x + outerInset
            let ox1 = rect.maxX - 1 - outerInset
            guard ox1 >= ox0 else { continue }

            guard y >= inner.y, y < inner.maxY,
                  let innerInset = roundedInset(inner, radius: innerRadius, y: y)
            else {
                span(y, ox0, ox1)
                continue
            }
            let ix0 = inner.x + innerInset
            let ix1 = inner.maxX - 1 - innerInset
            guard ix1 >= ix0 else {
                span(y, ox0, ox1)
                continue
            }
            if ix0 - 1 >= ox0 { span(y, ox0, ix0 - 1) }
            if ox1 >= ix1 + 1 { span(y, ix1 + 1, ox1) }
        }
    }

    /// Paint scales the corner with the shape, but never past a soft ceiling.
    static func defaultCornerRadius(for rect: PixelRect) -> Int {
        max(2, min(16, min(rect.width, rect.height) / 5))
    }

    // MARK: - Polygons

    /// Even-odd scanline fill, boundary included.
    ///
    /// The edges are treated as running through pixel *centres*, so the
    /// scanline pass alone drops the bottom and right boundary pixels — the
    /// classic half-open fill rule. Stroking the outline afterwards puts them
    /// back, which is what both callers want: a filled polygon should meet its
    /// own outline, and a lasso should carry the pixels you dragged through.
    static func polygonFill(_ points: [PixelPoint], span: SpanSink) {
        guard points.count >= 3 else { return }
        let minY = points.map(\.y).min()!
        let maxY = points.map(\.y).max()!
        var crossings: [Double] = []
        for y in minY ... maxY {
            crossings.removeAll(keepingCapacity: true)
            let scanY = Double(y) + 0.5
            for i in 0 ..< points.count {
                let a = points[i]
                let b = points[(i + 1) % points.count]
                let ay = Double(a.y) + 0.5
                let by = Double(b.y) + 0.5
                guard (ay <= scanY && by > scanY) || (by <= scanY && ay > scanY) else { continue }
                let t = (scanY - ay) / (by - ay)
                // Pixel centres on this axis too, matching the y comparison above.
                crossings.append(Double(a.x) + 0.5 + t * Double(b.x - a.x))
            }
            guard crossings.count >= 2 else { continue }
            crossings.sort()
            var i = 0
            while i + 1 < crossings.count {
                let x0 = Int((crossings[i] - 0.5).rounded(.up))
                let x1 = Int((crossings[i + 1] - 0.5).rounded(.down))
                if x1 >= x0 { span(y, x0, x1) }
                i += 2
            }
        }
        polygonOutline(points, closed: true) { x, y in span(y, x, x) }
    }

    static func polygonOutline(_ points: [PixelPoint], closed: Bool, plot: PointSink) {
        guard points.count >= 2 else {
            if let p = points.first { plot(p.x, p.y) }
            return
        }
        for i in 0 ..< (points.count - 1) {
            line(from: points[i], to: points[i + 1], plot: plot)
        }
        if closed, points.count > 2 {
            line(from: points[points.count - 1], to: points[0], plot: plot)
        }
    }

    // MARK: - Constraints

    /// Shift-constrains a drag: shapes become square/circular, lines snap to
    /// the nearest 45°.
    static func constrainToSquare(from anchor: PixelPoint, to point: PixelPoint) -> PixelPoint {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let size = max(abs(dx), abs(dy))
        return PixelPoint(anchor.x + (dx < 0 ? -size : size), anchor.y + (dy < 0 ? -size : size))
    }

    static func constrainToAngle(from anchor: PixelPoint, to point: PixelPoint) -> PixelPoint {
        let dx = Double(point.x - anchor.x)
        let dy = Double(point.y - anchor.y)
        guard dx != 0 || dy != 0 else { return point }
        let angle = atan2(dy, dx)
        let step = Double.pi / 4
        let snapped = (angle / step).rounded() * step
        let length = (dx * dx + dy * dy).squareRoot()
        return PixelPoint(
            anchor.x + Int((cos(snapped) * length).rounded()),
            anchor.y + Int((sin(snapped) * length).rounded())
        )
    }
}
