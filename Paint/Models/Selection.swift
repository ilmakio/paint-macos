import Foundation

/// A floating selection: pixels lifted off the canvas that can be dragged,
/// stretched, deleted or stamped back down.
///
/// The pristine pixels are kept in `original` so repeated stretching always
/// resamples from full quality instead of degrading a copy of a copy.
final class Selection {
    /// Where it came from, or nil when it arrived from the clipboard and there
    /// is no hole to punch.
    var sourceRect: PixelRect?

    /// True once the hole has been punched in the canvas. A brand new marquee
    /// is not floating yet — Paint only cuts the pixels loose when you move it.
    var isFloating = false

    var origin: PixelPoint

    private(set) var buffer: PixelBuffer
    private(set) var mask: [Bool]?

    private let original: PixelBuffer
    private let originalMask: [Bool]?

    var width: Int { buffer.width }
    var height: Int { buffer.height }

    var rect: PixelRect {
        PixelRect(x: origin.x, y: origin.y, width: buffer.width, height: buffer.height)
    }

    init(buffer: PixelBuffer, origin: PixelPoint, mask: [Bool]? = nil, sourceRect: PixelRect?) {
        self.buffer = buffer
        self.original = buffer.copy()
        self.mask = mask
        self.originalMask = mask
        self.origin = origin
        self.sourceRect = sourceRect
    }

    /// Lifts a rectangle out of `image`.
    static func rectangular(from image: PixelBuffer, rect: PixelRect) -> Selection? {
        let r = rect.intersection(image.bounds)
        guard !r.isEmpty else { return nil }
        return Selection(buffer: image.extract(r), origin: r.origin, mask: nil, sourceRect: r)
    }

    /// Lifts an arbitrary polygon, keeping a mask so only the lassoed pixels
    /// travel with the selection.
    static func freeForm(from image: PixelBuffer, points: [PixelPoint]) -> Selection? {
        guard points.count >= 3 else { return nil }
        var bounds = PixelRect(x: points[0].x, y: points[0].y, width: 1, height: 1)
        for p in points {
            bounds = bounds.union(PixelRect(x: p.x, y: p.y, width: 1, height: 1))
        }
        let r = bounds.intersection(image.bounds)
        guard !r.isEmpty else { return nil }

        var mask = [Bool](repeating: false, count: r.width * r.height)
        Raster.polygonFill(points) { y, x0, x1 in
            guard y >= r.y, y < r.maxY else { return }
            let lo = max(x0, r.x), hi = min(x1, r.maxX - 1)
            guard hi >= lo else { return }
            let rowBase = (y - r.y) * r.width - r.x
            for x in lo ... hi { mask[rowBase + x] = true }
        }
        guard mask.contains(true) else { return nil }

        let extracted = image.extract(r)
        // Clear everything outside the lasso so the floating pixels composite
        // with the right silhouette.
        for i in 0 ..< mask.count where !mask[i] {
            extracted.storage[i] = Pixel.transparent.raw
        }
        return Selection(buffer: extracted, origin: r.origin, mask: mask, sourceRect: r)
    }

    /// Resamples to a new size, always starting from the pristine pixels.
    func resize(toWidth newW: Int, height newH: Int) {
        let w = max(1, newW), h = max(1, newH)
        guard w != buffer.width || h != buffer.height else { return }
        buffer = original.scaled(toWidth: w, height: h)
        if let originalMask {
            var scaled = [Bool](repeating: false, count: w * h)
            for y in 0 ..< h {
                let sy = min(original.height - 1, y * original.height / h)
                for x in 0 ..< w {
                    let sx = min(original.width - 1, x * original.width / w)
                    scaled[y * w + x] = originalMask[sy * original.width + sx]
                }
            }
            mask = scaled
        }
    }

    func flipHorizontally() {
        buffer = buffer.flippedHorizontally()
        mask = mask.map { flipMaskHorizontally($0, width: buffer.width, height: buffer.height) }
    }

    func flipVertically() {
        buffer = buffer.flippedVertically()
        mask = mask.map { flipMaskVertically($0, width: buffer.width, height: buffer.height) }
    }

    func rotate(degrees: Int) {
        let oldW = buffer.width, oldH = buffer.height
        buffer = buffer.rotated(degrees: degrees)
        if let m = mask {
            mask = rotateMask(m, width: oldW, height: oldH, degrees: degrees)
        }
    }

    func invertColors() {
        buffer = buffer.inverted()
    }

    private func flipMaskHorizontally(_ m: [Bool], width: Int, height: Int) -> [Bool] {
        var out = m
        for y in 0 ..< height {
            for x in 0 ..< width {
                out[y * width + x] = m[y * width + (width - 1 - x)]
            }
        }
        return out
    }

    private func flipMaskVertically(_ m: [Bool], width: Int, height: Int) -> [Bool] {
        var out = m
        for y in 0 ..< height {
            for x in 0 ..< width {
                out[y * width + x] = m[(height - 1 - y) * width + x]
            }
        }
        return out
    }

    private func rotateMask(_ m: [Bool], width: Int, height: Int, degrees: Int) -> [Bool] {
        let normalized = ((degrees % 360) + 360) % 360
        switch normalized {
        case 90:
            var out = [Bool](repeating: false, count: m.count)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    out[x * height + (height - 1 - y)] = m[y * width + x]
                }
            }
            return out
        case 180:
            var out = [Bool](repeating: false, count: m.count)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    out[(height - 1 - y) * width + (width - 1 - x)] = m[y * width + x]
                }
            }
            return out
        case 270:
            var out = [Bool](repeating: false, count: m.count)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    out[(width - 1 - x) * height + y] = m[y * width + x]
                }
            }
            return out
        default:
            return m
        }
    }

    /// Stamps the floating pixels down onto `image`.
    func composite(onto image: PixelBuffer, transparentColor: Pixel?) {
        image.draw(buffer, at: origin, mask: mask, skipping: transparentColor)
    }
}

/// The eight drag handles around a floating selection.
enum SelectionHandle: Int, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Handle centres in canvas pixel space.
    func position(in rect: PixelRect) -> PixelPoint {
        let midX = rect.x + rect.width / 2
        let midY = rect.y + rect.height / 2
        switch self {
        case .topLeft: return PixelPoint(rect.x, rect.y)
        case .top: return PixelPoint(midX, rect.y)
        case .topRight: return PixelPoint(rect.maxX, rect.y)
        case .right: return PixelPoint(rect.maxX, midY)
        case .bottomRight: return PixelPoint(rect.maxX, rect.maxY)
        case .bottom: return PixelPoint(midX, rect.maxY)
        case .bottomLeft: return PixelPoint(rect.x, rect.maxY)
        case .left: return PixelPoint(rect.x, midY)
        }
    }

    var movesLeftEdge: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRightEdge: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTopEdge: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottomEdge: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}
