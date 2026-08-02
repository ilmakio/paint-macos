import XCTest
@testable import Paint

final class PixelBufferTests: XCTestCase {

    func testFillAndRead() {
        let buffer = PixelBuffer(width: 4, height: 3, fill: .white)
        XCTAssertEqual(buffer.pixel(0, 0), .white)
        XCTAssertEqual(buffer.pixel(3, 2), .white)
        XCTAssertNil(buffer.pixel(4, 0))
        XCTAssertNil(buffer.pixel(-1, 0))

        buffer.setPixel(2, 1, .black)
        XCTAssertEqual(buffer.pixel(2, 1), .black)
        XCTAssertEqual(buffer.pixel(1, 1), .white)
    }

    /// Guards the channel packing: an out-of-order byte layout would survive a
    /// round trip through our own code but silently corrupt every saved file.
    func testCGImageRoundTripPreservesChannels() throws {
        let buffer = PixelBuffer(width: 3, height: 2, fill: .white)
        let red = Pixel(r: 220, g: 30, b: 40)
        let green = Pixel(r: 20, g: 190, b: 60)
        let blue = Pixel(r: 15, g: 25, b: 200)
        buffer.setPixel(0, 0, red)
        buffer.setPixel(1, 0, green)
        buffer.setPixel(2, 1, blue)

        let image = try XCTUnwrap(buffer.makeCGImage())
        let restored = try XCTUnwrap(PixelBuffer(cgImage: image))

        XCTAssertEqual(restored.width, 3)
        XCTAssertEqual(restored.height, 2)
        XCTAssertEqual(restored.pixel(0, 0), red)
        XCTAssertEqual(restored.pixel(1, 0), green)
        XCTAssertEqual(restored.pixel(2, 1), blue)
    }

    func testSnapshotRestoreRoundTrip() {
        let buffer = PixelBuffer(width: 8, height: 8, fill: .white)
        let rect = PixelRect(x: 2, y: 3, width: 4, height: 2)
        let before = buffer.snapshot(rect)

        buffer.fill(rect, with: .black)
        XCTAssertEqual(buffer.pixel(2, 3), .black)
        XCTAssertEqual(buffer.pixel(1, 3), .white, "fill must not bleed outside the rect")

        buffer.restore(rect, from: before)
        for y in 0 ..< 8 {
            for x in 0 ..< 8 {
                XCTAssertEqual(buffer.pixel(x, y), .white)
            }
        }
    }

    func testFlipIsItsOwnInverse() {
        let buffer = PixelBuffer(width: 5, height: 4, fill: .white)
        buffer.setPixel(0, 0, .black)
        buffer.setPixel(4, 3, Pixel(r: 1, g: 2, b: 3))

        let flippedTwice = buffer.flippedHorizontally().flippedHorizontally()
        XCTAssertEqual(flippedTwice.pixel(0, 0), .black)
        XCTAssertEqual(flippedTwice.pixel(4, 3), Pixel(r: 1, g: 2, b: 3))

        let horizontal = buffer.flippedHorizontally()
        XCTAssertEqual(horizontal.pixel(4, 0), .black)

        let vertical = buffer.flippedVertically()
        XCTAssertEqual(vertical.pixel(0, 3), .black)
    }

    func testRotationsComposeToIdentity() {
        let buffer = PixelBuffer(width: 6, height: 3, fill: .white)
        buffer.setPixel(1, 0, .black)

        let quarter = buffer.rotated(degrees: 90)
        XCTAssertEqual(quarter.width, 3)
        XCTAssertEqual(quarter.height, 6)
        // Top-left of a clockwise turn comes from the bottom-left.
        XCTAssertEqual(quarter.pixel(2, 1), .black)

        let full = buffer.rotated(degrees: 90).rotated(degrees: 90)
            .rotated(degrees: 90).rotated(degrees: 90)
        XCTAssertEqual(full.width, 6)
        XCTAssertEqual(full.height, 3)
        XCTAssertEqual(full.pixel(1, 0), .black)
    }

    func testInvertIsItsOwnInverse() {
        let buffer = PixelBuffer(width: 3, height: 1, fill: .white)
        buffer.setPixel(1, 0, Pixel(r: 10, g: 128, b: 250))
        let twice = buffer.inverted().inverted()
        XCTAssertEqual(twice.pixel(0, 0), .white)
        XCTAssertEqual(twice.pixel(1, 0), Pixel(r: 10, g: 128, b: 250))
        XCTAssertEqual(buffer.inverted().pixel(0, 0), .black)
    }

    func testResizeCanvasAnchorsTopLeft() {
        let buffer = PixelBuffer(width: 4, height: 4, fill: .black)
        let grown = buffer.resizedCanvas(toWidth: 6, height: 5, background: .white)
        XCTAssertEqual(grown.pixel(0, 0), .black)
        XCTAssertEqual(grown.pixel(3, 3), .black)
        XCTAssertEqual(grown.pixel(4, 0), .white, "new space uses the background colour")
        XCTAssertEqual(grown.pixel(0, 4), .white)

        let shrunk = buffer.resizedCanvas(toWidth: 2, height: 2, background: .white)
        XCTAssertEqual(shrunk.width, 2)
        XCTAssertEqual(shrunk.pixel(1, 1), .black)
    }

    func testNearestNeighbourScaleKeepsHardEdges() {
        let buffer = PixelBuffer(width: 2, height: 1, fill: .white)
        buffer.setPixel(1, 0, .black)
        let doubled = buffer.scaled(toWidth: 4, height: 2)
        XCTAssertEqual(doubled.pixel(0, 0), .white)
        XCTAssertEqual(doubled.pixel(1, 0), .white)
        XCTAssertEqual(doubled.pixel(2, 0), .black)
        XCTAssertEqual(doubled.pixel(3, 1), .black, "no interpolated in-between shades")
    }
}

final class PixelRectTests: XCTestCase {

    func testBoundingIncludesBothCorners() {
        let rect = PixelRect.bounding(PixelPoint(5, 9), PixelPoint(2, 3))
        XCTAssertEqual(rect, PixelRect(x: 2, y: 3, width: 4, height: 7))
        XCTAssertTrue(rect.contains(PixelPoint(5, 9)))
        XCTAssertTrue(rect.contains(PixelPoint(2, 3)))
        XCTAssertFalse(rect.contains(PixelPoint(6, 9)))
    }

    func testIntersectionAndUnion() {
        let a = PixelRect(x: 0, y: 0, width: 4, height: 4)
        let b = PixelRect(x: 2, y: 2, width: 4, height: 4)
        XCTAssertEqual(a.intersection(b), PixelRect(x: 2, y: 2, width: 2, height: 2))
        XCTAssertEqual(a.union(b), PixelRect(x: 0, y: 0, width: 6, height: 6))
        XCTAssertTrue(a.intersection(PixelRect(x: 9, y: 9, width: 1, height: 1)).isEmpty)
        XCTAssertEqual(PixelRect.zero.union(b), b, "empty unions vanish")
    }
}

final class RasterTests: XCTestCase {

    func testLineHitsBothEndpoints() {
        var points: [PixelPoint] = []
        Raster.line(from: PixelPoint(1, 2), to: PixelPoint(9, 7)) { points.append(PixelPoint($0, $1)) }
        XCTAssertEqual(points.first, PixelPoint(1, 2))
        XCTAssertEqual(points.last, PixelPoint(9, 7))
    }

    func testLineIsEightConnected() {
        var points: [PixelPoint] = []
        Raster.line(from: PixelPoint(0, 0), to: PixelPoint(23, 9)) { points.append(PixelPoint($0, $1)) }
        for i in 1 ..< points.count {
            let dx = abs(points[i].x - points[i - 1].x)
            let dy = abs(points[i].y - points[i - 1].y)
            XCTAssertLessThanOrEqual(max(dx, dy), 1, "step \(i) jumped from \(points[i - 1]) to \(points[i])")
        }
    }

    func testSinglePointLine() {
        var count = 0
        Raster.line(from: PixelPoint(4, 4), to: PixelPoint(4, 4)) { _, _ in count += 1 }
        XCTAssertEqual(count, 1)
    }

    /// The bucket is 4-connected, so a shape outline has to be too — otherwise
    /// filling outside an ellipse would leak into it through a diagonal seam.
    func testEllipseOutlineContainsFloodFill() {
        let buffer = PixelBuffer(width: 60, height: 40, fill: .white)
        let rect = PixelRect(x: 5, y: 4, width: 48, height: 30)
        Raster.ellipseOutline(in: rect, thickness: 1) { y, x0, x1 in
            for x in x0 ... x1 { buffer.setPixel(x, y, .black) }
        }
        let filled = FloodFill.fill(buffer, from: PixelPoint(0, 0), with: Pixel(r: 255, g: 0, b: 0))
        XCTAssertFalse(filled.isEmpty)
        XCTAssertEqual(buffer.pixel(29, 19), .white, "the ellipse interior must stay sealed")
        XCTAssertEqual(buffer.pixel(0, 0), Pixel(r: 255, g: 0, b: 0))
    }

    func testRoundedRectangleOutlineContainsFloodFill() {
        let buffer = PixelBuffer(width: 50, height: 40, fill: .white)
        let rect = PixelRect(x: 4, y: 4, width: 40, height: 30)
        Raster.roundedRectangleOutline(in: rect, radius: 8, thickness: 1) { y, x0, x1 in
            for x in x0 ... x1 { buffer.setPixel(x, y, .black) }
        }
        FloodFill.fill(buffer, from: PixelPoint(0, 0), with: Pixel(r: 0, g: 0, b: 255))
        XCTAssertEqual(buffer.pixel(24, 19), .white)
    }

    func testEllipseFillCoversCentreAndSkipsCorners() {
        let buffer = PixelBuffer(width: 20, height: 20, fill: .white)
        let rect = PixelRect(x: 0, y: 0, width: 20, height: 20)
        Raster.ellipseFill(in: rect) { y, x0, x1 in
            for x in x0 ... x1 { buffer.setPixel(x, y, .black) }
        }
        XCTAssertEqual(buffer.pixel(10, 10), .black)
        XCTAssertEqual(buffer.pixel(0, 0), .white, "corners fall outside an inscribed ellipse")
        XCTAssertEqual(buffer.pixel(19, 19), .white)
    }

    func testRectangleOutlineRespectsThickness() {
        let buffer = PixelBuffer(width: 12, height: 12, fill: .white)
        let rect = PixelRect(x: 1, y: 1, width: 10, height: 10)
        Raster.rectangleOutline(rect, thickness: 2) { y, x0, x1 in
            for x in x0 ... x1 { buffer.setPixel(x, y, .black) }
        }
        XCTAssertEqual(buffer.pixel(1, 1), .black)
        XCTAssertEqual(buffer.pixel(2, 2), .black, "second ring is part of a 2px border")
        XCTAssertEqual(buffer.pixel(3, 3), .white, "third ring is interior")
        XCTAssertEqual(buffer.pixel(10, 10), .black)
    }

    func testPolygonFillOfSquare() {
        let buffer = PixelBuffer(width: 12, height: 12, fill: .white)
        let square = [PixelPoint(2, 2), PixelPoint(9, 2), PixelPoint(9, 9), PixelPoint(2, 9)]
        Raster.polygonFill(square) { y, x0, x1 in
            for x in x0 ... x1 { buffer.setPixel(x, y, .black) }
        }
        // Count distinct pixels: the boundary pass deliberately overlaps the
        // interior, so the number of span writes is higher than the coverage.
        var painted = 0
        for y in 0 ..< 12 {
            for x in 0 ..< 12 where buffer.pixel(x, y) == .black { painted += 1 }
        }
        XCTAssertEqual(painted, 64, "an 8×8 square of pixels")
        XCTAssertEqual(buffer.pixel(2, 2), .black)
        XCTAssertEqual(buffer.pixel(9, 9), .black)
        XCTAssertEqual(buffer.pixel(1, 2), .white)
    }

    func testShiftConstraints() {
        let anchor = PixelPoint(10, 10)
        XCTAssertEqual(Raster.constrainToSquare(from: anchor, to: PixelPoint(30, 15)),
                       PixelPoint(30, 30))
        XCTAssertEqual(Raster.constrainToSquare(from: anchor, to: PixelPoint(0, 8)),
                       PixelPoint(0, 0))
        // 10° off horizontal snaps flat.
        let snapped = Raster.constrainToAngle(from: anchor, to: PixelPoint(60, 13))
        XCTAssertEqual(snapped.y, 10)
    }

    func testBezierStartsAndEndsOnItsAnchors() {
        var points: [PixelPoint] = []
        Raster.cubicBezier(PixelPoint(0, 0), PixelPoint(10, 30), PixelPoint(30, -10),
                           PixelPoint(40, 20)) { points.append(PixelPoint($0, $1)) }
        XCTAssertEqual(points.first, PixelPoint(0, 0))
        XCTAssertEqual(points.last, PixelPoint(40, 20))
    }
}

final class FloodFillTests: XCTestCase {

    func testFillStopsAtBorder() {
        let buffer = PixelBuffer(width: 20, height: 20, fill: .white)
        // A closed 1px box from (5,5) to (14,14).
        for x in 5 ... 14 {
            buffer.setPixel(x, 5, .black)
            buffer.setPixel(x, 14, .black)
        }
        for y in 5 ... 14 {
            buffer.setPixel(5, y, .black)
            buffer.setPixel(14, y, .black)
        }

        let red = Pixel(r: 255, g: 0, b: 0)
        let dirty = FloodFill.fill(buffer, from: PixelPoint(10, 10), with: red)

        XCTAssertEqual(dirty, PixelRect(x: 6, y: 6, width: 8, height: 8))
        XCTAssertEqual(buffer.pixel(10, 10), red)
        XCTAssertEqual(buffer.pixel(6, 6), red)
        XCTAssertEqual(buffer.pixel(5, 5), .black, "the border is untouched")
        XCTAssertEqual(buffer.pixel(0, 0), .white, "the outside is untouched")
    }

    func testFillIsANoOpWhenColoursMatch() {
        let buffer = PixelBuffer(width: 5, height: 5, fill: .white)
        XCTAssertTrue(FloodFill.fill(buffer, from: PixelPoint(2, 2), with: .white).isEmpty)
    }

    func testFillOutsideBoundsIsIgnored() {
        let buffer = PixelBuffer(width: 5, height: 5, fill: .white)
        XCTAssertTrue(FloodFill.fill(buffer, from: PixelPoint(99, 1), with: .black).isEmpty)
    }

    /// With tolerance, the replacement colour can itself match the seed. The
    /// visited bitmap is what stops that becoming an infinite loop.
    func testTolerantFillTerminates() {
        let buffer = PixelBuffer(width: 30, height: 30, fill: Pixel(r: 200, g: 200, b: 200))
        let nearlyTheSame = Pixel(r: 205, g: 205, b: 205)
        let dirty = FloodFill.fill(buffer, from: PixelPoint(0, 0), with: nearlyTheSame, tolerance: 40)
        XCTAssertEqual(dirty, buffer.bounds)
        XCTAssertEqual(buffer.pixel(29, 29), nearlyTheSame)
    }

    func testToleranceWidensTheMatch() {
        let buffer = PixelBuffer(width: 4, height: 1, fill: Pixel(r: 100, g: 100, b: 100))
        buffer.setPixel(2, 0, Pixel(r: 120, g: 100, b: 100))
        let red = Pixel(r: 255, g: 0, b: 0)

        FloodFill.fill(buffer, from: PixelPoint(0, 0), with: red, tolerance: 5)
        XCTAssertEqual(buffer.pixel(1, 0), red)
        XCTAssertNotEqual(buffer.pixel(3, 0), red, "the off-shade pixel blocks a strict fill")

        let blue = Pixel(r: 0, g: 0, b: 255)
        FloodFill.fill(buffer, from: PixelPoint(3, 0), with: blue, tolerance: 40)
        XCTAssertEqual(buffer.pixel(2, 0), blue, "a wider tolerance walks straight through")
    }

    func testReplaceColorOnlyTouchesTheTarget() {
        let buffer = PixelBuffer(width: 4, height: 2, fill: .white)
        buffer.setPixel(1, 0, .black)
        buffer.setPixel(3, 1, .black)
        let region = PixelRect(x: 0, y: 0, width: 3, height: 2)
        let green = Pixel(r: 0, g: 255, b: 0)

        FloodFill.replaceColor(buffer, in: region, from: .black, to: green)
        XCTAssertEqual(buffer.pixel(1, 0), green)
        XCTAssertEqual(buffer.pixel(3, 1), .black, "outside the region stays put")
        XCTAssertEqual(buffer.pixel(0, 0), .white)
    }
}

final class BrushStampTests: XCTestCase {

    func testSinglePixelNib() {
        let stamp = BrushStamp.make(shape: .square, size: 1)
        let buffer = PixelBuffer(width: 5, height: 5, fill: .white)
        let dirty = stamp.apply(to: buffer, at: PixelPoint(2, 2), color: .black)
        XCTAssertEqual(dirty, PixelRect(x: 2, y: 2, width: 1, height: 1))
        XCTAssertEqual(buffer.pixel(2, 2), .black)
        XCTAssertEqual(buffer.pixel(1, 2), .white)
    }

    func testRoundNibIsSymmetricForOddSizes() {
        let stamp = BrushStamp.make(shape: .round, size: 5)
        XCTAssertEqual(stamp.bounds.width, 5)
        XCTAssertEqual(stamp.bounds.height, 5)
        XCTAssertEqual(stamp.bounds.x, -2)
        XCTAssertEqual(stamp.bounds.y, -2)
    }

    func testStrokeIsContinuous() {
        let buffer = PixelBuffer(width: 40, height: 40, fill: .white)
        let stamp = BrushStamp.make(shape: .square, size: 1)
        stamp.stroke(on: buffer, from: PixelPoint(2, 2), to: PixelPoint(30, 20), color: .black)

        // Every painted row must be reachable from the one above it.
        var previousRowXs: [Int] = []
        for y in 0 ..< 40 {
            let xs = (0 ..< 40).filter { buffer.pixel($0, y) == .black }
            if !xs.isEmpty, !previousRowXs.isEmpty {
                let gap = xs.map { x in previousRowXs.map { abs($0 - x) }.min()! }.min()!
                XCTAssertLessThanOrEqual(gap, 1, "row \(y) is disconnected from the previous one")
            }
            if !xs.isEmpty { previousRowXs = xs }
        }
        XCTAssertEqual(buffer.pixel(2, 2), .black)
        XCTAssertEqual(buffer.pixel(30, 20), .black)
    }

    func testCoverageMatchesWhatGetsPainted() {
        let stamp = BrushStamp.make(shape: .round, size: 9)
        let buffer = PixelBuffer(width: 40, height: 40, fill: .white)
        let claimed = stamp.coverage(at: PixelPoint(20, 20))
        let actual = stamp.apply(to: buffer, at: PixelPoint(20, 20), color: .black)
        XCTAssertEqual(claimed, actual)
    }
}
