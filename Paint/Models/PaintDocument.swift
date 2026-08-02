import AppKit
import UniformTypeIdentifiers

protocol PaintDocumentObserver: AnyObject {
    func paintDocument(_ document: PaintDocument, didChangeImageIn rect: PixelRect)
    func paintDocumentDidChangeSelection(_ document: PaintDocument)
    func paintDocumentDidChangeCanvasSize(_ document: PaintDocument)
}

extension PaintDocumentObserver {
    func paintDocument(_ document: PaintDocument, didChangeImageIn rect: PixelRect) {}
    func paintDocumentDidChangeSelection(_ document: PaintDocument) {}
    func paintDocumentDidChangeCanvasSize(_ document: PaintDocument) {}
}

enum PaintError: LocalizedError {
    case unreadableImage
    case unwritableImage

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "That file isn’t an image Paint can open."
        case .unwritableImage: return "Paint couldn’t encode the image in that format."
        }
    }
}

/// The document: one raster image, its floating selection, and the undo stack
/// that ties them together.
final class PaintDocument: NSDocument {

    static let defaultSize = PixelRect(x: 0, y: 0, width: 800, height: 600)

    private(set) var image: PixelBuffer
    private(set) var selection: Selection?

    /// Full-canvas copy taken when an edit begins; diffed at commit time so the
    /// undo stack only stores the rectangle that actually moved.
    private var editSnapshot: PixelBuffer?

    // MARK: Init

    override init() {
        image = PixelBuffer(width: PaintDocument.defaultSize.width,
                            height: PaintDocument.defaultSize.height,
                            fill: .white)
        super.init()
        hasUndoManager = true
    }

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(PaintWindowController())
    }

    // MARK: - Observers

    private struct WeakObserver {
        weak var value: PaintDocumentObserver?
    }

    private var observers: [WeakObserver] = []

    func addObserver(_ observer: PaintDocumentObserver) {
        observers.removeAll { $0.value == nil }
        guard !observers.contains(where: { $0.value === observer }) else { return }
        observers.append(WeakObserver(value: observer))
    }

    func removeObserver(_ observer: PaintDocumentObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
    }

    func notifyImageChanged(_ rect: PixelRect) {
        guard !rect.isEmpty else { return }
        for o in observers { o.value?.paintDocument(self, didChangeImageIn: rect) }
    }

    func notifySelectionChanged() {
        for o in observers { o.value?.paintDocumentDidChangeSelection(self) }
    }

    private func notifyCanvasSizeChanged() {
        for o in observers { o.value?.paintDocumentDidChangeCanvasSize(self) }
    }

    // MARK: - Undo

    /// Opens an edit transaction. Calling it again while one is open is a no-op,
    /// so a whole drag — or an entire selection move — collapses to one undo.
    func beginEdit() {
        if editSnapshot == nil {
            editSnapshot = image.copy()
        }
    }

    /// Closes the transaction and pushes it onto the undo stack.
    /// - Returns: true when pixels actually changed.
    @discardableResult
    func commitEdit(_ actionName: String) -> Bool {
        guard let before = editSnapshot else { return false }
        editSnapshot = nil
        guard before.width == image.width, before.height == image.height,
              let rect = PaintDocument.diffRect(before, image)
        else { return false }
        pushUndo(actionName: actionName,
                 rect: rect,
                 before: before.snapshot(rect),
                 after: image.snapshot(rect))
        return true
    }

    /// Throws away an in-progress transaction, restoring the pixels.
    func cancelEdit() {
        guard let before = editSnapshot else { return }
        editSnapshot = nil
        guard before.width == image.width, before.height == image.height else { return }
        let rect = PaintDocument.diffRect(before, image) ?? image.bounds
        image.restore(rect, from: before.snapshot(rect))
        notifyImageChanged(rect)
    }

    var hasOpenEdit: Bool { editSnapshot != nil }

    /// Rolls a rectangle back to how it looked when `beginEdit()` ran, without
    /// closing the transaction.
    ///
    /// This is what makes shape previews pixel-exact: while you drag, the tool
    /// wipes its last attempt and rasterises the new one straight into the
    /// canvas, so the preview *is* the result rather than an approximation of it.
    func revertToSnapshot(_ rect: PixelRect) {
        guard let snapshot = editSnapshot,
              snapshot.width == image.width, snapshot.height == image.height
        else { return }
        let r = rect.intersection(image.bounds)
        guard !r.isEmpty else { return }
        image.restore(r, from: snapshot.snapshot(r))
    }

    private func pushUndo(actionName: String, rect: PixelRect, before: [UInt32], after: [UInt32]) {
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { document in
            document.image.restore(rect, from: before)
            // Register the mirror image so redo walks back the other way.
            document.pushUndo(actionName: actionName, rect: rect, before: after, after: before)
            document.notifyImageChanged(rect)
        }
    }

    /// Swaps in a whole new raster — used when the canvas changes size or the
    /// entire image is transformed.
    func replaceImage(with newImage: PixelBuffer, actionName: String) {
        cancelPendingSnapshotForStructuralChange()
        let old = image
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { document in
            document.replaceImage(with: old, actionName: actionName)
        }
        image = newImage
        notifyCanvasSizeChanged()
    }

    /// A structural change invalidates any half-open pixel transaction, since
    /// the diff at commit time would compare buffers of different sizes.
    private func cancelPendingSnapshotForStructuralChange() {
        editSnapshot = nil
    }

    /// Bounding box of the pixels that differ between two same-sized buffers.
    private static func diffRect(_ a: PixelBuffer, _ b: PixelBuffer) -> PixelRect? {
        guard a.width == b.width, a.height == b.height else { return nil }
        let w = a.width, h = a.height
        let rowBytes = w * MemoryLayout<UInt32>.stride

        var minY = -1
        var maxY = -1
        for y in 0 ..< h where memcmp(a.storage + y * w, b.storage + y * w, rowBytes) != 0 {
            if minY < 0 { minY = y }
            maxY = y
        }
        guard minY >= 0 else { return nil }

        var minX = w
        var maxX = -1
        for y in minY ... maxY {
            let ra = a.storage + y * w
            let rb = b.storage + y * w
            var x = 0
            while x < minX {
                if ra[x] != rb[x] { minX = x; break }
                x += 1
            }
            var xe = w - 1
            while xe > maxX {
                if ra[xe] != rb[xe] { maxX = xe; break }
                xe -= 1
            }
        }
        guard maxX >= minX else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - Selection lifecycle

    /// Installs a new selection, stamping down whatever was floating before.
    func setSelection(_ newSelection: Selection?) {
        if selection !== newSelection { commitSelection() }
        selection = newSelection
        notifySelectionChanged()
    }

    /// Cuts the selection loose from the canvas, filling the hole it leaves
    /// with the background colour. Safe to call repeatedly.
    func floatSelectionIfNeeded() {
        guard let selection, !selection.isFloating else { return }
        selection.isFloating = true
        guard let source = selection.sourceRect else { return }
        beginEdit()
        if let mask = selection.mask {
            let bg = PaintSettings.shared.background
            for y in 0 ..< source.height {
                for x in 0 ..< source.width where mask[y * source.width + x] {
                    image.setPixel(source.x + x, source.y + y, bg)
                }
            }
        } else {
            image.fill(source, with: PaintSettings.shared.background)
        }
        notifyImageChanged(source)
    }

    /// Stamps the floating selection back onto the canvas and clears it.
    func commitSelection() {
        guard let selection else { return }
        self.selection = nil
        let wasFloating = selection.isFloating || selection.sourceRect == nil
        if wasFloating {
            beginEdit()
            let transparent = PaintSettings.shared.transparentSelection
                ? PaintSettings.shared.background : nil
            selection.composite(onto: image, transparentColor: transparent)
            notifyImageChanged(selection.rect)
            commitEdit("Selection")
        } else {
            // A marquee that was never moved changed nothing.
            commitEdit("Selection")
        }
        notifySelectionChanged()
    }

    /// Drops the selection without stamping it — the pixels are gone.
    func deleteSelection() {
        guard let selection else { return }
        floatSelectionIfNeeded()
        self.selection = nil
        let rect = selection.rect
        commitEdit("Delete")
        notifyImageChanged(rect)
        notifySelectionChanged()
    }

    func selectAll() {
        commitSelection()
        guard let all = Selection.rectangular(from: image, rect: image.bounds) else { return }
        selection = all
        notifySelectionChanged()
    }

    func deselect() {
        commitSelection()
    }

    /// The image as it looks on screen, floating selection included.
    func flattenedImage() -> PixelBuffer {
        guard let selection else { return image }
        let out = image.copy()
        let transparent = PaintSettings.shared.transparentSelection
            ? PaintSettings.shared.background : nil
        // A never-moved marquee is still part of the canvas, so it must not be
        // drawn twice — only float it if it has actually been lifted.
        if selection.isFloating || selection.sourceRect == nil {
            selection.composite(onto: out, transparentColor: transparent)
        }
        return out
    }

    // MARK: - Clipboard

    func copySelectionToPasteboard() {
        let source: PixelBuffer
        if let selection {
            source = selection.buffer
        } else {
            source = image
        }
        guard let cg = source.makeCGImage() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: source.width, height: source.height)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
    }

    func cutSelection() {
        guard selection != nil else { return }
        copySelectionToPasteboard()
        deleteSelection()
    }

    /// Pastes the clipboard as a new floating selection anchored at `origin`.
    @discardableResult
    func paste(at origin: PixelPoint = .zero) -> Bool {
        let pb = NSPasteboard.general
        guard let objects = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              let nsImage = objects.first,
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let buffer = PixelBuffer(cgImage: cg)
        else { return false }

        commitSelection()
        // Oversized pastes get scaled down to fit, which beats silently
        // clipping most of the image off the canvas.
        var pasted = buffer
        if pasted.width > image.width || pasted.height > image.height {
            let scale = min(Double(image.width) / Double(pasted.width),
                            Double(image.height) / Double(pasted.height))
            pasted = pasted.resampled(toWidth: Int(Double(pasted.width) * scale),
                                      height: Int(Double(pasted.height) * scale))
        }
        let clamped = PixelPoint(max(0, min(origin.x, image.width - pasted.width)),
                                 max(0, min(origin.y, image.height - pasted.height)))
        selection = Selection(buffer: pasted, origin: clamped, mask: nil, sourceRect: nil)
        notifySelectionChanged()
        return true
    }

    static var pasteboardHasImage: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    // MARK: - Image operations

    func clearImage() {
        commitSelection()
        beginEdit()
        image.fillAll(PaintSettings.shared.background)
        notifyImageChanged(image.bounds)
        commitEdit("Clear Image")
    }

    func invertColors() {
        if let selection {
            selection.invertColors()
            notifySelectionChanged()
            return
        }
        beginEdit()
        let inverted = image.inverted()
        image.restore(image.bounds, from: inverted.snapshot(inverted.bounds))
        notifyImageChanged(image.bounds)
        commitEdit("Invert Colors")
    }

    func flip(horizontal: Bool) {
        if let selection {
            if horizontal { selection.flipHorizontally() } else { selection.flipVertically() }
            notifySelectionChanged()
            return
        }
        let flipped = horizontal ? image.flippedHorizontally() : image.flippedVertically()
        beginEdit()
        image.restore(image.bounds, from: flipped.snapshot(flipped.bounds))
        notifyImageChanged(image.bounds)
        commitEdit(horizontal ? "Flip Horizontal" : "Flip Vertical")
    }

    func rotate(degrees: Int) {
        if let selection {
            selection.rotate(degrees: degrees)
            notifySelectionChanged()
            return
        }
        let rotated = image.rotated(degrees: degrees)
        if rotated.width == image.width, rotated.height == image.height {
            beginEdit()
            image.restore(image.bounds, from: rotated.snapshot(rotated.bounds))
            notifyImageChanged(image.bounds)
            commitEdit("Rotate")
        } else {
            replaceImage(with: rotated, actionName: "Rotate")
        }
    }

    func resizeCanvas(toWidth w: Int, height h: Int) {
        commitSelection()
        guard w != image.width || h != image.height, w > 0, h > 0 else { return }
        let resized = image.resizedCanvas(toWidth: w, height: h, background: PaintSettings.shared.background)
        replaceImage(with: resized, actionName: "Image Attributes")
    }

    func stretch(horizontalPercent: Double, verticalPercent: Double,
                 skewHorizontalDegrees: Double, skewVerticalDegrees: Double) {
        commitSelection()
        var result = image
        if horizontalPercent != 100 || verticalPercent != 100 {
            let w = max(1, Int((Double(image.width) * horizontalPercent / 100).rounded()))
            let h = max(1, Int((Double(image.height) * verticalPercent / 100).rounded()))
            result = result.resampled(toWidth: w, height: h)
        }
        if skewHorizontalDegrees != 0 || skewVerticalDegrees != 0 {
            result = result.skewed(hDegrees: skewHorizontalDegrees,
                                   vDegrees: skewVerticalDegrees,
                                   background: PaintSettings.shared.background)
        }
        guard result !== image else { return }
        replaceImage(with: result, actionName: "Stretch/Skew")
    }

    /// Trims the canvas down to the current selection.
    func cropToSelection() {
        guard let selection else { return }
        let rect = selection.rect
        let cropped: PixelBuffer
        if selection.isFloating || selection.sourceRect == nil {
            cropped = selection.buffer.copy()
            if let mask = selection.mask {
                let bg = PaintSettings.shared.background
                for i in 0 ..< mask.count where !mask[i] {
                    cropped.storage[i] = bg.raw
                }
            }
        } else {
            cropped = image.extract(rect)
        }
        self.selection = nil
        notifySelectionChanged()
        replaceImage(with: cropped, actionName: "Crop")
    }

    // MARK: - Reading and writing

    override class var readableTypes: [String] {
        ["public.png", "public.jpeg", "public.tiff", "com.microsoft.bmp", "com.compuserve.gif"]
    }

    override class var writableTypes: [String] {
        ["public.png", "public.jpeg", "public.tiff", "com.microsoft.bmp", "com.compuserve.gif"]
    }

    override class func isNativeType(_ type: String) -> Bool { true }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let rep = NSBitmapImageRep(data: data),
              let cg = rep.cgImage,
              let buffer = PixelBuffer(cgImage: cg)
        else { throw PaintError.unreadableImage }
        image = buffer
        selection = nil
        editSnapshot = nil
        undoManager?.removeAllActions()
        notifyCanvasSizeChanged()
    }

    override func data(ofType typeName: String) throws -> Data {
        let fileType = PaintDocument.bitmapFileType(for: typeName)
        var source = flattenedImage()

        // JPEG, BMP and GIF have no usable alpha, so flatten onto white first
        // instead of letting the encoder guess.
        if fileType != .png && fileType != .tiff {
            let flat = PixelBuffer(width: source.width, height: source.height, fill: .white)
            flat.draw(source, at: .zero)
            source = flat
        }

        guard let cg = source.makeCGImage() else { throw PaintError.unwritableImage }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: source.width, height: source.height)

        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if fileType == .jpeg { properties[.compressionFactor] = 0.92 }
        guard let data = rep.representation(using: fileType, properties: properties) else {
            throw PaintError.unwritableImage
        }
        return data
    }

    private static func bitmapFileType(for typeName: String) -> NSBitmapImageRep.FileType {
        switch typeName {
        case "public.jpeg", "public.jpeg-2000": return .jpeg
        case "public.tiff": return .tiff
        case "com.microsoft.bmp": return .bmp
        case "com.compuserve.gif": return .gif
        default: return .png
        }
    }

    /// Writes just the selection (or the whole image) to a file — Paint's
    /// Edit ▸ Copy To.
    func writeSelection(to url: URL) throws {
        let source = selection?.buffer ?? flattenedImage()
        guard let cg = source.makeCGImage() else { throw PaintError.unwritableImage }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: source.width, height: source.height)
        let ext = url.pathExtension.lowercased()
        let type: NSBitmapImageRep.FileType = ext == "jpg" || ext == "jpeg" ? .jpeg
            : ext == "bmp" ? .bmp
            : ext == "gif" ? .gif
            : ext == "tif" || ext == "tiff" ? .tiff
            : .png
        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if type == .jpeg { properties[.compressionFactor] = 0.92 }
        guard let data = rep.representation(using: type, properties: properties) else {
            throw PaintError.unwritableImage
        }
        try data.write(to: url)
    }

    /// Loads a file as a floating selection — Paint's Edit ▸ Paste From.
    func pasteSelection(from url: URL) throws {
        guard let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let buffer = PixelBuffer(cgImage: cg)
        else { throw PaintError.unreadableImage }
        commitSelection()
        selection = Selection(buffer: buffer, origin: .zero, mask: nil, sourceRect: nil)
        notifySelectionChanged()
    }

    // MARK: - Printing

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws
        -> NSPrintOperation {
        let source = flattenedImage()
        guard let cg = source.makeCGImage() else { throw PaintError.unwritableImage }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: source.width, height: source.height)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)

        let view = NSImageView(frame: NSRect(origin: .zero, size: rep.size))
        view.image = nsImage
        view.imageScaling = .scaleProportionallyUpOrDown

        let info = printInfo.copy() as! NSPrintInfo
        for (key, value) in printSettings { info.dictionary()[key as NSString] = value }
        return NSPrintOperation(view: view, printInfo: info)
    }
}
