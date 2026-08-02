import XCTest
@testable import Paint

final class DocumentTests: XCTestCase {

    private var document: PaintDocument!

    override func setUp() {
        super.setUp()
        document = PaintDocument()
        document.resizeCanvas(toWidth: 40, height: 30)
        document.undoManager?.removeAllActions()
    }

    override func tearDown() {
        document = nil
        super.tearDown()
    }

    // MARK: Undo

    func testCommitEditRegistersUndo() throws {
        let undo = try XCTUnwrap(document.undoManager)
        XCTAssertFalse(undo.canUndo)

        document.beginEdit()
        document.image.fill(PixelRect(x: 2, y: 2, width: 5, height: 5), with: .black)
        XCTAssertTrue(document.commitEdit("Test"))

        XCTAssertEqual(document.undoManager?.canUndo, true)
        XCTAssertEqual(document.undoManager?.undoActionName, "Test")
        XCTAssertEqual(document.image.pixel(3, 3), .black)

        document.undoManager?.undo()
        XCTAssertEqual(document.image.pixel(3, 3), .white, "undo restores the original pixels")

        document.undoManager?.redo()
        XCTAssertEqual(document.image.pixel(3, 3), .black, "redo puts them back")
    }

    func testCommitEditWithNoChangesRegistersNothing() {
        document.beginEdit()
        XCTAssertFalse(document.commitEdit("Nothing"))
        XCTAssertEqual(document.undoManager?.canUndo, false)
    }

    /// A whole drag is one snapshot, so it collapses into a single undo step.
    func testRepeatedBeginEditCoalescesIntoOneStep() {
        document.beginEdit()
        document.image.setPixel(1, 1, .black)
        document.beginEdit()
        document.image.setPixel(2, 2, .black)
        document.beginEdit()
        document.image.setPixel(3, 3, .black)
        document.commitEdit("Stroke")

        document.undoManager?.undo()
        XCTAssertEqual(document.image.pixel(1, 1), .white)
        XCTAssertEqual(document.image.pixel(2, 2), .white)
        XCTAssertEqual(document.image.pixel(3, 3), .white)
        XCTAssertEqual(document.undoManager?.canUndo, false, "one drag, one undo")
    }

    func testRevertToSnapshotRollsBackWithoutClosingTheEdit() {
        document.beginEdit()
        let rect = PixelRect(x: 4, y: 4, width: 6, height: 6)
        document.image.fill(rect, with: .black)
        document.revertToSnapshot(rect)
        XCTAssertEqual(document.image.pixel(5, 5), .white)

        // Still inside the same transaction: a second shape commits alone.
        document.image.fill(PixelRect(x: 20, y: 10, width: 3, height: 3), with: .black)
        XCTAssertTrue(document.commitEdit("Shape"))
        document.undoManager?.undo()
        XCTAssertEqual(document.image.pixel(21, 11), .white)
    }

    func testCancelEditDiscardsChanges() {
        document.beginEdit()
        document.image.fill(PixelRect(x: 0, y: 0, width: 10, height: 10), with: .black)
        document.cancelEdit()
        XCTAssertEqual(document.image.pixel(5, 5), .white)
        XCTAssertEqual(document.undoManager?.canUndo, false)
    }

    func testCanvasResizeIsUndoable() {
        document.undoManager?.removeAllActions()
        document.image.setPixel(0, 0, .black)
        document.resizeCanvas(toWidth: 80, height: 60)
        XCTAssertEqual(document.image.width, 80)

        document.undoManager?.undo()
        XCTAssertEqual(document.image.width, 40)
        XCTAssertEqual(document.image.pixel(0, 0), .black, "the pixels come back with the size")
    }

    // MARK: File formats

    func testPNGRoundTripPreservesPixels() throws {
        document.image.fill(PixelRect(x: 1, y: 1, width: 8, height: 6), with: Pixel(r: 12, g: 200, b: 77))
        let data = try document.data(ofType: "public.png")
        XCTAssertFalse(data.isEmpty)

        let reopened = PaintDocument()
        try reopened.read(from: data, ofType: "public.png")
        XCTAssertEqual(reopened.image.width, 40)
        XCTAssertEqual(reopened.image.height, 30)
        XCTAssertEqual(reopened.image.pixel(2, 2), Pixel(r: 12, g: 200, b: 77))
        XCTAssertEqual(reopened.image.pixel(30, 20), .white)
    }

    func testJPEGWritesFlattenedOpaquePixels() throws {
        let data = try document.data(ofType: "public.jpeg")
        XCTAssertFalse(data.isEmpty)
        let reopened = PaintDocument()
        try reopened.read(from: data, ofType: "public.jpeg")
        XCTAssertEqual(reopened.image.pixel(5, 5)?.a, 255)
    }

    func testUnreadableDataThrows() {
        let reopened = PaintDocument()
        XCTAssertThrowsError(try reopened.read(from: Data("not an image".utf8), ofType: "public.png"))
    }

    func testTransparencySurvivesPNG() throws {
        document.image.setPixel(0, 0, .transparent)
        let data = try document.data(ofType: "public.png")
        let reopened = PaintDocument()
        try reopened.read(from: data, ofType: "public.png")
        XCTAssertEqual(reopened.image.pixel(0, 0)?.a, 0)
    }

    // MARK: Selection

    func testSelectionLiftsMovesAndStamps() throws {
        document.image.fill(PixelRect(x: 2, y: 2, width: 4, height: 4), with: .black)
        let settings = PaintSettings.shared
        let savedBackground = settings.background
        settings.background = .white
        defer { settings.background = savedBackground }

        let selection = try XCTUnwrap(
            Selection.rectangular(from: document.image, rect: PixelRect(x: 2, y: 2, width: 4, height: 4))
        )
        document.setSelection(selection)
        XCTAssertNotNil(document.selection)

        // Nothing has moved yet, so the canvas is untouched.
        XCTAssertEqual(document.image.pixel(3, 3), .black)

        document.floatSelectionIfNeeded()
        XCTAssertEqual(document.image.pixel(3, 3), .white, "lifting punches a hole")

        document.selection?.origin = PixelPoint(20, 10)
        document.commitSelection()
        XCTAssertNil(document.selection)
        XCTAssertEqual(document.image.pixel(21, 11), .black, "the pixels landed at the new home")
        XCTAssertEqual(document.image.pixel(3, 3), .white)
    }

    func testMovingASelectionIsOneUndoStep() {
        document.image.fill(PixelRect(x: 2, y: 2, width: 4, height: 4), with: .black)
        document.undoManager?.removeAllActions()

        document.setSelection(Selection.rectangular(from: document.image,
                                                    rect: PixelRect(x: 2, y: 2, width: 4, height: 4)))
        document.floatSelectionIfNeeded()
        document.selection?.origin = PixelPoint(10, 10)
        document.selection?.origin = PixelPoint(20, 12)
        document.commitSelection()

        document.undoManager?.undo()
        XCTAssertEqual(document.image.pixel(3, 3), .black, "the hole is filled back in")
        XCTAssertEqual(document.image.pixel(21, 13), .white, "and the copy is gone")
        XCTAssertEqual(document.undoManager?.canUndo, false)
    }

    func testDeleteSelectionLeavesBackgroundColour() {
        document.image.fill(document.image.bounds, with: .black)
        let settings = PaintSettings.shared
        let savedBackground = settings.background
        settings.background = Pixel(r: 0, g: 0, b: 255)
        defer { settings.background = savedBackground }

        document.setSelection(Selection.rectangular(from: document.image,
                                                    rect: PixelRect(x: 5, y: 5, width: 6, height: 6)))
        document.deleteSelection()
        XCTAssertNil(document.selection)
        XCTAssertEqual(document.image.pixel(7, 7), Pixel(r: 0, g: 0, b: 255))
        XCTAssertEqual(document.image.pixel(4, 4), .black)
    }

    func testSelectAllCoversTheWholeCanvas() {
        document.selectAll()
        XCTAssertEqual(document.selection?.rect, document.image.bounds)
    }

    func testCropToSelectionResizesTheCanvas() {
        document.image.fill(PixelRect(x: 10, y: 6, width: 5, height: 4), with: .black)
        document.setSelection(Selection.rectangular(from: document.image,
                                                    rect: PixelRect(x: 10, y: 6, width: 5, height: 4)))
        document.cropToSelection()
        XCTAssertEqual(document.image.width, 5)
        XCTAssertEqual(document.image.height, 4)
        XCTAssertEqual(document.image.pixel(0, 0), .black)
        XCTAssertNil(document.selection)
    }

    func testFreeFormSelectionKeepsOnlyTheLassoedPixels() throws {
        document.image.fill(document.image.bounds, with: .black)
        let triangle = [PixelPoint(0, 0), PixelPoint(10, 0), PixelPoint(0, 10)]
        let selection = try XCTUnwrap(Selection.freeForm(from: document.image, points: triangle))
        let mask = try XCTUnwrap(selection.mask)

        // Inside the triangle is carried; the far corner is not.
        let width = selection.width
        XCTAssertGreaterThan(width, 0)
        XCTAssertTrue(mask[1 * width + 1])
        XCTAssertFalse(mask[9 * width + 9])
    }

    func testFlattenedImageIncludesAFloatingSelection() {
        document.setSelection(Selection(buffer: PixelBuffer(width: 3, height: 3, fill: .black),
                                        origin: PixelPoint(5, 5), mask: nil, sourceRect: nil))
        let flat = document.flattenedImage()
        XCTAssertEqual(flat.pixel(6, 6), .black)
        XCTAssertEqual(document.image.pixel(6, 6), .white, "the canvas itself is untouched")
    }

    // MARK: Image operations

    func testInvertColours() {
        document.image.fill(document.image.bounds, with: .white)
        document.invertColors()
        XCTAssertEqual(document.image.pixel(1, 1), .black)
        document.undoManager?.undo()
        XCTAssertEqual(document.image.pixel(1, 1), .white)
    }

    func testRotateSwapsDimensions() {
        document.rotate(degrees: 90)
        XCTAssertEqual(document.image.width, 30)
        XCTAssertEqual(document.image.height, 40)
        document.undoManager?.undo()
        XCTAssertEqual(document.image.width, 40)
    }

    func testClearImageUsesTheBackgroundColour() {
        let settings = PaintSettings.shared
        let saved = settings.background
        settings.background = Pixel(r: 9, g: 9, b: 9)
        defer { settings.background = saved }

        document.clearImage()
        XCTAssertEqual(document.image.pixel(0, 0), Pixel(r: 9, g: 9, b: 9))
        document.undoManager?.undo()
        XCTAssertEqual(document.image.pixel(0, 0), .white)
    }

    func testStretchScalesTheCanvas() {
        document.stretch(horizontalPercent: 200, verticalPercent: 50,
                         skewHorizontalDegrees: 0, skewVerticalDegrees: 0)
        XCTAssertEqual(document.image.width, 80)
        XCTAssertEqual(document.image.height, 15)
    }
}
