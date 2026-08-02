import Foundation

/// Bridges the geometry in `Raster` to actual pixels, accumulating the rect
/// that was touched so the view can repaint the minimum area.
final class Painter {
    let buffer: PixelBuffer
    private(set) var dirty = PixelRect.zero

    init(_ buffer: PixelBuffer) {
        self.buffer = buffer
    }

    func plot(_ x: Int, _ y: Int, _ color: Pixel) {
        guard buffer.contains(x, y) else { return }
        buffer.blendPixel(x, y, color)
        dirty = dirty.union(PixelRect(x: x, y: y, width: 1, height: 1))
    }

    func span(_ y: Int, _ x0: Int, _ x1: Int, _ color: Pixel) {
        guard y >= 0, y < buffer.height else { return }
        let lo = max(0, x0)
        let hi = min(buffer.width - 1, x1)
        guard hi >= lo else { return }
        if color.a == 255 {
            (buffer.storage + y * buffer.width + lo).update(repeating: color.raw, count: hi - lo + 1)
        } else {
            for x in lo ... hi { buffer.blendPixel(x, y, color) }
        }
        dirty = dirty.union(PixelRect(x: lo, y: y, width: hi - lo + 1, height: 1))
    }

    /// Drags a nib along a line — the way every thick outline is drawn.
    func strokeLine(from a: PixelPoint, to b: PixelPoint, nib: BrushStamp, color: Pixel) {
        dirty = dirty.union(nib.stroke(on: buffer, from: a, to: b, color: color))
    }

    func stamp(_ nib: BrushStamp, at p: PixelPoint, color: Pixel) {
        dirty = dirty.union(nib.apply(to: buffer, at: p, color: color))
    }

    func include(_ rect: PixelRect) {
        dirty = dirty.union(rect)
    }
}
