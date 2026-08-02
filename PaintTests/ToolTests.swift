import AppKit
import XCTest
@testable import Paint

/// Stands in for the canvas so tools can be driven with no window on screen.
final class StubToolHost: ToolHost {
    let document: PaintDocument
    var zoom: CGFloat = 1

    private(set) var invalidatedRects: [PixelRect] = []
    private(set) var zoomInCount = 0
    private(set) var zoomOutCount = 0
    private(set) var textEditRect: PixelRect?
    private(set) var didRequestToolRevert = false

    init(document: PaintDocument) { self.document = document }

    func invalidate(_ rect: PixelRect) { invalidatedRects.append(rect) }
    func invalidateAll() {}
    func invalidateOverlay() {}
    func zoomIn(around point: PixelPoint) { zoomInCount += 1 }
    func zoomOut(around point: PixelPoint) { zoomOutCount += 1 }
    func beginTextEditing(in rect: PixelRect) { textEditRect = rect }
    func toolWantsToRevertToPreviousTool() { didRequestToolRevert = true }
}

final class ToolTests: XCTestCase {

    private var document: PaintDocument!
    private var host: StubToolHost!
    private let settings = PaintSettings.shared

    private var savedTool: ToolKind!
    private var savedForeground: Pixel!
    private var savedBackground: Pixel!
    private var savedPencilSize: Int!
    private var savedLineWidth: Int!
    private var savedShapeStyle: ShapeFillStyle!
    private var savedTransparent: Bool!

    override func setUp() {
        super.setUp()
        // The settings object is a persisted singleton, so put it back the way
        // we found it or these tests would rewrite the user's preferences.
        savedTool = settings.tool
        savedForeground = settings.foreground
        savedBackground = settings.background
        savedPencilSize = settings.pencilSize
        savedLineWidth = settings.lineWidth
        savedShapeStyle = settings.shapeStyle
        savedTransparent = settings.transparentSelection

        settings.foreground = .black
        settings.background = .white
        settings.pencilSize = 1
        settings.lineWidth = 1
        settings.shapeStyle = .outline
        settings.transparentSelection = false

        document = PaintDocument()
        document.resizeCanvas(toWidth: 60, height: 40)
        document.undoManager?.removeAllActions()
        host = StubToolHost(document: document)
    }

    override func tearDown() {
        settings.tool = savedTool
        settings.foreground = savedForeground
        settings.background = savedBackground
        settings.pencilSize = savedPencilSize
        settings.lineWidth = savedLineWidth
        settings.shapeStyle = savedShapeStyle
        settings.transparentSelection = savedTransparent
        document = nil
        host = nil
        super.tearDown()
    }

    private func context(secondary: Bool = false,
                         modifiers: NSEvent.ModifierFlags = []) -> ToolContext {
        ToolContext(host: host, document: document, settings: settings,
                    modifiers: modifiers, isSecondary: secondary)
    }

    private func drag(_ tool: Tool, through points: [PixelPoint],
                      secondary: Bool = false, modifiers: NSEvent.ModifierFlags = []) {
        let ctx = context(secondary: secondary, modifiers: modifiers)
        guard let first = points.first else { return }
        tool.mouseDown(at: first, context: ctx)
        for point in points.dropFirst() { tool.mouseDragged(to: point, context: ctx) }
        tool.mouseUp(at: points.last!, context: ctx)
    }

    private func paintedPixels(_ color: Pixel = .black) -> Int {
        var count = 0
        for y in 0 ..< document.image.height {
            for x in 0 ..< document.image.width where document.image.pixel(x, y) == color {
                count += 1
            }
        }
        return count
    }

    // MARK: Freehand

    func testPencilDrawsAConnectedStroke() {
        settings.tool = .pencil
        drag(PencilTool(), through: [PixelPoint(5, 5), PixelPoint(15, 9), PixelPoint(25, 20)])

        XCTAssertEqual(document.image.pixel(5, 5), .black)
        XCTAssertEqual(document.image.pixel(25, 20), .black)
        // Bresenham lays 11 pixels on the first leg and 12 on the second, and
        // the shared corner is only painted once.
        XCTAssertEqual(paintedPixels(), 22, "the whole path was painted, not just the samples")
        XCTAssertFalse(host.invalidatedRects.isEmpty)
    }

    func testWholeStrokeIsASingleUndo() {
        settings.tool = .pencil
        drag(PencilTool(), through: [PixelPoint(1, 1), PixelPoint(10, 10), PixelPoint(20, 5)])

        XCTAssertEqual(document.undoManager?.canUndo, true)
        document.undoManager?.undo()
        XCTAssertEqual(paintedPixels(), 0, "one undo wipes the entire stroke")
        XCTAssertEqual(document.undoManager?.canUndo, false)
    }

    func testPencilHonoursItsSize() {
        settings.tool = .pencil
        settings.pencilSize = 3
        let tool = PencilTool()
        tool.mouseDown(at: PixelPoint(20, 20), context: context())
        tool.mouseUp(at: PixelPoint(20, 20), context: context())
        XCTAssertEqual(paintedPixels(), 9, "a 3px square nib covers nine pixels")
    }

    func testRightButtonPaintsWithTheBackgroundColour() {
        settings.tool = .pencil
        settings.background = Pixel(r: 255, g: 0, b: 0)
        drag(PencilTool(), through: [PixelPoint(4, 4), PixelPoint(8, 4)], secondary: true)
        XCTAssertEqual(document.image.pixel(6, 4), Pixel(r: 255, g: 0, b: 0))
    }

    func testShiftLocksAFreehandStrokeToAStraightLine() {
        settings.tool = .pencil
        // Wander off-axis; Shift should still leave a clean horizontal run.
        drag(PencilTool(), through: [PixelPoint(5, 20), PixelPoint(15, 24), PixelPoint(25, 21)],
             modifiers: .shift)
        for x in 5 ... 25 {
            XCTAssertEqual(document.image.pixel(x, 20), .black, "x=\(x) should be on the line")
        }
        XCTAssertEqual(paintedPixels(), 21, "and nothing should be left off it")
    }

    func testEraserLaysDownTheBackgroundColour() {
        settings.tool = .eraser
        settings.eraserSize = 4
        settings.background = Pixel(r: 0, g: 128, b: 255)
        document.image.fill(document.image.bounds, with: .black)

        drag(EraserTool(), through: [PixelPoint(10, 10), PixelPoint(20, 10)])
        XCTAssertEqual(document.image.pixel(15, 10), Pixel(r: 0, g: 128, b: 255))
        XCTAssertEqual(document.image.pixel(50, 30), .black)
    }

    func testColourEraserOnlyReplacesTheForegroundColour() {
        settings.tool = .eraser
        settings.eraserSize = 8
        settings.foreground = Pixel(r: 255, g: 0, b: 0)
        settings.background = Pixel(r: 0, g: 255, b: 0)
        document.image.fill(document.image.bounds, with: .black)
        document.image.fill(PixelRect(x: 8, y: 8, width: 6, height: 6), with: Pixel(r: 255, g: 0, b: 0))

        drag(EraserTool(), through: [PixelPoint(11, 11)], secondary: true)
        XCTAssertEqual(document.image.pixel(11, 11), Pixel(r: 0, g: 255, b: 0), "red became green")
        XCTAssertEqual(document.image.pixel(4, 4), .black, "black was left alone")
    }

    func testAirbrushSpraysInsideItsRadius() {
        settings.tool = .airbrush
        settings.airbrushRadius = 6
        settings.airbrushDensity = 40
        let tool = AirbrushTool()
        let ctx = context()
        tool.mouseDown(at: PixelPoint(30, 20), context: ctx)
        for _ in 0 ..< 20 { tool.autorepeat(at: PixelPoint(30, 20), context: ctx) }
        tool.mouseUp(at: PixelPoint(30, 20), context: ctx)

        XCTAssertGreaterThan(paintedPixels(), 20)
        for y in 0 ..< document.image.height {
            for x in 0 ..< document.image.width where document.image.pixel(x, y) == .black {
                let dx = Double(x - 30)
                let dy = Double(y - 20)
                let distance = (dx * dx + dy * dy).squareRoot()
                XCTAssertLessThanOrEqual(distance, 7.5, "dot at \(x),\(y) escaped the disc")
            }
        }
    }

    // MARK: Bucket and pickers

    func testFillToolFloodsABoundedRegion() {
        settings.tool = .fill
        settings.foreground = Pixel(r: 255, g: 0, b: 0)
        for x in 10 ... 30 {
            document.image.setPixel(x, 10, .black)
            document.image.setPixel(x, 25, .black)
        }
        for y in 10 ... 25 {
            document.image.setPixel(10, y, .black)
            document.image.setPixel(30, y, .black)
        }

        FillTool().mouseDown(at: PixelPoint(20, 18), context: context())
        XCTAssertEqual(document.image.pixel(20, 18), Pixel(r: 255, g: 0, b: 0))
        XCTAssertEqual(document.image.pixel(5, 5), .white, "the outside is untouched")

        document.undoManager?.undo()
        XCTAssertEqual(document.image.pixel(20, 18), .white)
    }

    func testEyedropperPicksAndHandsBackControl() {
        settings.tool = .pickColor
        let target = Pixel(r: 33, g: 66, b: 99)
        document.image.setPixel(12, 12, target)

        let tool = PickColorTool()
        tool.mouseDown(at: PixelPoint(12, 12), context: context())
        XCTAssertEqual(settings.foreground, target)

        document.image.setPixel(13, 13, Pixel(r: 1, g: 2, b: 3))
        tool.mouseDown(at: PixelPoint(13, 13), context: context(secondary: true))
        XCTAssertEqual(settings.background, Pixel(r: 1, g: 2, b: 3), "right-click sets the background")

        tool.mouseUp(at: PixelPoint(13, 13), context: context())
        XCTAssertTrue(host.didRequestToolRevert)
    }

    func testMagnifierZoomsBothWays() {
        let tool = MagnifierTool()
        tool.mouseDown(at: PixelPoint(5, 5), context: context())
        XCTAssertEqual(host.zoomInCount, 1)
        tool.mouseDown(at: PixelPoint(5, 5), context: context(secondary: true))
        XCTAssertEqual(host.zoomOutCount, 1)
    }

    // MARK: Shapes

    /// The heart of the shape preview: every drag frame must wipe the previous
    /// attempt, so only the last shape survives.
    func testDraggingAShapeLeavesNoResidue() {
        settings.tool = .line
        let tool = LineTool()
        let ctx = context()
        tool.mouseDown(at: PixelPoint(5, 5), context: ctx)
        tool.mouseDragged(to: PixelPoint(50, 35), context: ctx)
        tool.mouseDragged(to: PixelPoint(50, 5), context: ctx)
        tool.mouseUp(at: PixelPoint(50, 5), context: ctx)

        for x in 5 ... 50 {
            XCTAssertEqual(document.image.pixel(x, 5), .black, "the final line is drawn")
        }
        XCTAssertEqual(document.image.pixel(30, 22), .white, "the discarded diagonal is gone")
        XCTAssertEqual(paintedPixels(), 46)
    }

    func testRectangleOutlineIsHollow() {
        settings.tool = .rectangle
        settings.shapeStyle = .outline
        drag(RectangleTool(), through: [PixelPoint(10, 10), PixelPoint(19, 19)])

        XCTAssertEqual(document.image.pixel(10, 10), .black)
        XCTAssertEqual(document.image.pixel(19, 19), .black)
        XCTAssertEqual(document.image.pixel(14, 14), .white, "the middle stays empty")
        XCTAssertEqual(paintedPixels(), 36, "a 10×10 hollow box is 36 pixels of border")
    }

    func testRectangleFilledUsesBothColours() {
        settings.tool = .rectangle
        settings.shapeStyle = .outlineAndFill
        settings.foreground = .black
        settings.background = Pixel(r: 0, g: 200, b: 0)
        drag(RectangleTool(), through: [PixelPoint(10, 10), PixelPoint(19, 19)])

        XCTAssertEqual(document.image.pixel(10, 10), .black, "outline uses the foreground")
        XCTAssertEqual(document.image.pixel(14, 14), Pixel(r: 0, g: 200, b: 0),
                       "fill uses the background")
    }

    func testEllipseIsRoundNotRectangular() {
        settings.tool = .ellipse
        settings.shapeStyle = .filled
        drag(EllipseTool(), through: [PixelPoint(10, 10), PixelPoint(29, 29)])
        XCTAssertEqual(document.image.pixel(20, 20), .black)
        XCTAssertEqual(document.image.pixel(10, 10), .white, "corners are outside the ellipse")
    }

    func testShiftMakesASquare() {
        settings.tool = .rectangle
        let tool = RectangleTool()
        let ctx = context(modifiers: .shift)
        tool.mouseDown(at: PixelPoint(5, 5), context: ctx)
        tool.mouseDragged(to: PixelPoint(25, 12), context: ctx)
        tool.mouseUp(at: PixelPoint(25, 12), context: ctx)

        XCTAssertEqual(document.image.pixel(25, 25), .black, "the drag was squared off")
        XCTAssertEqual(document.image.pixel(25, 12), .black, "on the right edge")
    }

    func testPolygonClosesAndFills() {
        settings.tool = .polygon
        settings.shapeStyle = .filled
        let tool = PolygonTool()
        let ctx = context()
        for point in [PixelPoint(10, 10), PixelPoint(30, 10), PixelPoint(30, 30)] {
            tool.mouseDown(at: point, context: ctx)
            tool.mouseUp(at: point, context: ctx)
        }
        XCTAssertTrue(tool.isInProgress)
        XCTAssertTrue(tool.doubleClick(at: PixelPoint(30, 30), context: ctx))
        XCTAssertFalse(tool.isInProgress)

        XCTAssertEqual(document.image.pixel(27, 20), .black, "inside the triangle")
        XCTAssertEqual(document.image.pixel(12, 28), .white, "outside it")
        XCTAssertEqual(document.undoManager?.canUndo, true)
    }

    func testEscapeAbandonsAPolygonInProgress() {
        settings.tool = .polygon
        let tool = PolygonTool()
        let ctx = context()
        tool.mouseDown(at: PixelPoint(10, 10), context: ctx)
        tool.mouseUp(at: PixelPoint(10, 10), context: ctx)
        tool.mouseDown(at: PixelPoint(30, 10), context: ctx)
        tool.mouseUp(at: PixelPoint(30, 10), context: ctx)
        XCTAssertGreaterThan(paintedPixels(), 0)

        tool.cancel(context: ctx)
        XCTAssertEqual(paintedPixels(), 0, "the canvas is back to how it was")
        XCTAssertEqual(document.undoManager?.canUndo, false, "and nothing hit the undo stack")
    }

    func testCurveBendsAfterTheInitialLine() {
        settings.tool = .curve
        let tool = CurveTool()
        let ctx = context()
        tool.mouseDown(at: PixelPoint(5, 20), context: ctx)
        tool.mouseDragged(to: PixelPoint(55, 20), context: ctx)
        tool.mouseUp(at: PixelPoint(55, 20), context: ctx)
        XCTAssertTrue(tool.isInProgress, "the curve waits for its bends")

        let straightCount = paintedPixels()
        tool.mouseDown(at: PixelPoint(30, 4), context: ctx)
        tool.mouseDragged(to: PixelPoint(30, 4), context: ctx)
        tool.mouseUp(at: PixelPoint(30, 4), context: ctx)

        XCTAssertGreaterThan(paintedPixels(), straightCount, "bending lengthens the stroke")
        XCTAssertEqual(document.image.pixel(30, 20), .white, "the middle lifted off the baseline")

        tool.finish(context: ctx)
        XCTAssertFalse(tool.isInProgress)
        XCTAssertEqual(document.undoManager?.canUndo, true)
    }

    // MARK: Selection and text

    func testRectangleSelectCreatesASelection() {
        settings.tool = .rectangleSelect
        document.image.fill(PixelRect(x: 5, y: 5, width: 10, height: 10), with: .black)
        drag(RectangleSelectTool(), through: [PixelPoint(5, 5), PixelPoint(10, 10), PixelPoint(14, 14)])

        let selection = document.selection
        XCTAssertNotNil(selection)
        XCTAssertEqual(selection?.rect, PixelRect(x: 5, y: 5, width: 10, height: 10))
        XCTAssertEqual(selection?.isFloating, false, "a fresh marquee has not lifted anything yet")
    }

    func testDraggingInsideASelectionMovesIt() {
        settings.tool = .rectangleSelect
        document.image.fill(PixelRect(x: 5, y: 5, width: 10, height: 10), with: .black)
        let tool = RectangleSelectTool()
        drag(tool, through: [PixelPoint(5, 5), PixelPoint(14, 14)])
        XCTAssertNotNil(document.selection)

        drag(tool, through: [PixelPoint(10, 10), PixelPoint(30, 20)])
        XCTAssertEqual(document.selection?.origin, PixelPoint(25, 15))
        XCTAssertEqual(document.selection?.isFloating, true)
        XCTAssertEqual(document.image.pixel(7, 7), .white, "the original spot was cleared")
    }

    func testFreeFormSelectBuildsAMask() {
        settings.tool = .freeFormSelect
        document.image.fill(document.image.bounds, with: .black)
        drag(FreeFormSelectTool(), through: [
            PixelPoint(5, 5), PixelPoint(25, 5), PixelPoint(25, 25), PixelPoint(5, 25),
        ])
        XCTAssertNotNil(document.selection)
        XCTAssertNotNil(document.selection?.mask)
        XCTAssertEqual(document.selection?.rect.width, 21)
    }

    func testTextToolHandsARectToTheHost() {
        settings.tool = .text
        drag(TextTool(), through: [PixelPoint(5, 5), PixelPoint(45, 25)])
        XCTAssertEqual(host.textEditRect, PixelRect(x: 5, y: 5, width: 41, height: 21))
    }

    func testTextToolClickGetsADefaultBox() throws {
        settings.tool = .text
        drag(TextTool(), through: [PixelPoint(2, 2)])
        let rect = try XCTUnwrap(host.textEditRect)
        XCTAssertGreaterThan(rect.width, 8)
        XCTAssertGreaterThan(rect.height, 8)
    }
}
