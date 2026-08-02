import Foundation

/// Paint's bucket: a 4-connected flood fill.
///
/// Four-connected is the authentic choice — it is why a bucket can escape
/// through the diagonal gap in a 1px Bresenham line in the real thing too.
enum FloodFill {

    /// Fills the contiguous region around `start`.
    /// - Parameter tolerance: 0 matches the seed colour exactly (classic Paint);
    ///   higher values widen the match per channel, up to 255.
    /// - Returns: the rect that changed, or `.zero` if nothing did.
    @discardableResult
    static func fill(_ buffer: PixelBuffer, from start: PixelPoint, with newColor: Pixel,
                     tolerance: Int = 0) -> PixelRect {
        guard buffer.contains(start.x, start.y) else { return .zero }
        let target = Pixel(raw: buffer.storage[buffer.index(start.x, start.y)])
        if target.raw == newColor.raw { return .zero }

        let width = buffer.width
        let height = buffer.height
        let tol = max(0, min(255, tolerance))

        // A visited bitmap guarantees termination even when the replacement
        // colour itself falls inside the tolerance window of the seed.
        var visited = [Bool](repeating: false, count: width * height)
        var dirty = PixelRect.zero

        return visited.withUnsafeMutableBufferPointer { seen -> PixelRect in
            @inline(__always)
            func matches(_ x: Int, _ y: Int) -> Bool {
                let i = y * width + x
                if seen[i] { return false }
                let p = Pixel(raw: buffer.storage[i])
                if tol == 0 { return p.raw == target.raw }
                return p.distance(to: target) <= tol
            }

            var stack: [PixelPoint] = [start]
            stack.reserveCapacity(64)

            while let seed = stack.popLast() {
                let y = seed.y
                guard matches(seed.x, y) else { continue }

                // Grow the run left and right from the seed.
                var x0 = seed.x
                while x0 - 1 >= 0, matches(x0 - 1, y) { x0 -= 1 }
                var x1 = seed.x
                while x1 + 1 < width, matches(x1 + 1, y) { x1 += 1 }

                let rowBase = y * width
                for x in x0 ... x1 { seen[rowBase + x] = true }
                (buffer.storage + rowBase + x0).update(repeating: newColor.raw, count: x1 - x0 + 1)
                dirty = dirty.union(PixelRect(x: x0, y: y, width: x1 - x0 + 1, height: 1))

                // Seed one point per unbroken run on the rows above and below.
                for ny in [y - 1, y + 1] where ny >= 0 && ny < height {
                    var x = x0
                    while x <= x1 {
                        if matches(x, ny) {
                            stack.append(PixelPoint(x, ny))
                            while x <= x1, matches(x, ny) { x += 1 }
                        } else {
                            x += 1
                        }
                    }
                }
            }
            return dirty
        }
    }

    /// Swaps one colour for another everywhere inside `region` — the engine
    /// behind Paint's colour eraser (right-drag with the eraser).
    @discardableResult
    static func replaceColor(_ buffer: PixelBuffer, in region: PixelRect, from oldColor: Pixel,
                             to newColor: Pixel, tolerance: Int = 0) -> PixelRect {
        let r = region.intersection(buffer.bounds)
        guard !r.isEmpty else { return .zero }
        var dirty = PixelRect.zero
        for y in r.y ..< r.maxY {
            for x in r.x ..< r.maxX {
                let i = y * buffer.width + x
                let p = Pixel(raw: buffer.storage[i])
                let hit = tolerance == 0 ? p.raw == oldColor.raw : p.distance(to: oldColor) <= tolerance
                guard hit else { continue }
                buffer.storage[i] = newColor.raw
                dirty = dirty.union(PixelRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return dirty
    }
}
