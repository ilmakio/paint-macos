import CoreGraphics
import Foundation

// MARK: - Integer geometry
//
// The whole drawing core works in integer pixel space. Keeping a dedicated
// point/rect pair (instead of leaning on CGPoint/CGRect) means there is exactly
// one place where floating point can sneak in — the view layer — so a stroke
// always lands on the pixel the user is pointing at.

struct PixelPoint: Equatable, Hashable {
    var x: Int
    var y: Int

    init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    static let zero = PixelPoint(0, 0)
}

/// A half-open rectangle: `x ..< maxX`, `y ..< maxY`.
struct PixelRect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }
    var origin: PixelPoint { PixelPoint(x, y) }

    /// The smallest rect containing both corners, treating each as a pixel.
    static func bounding(_ a: PixelPoint, _ b: PixelPoint) -> PixelRect {
        let minX = min(a.x, b.x), maxX = max(a.x, b.x)
        let minY = min(a.y, b.y), maxY = max(a.y, b.y)
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func contains(_ p: PixelPoint) -> Bool {
        p.x >= x && p.x < maxX && p.y >= y && p.y < maxY
    }

    func intersection(_ other: PixelRect) -> PixelRect {
        let nx = max(x, other.x), ny = max(y, other.y)
        let nmaxX = min(maxX, other.maxX), nmaxY = min(maxY, other.maxY)
        if nmaxX <= nx || nmaxY <= ny { return .zero }
        return PixelRect(x: nx, y: ny, width: nmaxX - nx, height: nmaxY - ny)
    }

    func union(_ other: PixelRect) -> PixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let nx = min(x, other.x), ny = min(y, other.y)
        let nmaxX = max(maxX, other.maxX), nmaxY = max(maxY, other.maxY)
        return PixelRect(x: nx, y: ny, width: nmaxX - nx, height: nmaxY - ny)
    }

    func insetBy(_ d: Int) -> PixelRect {
        PixelRect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d)
    }

    func offsetBy(dx: Int, dy: Int) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}

// MARK: - Pixel

/// One ARGB pixel stored as a little-endian `UInt32` laid out `0xAARRGGBB`.
///
/// That is exactly `premultipliedFirst | byteOrder32Little`, the format Core
/// Graphics blits without conversion on Apple silicon, so the canvas can be
/// handed straight to a `CGContext` with no per-frame repacking.
struct Pixel: Equatable, Hashable {
    var raw: UInt32

    init(raw: UInt32) { self.raw = raw }

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        raw = (UInt32(a) << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }

    var a: UInt8 { UInt8(truncatingIfNeeded: raw >> 24) }
    var r: UInt8 { UInt8(truncatingIfNeeded: raw >> 16) }
    var g: UInt8 { UInt8(truncatingIfNeeded: raw >> 8) }
    var b: UInt8 { UInt8(truncatingIfNeeded: raw) }

    var isOpaque: Bool { a == 255 }

    static let white = Pixel(r: 255, g: 255, b: 255)
    static let black = Pixel(r: 0, g: 0, b: 0)
    static let transparent = Pixel(raw: 0)

    /// Multiplies the colour channels down by alpha, as the buffer format requires.
    var premultiplied: Pixel {
        if a == 255 { return self }
        if a == 0 { return .transparent }
        let alpha = UInt32(a)
        let nr = (UInt32(r) * alpha + 127) / 255
        let ng = (UInt32(g) * alpha + 127) / 255
        let nb = (UInt32(b) * alpha + 127) / 255
        return Pixel(r: UInt8(nr), g: UInt8(ng), b: UInt8(nb), a: a)
    }

    /// Undoes premultiplication, for handing a colour back to AppKit.
    var straight: Pixel {
        if a == 255 || a == 0 { return self }
        let alpha = UInt32(a)
        let nr = min(255, UInt32(r) * 255 / alpha)
        let ng = min(255, UInt32(g) * 255 / alpha)
        let nb = min(255, UInt32(b) * 255 / alpha)
        return Pixel(r: UInt8(nr), g: UInt8(ng), b: UInt8(nb), a: a)
    }

    /// Source-over composite of `src` (premultiplied) onto `self`.
    func blended(with src: Pixel) -> Pixel {
        if src.a == 255 { return src }
        if src.a == 0 { return self }
        let inv = 255 - UInt32(src.a)
        func chan(_ s: UInt8, _ d: UInt8) -> UInt8 {
            UInt8(truncatingIfNeeded: UInt32(s) + (UInt32(d) * inv + 127) / 255)
        }
        return Pixel(r: chan(src.r, r), g: chan(src.g, g), b: chan(src.b, b), a: chan(src.a, a))
    }

    /// Channel-wise distance, used by the bucket's tolerance slider.
    func distance(to other: Pixel) -> Int {
        let dr = abs(Int(r) - Int(other.r))
        let dg = abs(Int(g) - Int(other.g))
        let db = abs(Int(b) - Int(other.b))
        let da = abs(Int(a) - Int(other.a))
        return max(max(dr, dg), max(db, da))
    }
}

// MARK: - PixelBuffer

/// A mutable ARGB32 raster. This is the single source of truth for image data:
/// every tool writes here, and the view simply mirrors it to the screen.
final class PixelBuffer {
    let width: Int
    let height: Int
    let storage: UnsafeMutablePointer<UInt32>

    var count: Int { width * height }
    var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    init(width: Int, height: Int, fill: Pixel = .white) {
        self.width = max(1, width)
        self.height = max(1, height)
        storage = UnsafeMutablePointer<UInt32>.allocate(capacity: self.width * self.height)
        storage.initialize(repeating: fill.raw, count: self.width * self.height)
    }

    deinit {
        storage.deinitialize(count: width * height)
        storage.deallocate()
    }

    // MARK: Pixel access

    @inline(__always)
    func index(_ x: Int, _ y: Int) -> Int { y * width + x }

    @inline(__always)
    func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// Unchecked read. Callers must have already clipped.
    @inline(__always)
    func unsafePixel(_ x: Int, _ y: Int) -> Pixel { Pixel(raw: storage[y * width + x]) }

    @inline(__always)
    func pixel(_ x: Int, _ y: Int) -> Pixel? {
        contains(x, y) ? Pixel(raw: storage[y * width + x]) : nil
    }

    /// Overwrites the pixel, ignoring alpha. Out-of-bounds writes are dropped.
    @inline(__always)
    func setPixel(_ x: Int, _ y: Int, _ p: Pixel) {
        guard contains(x, y) else { return }
        storage[y * width + x] = p.raw
    }

    /// Source-over composites onto the pixel. Out-of-bounds writes are dropped.
    @inline(__always)
    func blendPixel(_ x: Int, _ y: Int, _ p: Pixel) {
        guard contains(x, y) else { return }
        if p.a == 255 {
            storage[y * width + x] = p.raw
        } else if p.a != 0 {
            let i = y * width + x
            storage[i] = Pixel(raw: storage[i]).blended(with: p).raw
        }
    }

    // MARK: Bulk operations

    func fill(_ rect: PixelRect, with p: Pixel) {
        let r = rect.intersection(bounds)
        guard !r.isEmpty else { return }
        for y in r.y ..< r.maxY {
            let row = storage + y * width + r.x
            row.update(repeating: p.raw, count: r.width)
        }
    }

    func fillAll(_ p: Pixel) {
        storage.update(repeating: p.raw, count: count)
    }

    func copy() -> PixelBuffer {
        let out = PixelBuffer(width: width, height: height)
        out.storage.update(from: storage, count: count)
        return out
    }

    /// Snapshots a rect into a flat array, for the undo stack.
    func snapshot(_ rect: PixelRect) -> [UInt32] {
        let r = rect.intersection(bounds)
        guard !r.isEmpty else { return [] }
        var out = [UInt32](repeating: 0, count: r.width * r.height)
        out.withUnsafeMutableBufferPointer { dst in
            for row in 0 ..< r.height {
                let src = storage + (r.y + row) * width + r.x
                (dst.baseAddress! + row * r.width).update(from: src, count: r.width)
            }
        }
        return out
    }

    /// Puts a snapshot back. `pixels` must be `rect.width * rect.height` long.
    func restore(_ rect: PixelRect, from pixels: [UInt32]) {
        let r = rect.intersection(bounds)
        guard !r.isEmpty, pixels.count == r.width * r.height else { return }
        pixels.withUnsafeBufferPointer { src in
            for row in 0 ..< r.height {
                let dst = storage + (r.y + row) * width + r.x
                dst.update(from: src.baseAddress! + row * r.width, count: r.width)
            }
        }
    }

    /// Extracts a sub-image. Pixels outside the buffer come back transparent.
    func extract(_ rect: PixelRect) -> PixelBuffer {
        let out = PixelBuffer(width: max(1, rect.width), height: max(1, rect.height), fill: .transparent)
        let r = rect.intersection(bounds)
        guard !r.isEmpty else { return out }
        for y in r.y ..< r.maxY {
            let src = storage + y * width + r.x
            let dst = out.storage + (y - rect.y) * out.width + (r.x - rect.x)
            dst.update(from: src, count: r.width)
        }
        return out
    }

    /// Composites `other` at `origin`. `mask`, when given, is row-major over
    /// `other` and gates which pixels land — that is how free-form selections
    /// keep their lasso shape.
    func draw(_ other: PixelBuffer, at origin: PixelPoint, mask: [Bool]? = nil, skipping skipColor: Pixel? = nil) {
        for sy in 0 ..< other.height {
            let dy = origin.y + sy
            guard dy >= 0, dy < height else { continue }
            for sx in 0 ..< other.width {
                let dx = origin.x + sx
                guard dx >= 0, dx < width else { continue }
                if let mask, !mask[sy * other.width + sx] { continue }
                let p = other.unsafePixel(sx, sy)
                if let skipColor, p.a == 255, p.raw == skipColor.raw { continue }
                blendPixel(dx, dy, p)
            }
        }
    }

    // MARK: Core Graphics bridging

    static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )

    /// A context drawing straight into this buffer's memory — no copy. Used by
    /// the text tool, which needs Core Text to rasterise glyphs for us.
    func makeContext() -> CGContext? {
        CGContext(
            data: storage,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: PixelBuffer.bitmapInfo.rawValue
        )
    }

    func makeCGImage() -> CGImage? {
        makeContext()?.makeImage()
    }

    convenience init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        self.init(width: w, height: h, fill: .transparent)
        guard let ctx = makeContext() else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    }

    // MARK: Whole-image transforms

    func flippedHorizontally() -> PixelBuffer {
        let out = PixelBuffer(width: width, height: height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                out.storage[y * width + x] = storage[y * width + (width - 1 - x)]
            }
        }
        return out
    }

    func flippedVertically() -> PixelBuffer {
        let out = PixelBuffer(width: width, height: height)
        for y in 0 ..< height {
            let src = storage + (height - 1 - y) * width
            (out.storage + y * width).update(from: src, count: width)
        }
        return out
    }

    /// Rotates clockwise by 90, 180 or 270 degrees.
    func rotated(degrees: Int) -> PixelBuffer {
        switch ((degrees % 360) + 360) % 360 {
        case 90:
            let out = PixelBuffer(width: height, height: width)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    out.storage[x * out.width + (height - 1 - y)] = storage[y * width + x]
                }
            }
            return out
        case 180:
            let out = PixelBuffer(width: width, height: height)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    out.storage[(height - 1 - y) * width + (width - 1 - x)] = storage[y * width + x]
                }
            }
            return out
        case 270:
            let out = PixelBuffer(width: height, height: width)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    out.storage[(width - 1 - x) * out.width + y] = storage[y * width + x]
                }
            }
            return out
        default:
            return copy()
        }
    }

    func inverted() -> PixelBuffer {
        let out = PixelBuffer(width: width, height: height)
        for i in 0 ..< count {
            let p = Pixel(raw: storage[i]).straight
            out.storage[i] = Pixel(r: 255 - p.r, g: 255 - p.g, b: 255 - p.b, a: p.a).premultiplied.raw
        }
        return out
    }

    /// Nearest-neighbour resample — keeps hard pixel edges when you scale a
    /// selection, exactly like Paint's stretch.
    func scaled(toWidth newW: Int, height newH: Int) -> PixelBuffer {
        let w = max(1, newW), h = max(1, newH)
        let out = PixelBuffer(width: w, height: h, fill: .transparent)
        for y in 0 ..< h {
            let sy = min(height - 1, y * height / h)
            for x in 0 ..< w {
                let sx = min(width - 1, x * width / w)
                out.storage[y * w + x] = storage[sy * width + sx]
            }
        }
        return out
    }

    /// Smooth resample, for when quality beats crispness (Image ▸ Stretch).
    func resampled(toWidth newW: Int, height newH: Int) -> PixelBuffer {
        let w = max(1, newW), h = max(1, newH)
        let out = PixelBuffer(width: w, height: h, fill: .transparent)
        guard let image = makeCGImage(), let ctx = out.makeContext() else { return out }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return out
    }

    /// Grows or crops the canvas, anchoring the existing image at the top-left
    /// (Paint's behaviour) and padding with `background`.
    func resizedCanvas(toWidth newW: Int, height newH: Int, background: Pixel) -> PixelBuffer {
        let out = PixelBuffer(width: newW, height: newH, fill: background)
        let copyW = min(width, out.width)
        let copyH = min(height, out.height)
        for y in 0 ..< copyH {
            (out.storage + y * out.width).update(from: storage + y * width, count: copyW)
        }
        return out
    }

    /// Shears the image. `hDegrees` slants rows sideways, `vDegrees` slants
    /// columns vertically; the canvas grows to fit the result.
    func skewed(hDegrees: Double, vDegrees: Double, background: Pixel) -> PixelBuffer {
        let hTan = tan(hDegrees * .pi / 180)
        let vTan = tan(vDegrees * .pi / 180)
        let extraW = Int((Double(height) * abs(hTan)).rounded())
        let extraH = Int((Double(width) * abs(vTan)).rounded())
        let out = PixelBuffer(width: width + extraW, height: height + extraH, fill: background)
        for y in 0 ..< height {
            let dxBase = hTan >= 0 ? Int((Double(height - 1 - y) * hTan).rounded())
                                   : Int((Double(y) * -hTan).rounded())
            for x in 0 ..< width {
                let dyBase = vTan >= 0 ? Int((Double(x) * vTan).rounded())
                                       : Int((Double(width - 1 - x) * -vTan).rounded())
                let nx = x + dxBase
                let ny = y + dyBase
                if nx >= 0, nx < out.width, ny >= 0, ny < out.height {
                    out.storage[ny * out.width + nx] = storage[y * width + x]
                }
            }
        }
        return out
    }
}
