import AppKit

/// Assembles the window — toolbox, canvas, palette, status bar — and is the
/// responder that every menu command lands on.
final class PaintWindowController: NSWindowController, NSWindowDelegate, CanvasViewDelegate,
                                   PaintDocumentObserver, NSToolbarDelegate, NSMenuItemValidation {

    private var canvasView: CanvasView?
    private var scrollView: NSScrollView?
    private let toolboxView = ToolboxView()
    private let optionsView = ToolOptionsView()
    private let paletteView = PaletteView()
    private let statusBar = StatusBarView()

    /// Lets the eyedropper hand control back where it came from.
    private var previousTool: ToolKind = .pencil
    private var didInstallUI = false

    private var paintDocument: PaintDocument? { document as? PaintDocument }

    // MARK: Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 760, height: 560)
        window.title = "Untitled"
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        windowFrameAutosaveName = "PaintWindow"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var document: AnyObject? {
        didSet {
            guard let paintDocument, !didInstallUI else { return }
            didInstallUI = true
            installUI(for: paintDocument)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    private func installUI(for document: PaintDocument) {
        guard let window else { return }

        let content = NSView()
        window.contentView = content

        let canvas = CanvasView(document: document)
        canvas.delegate = self
        canvasView = canvas

        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = CanvasChrome.backdrop
        scroll.allowsMagnification = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollView = scroll

        let sidebar = makeSidebar()
        paletteView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        let paletteBackground = NSVisualEffectView()
        paletteBackground.material = .titlebar
        paletteBackground.blendingMode = .withinWindow
        paletteBackground.state = .followsWindowActiveState
        paletteBackground.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(sidebar)
        content.addSubview(paletteBackground)
        content.addSubview(paletteView)
        content.addSubview(statusBar)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: paletteBackground.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 124),

            scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: paletteBackground.topAnchor),

            paletteBackground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            paletteBackground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paletteBackground.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            paletteView.leadingAnchor.constraint(equalTo: paletteBackground.leadingAnchor),
            paletteView.trailingAnchor.constraint(equalTo: paletteBackground.trailingAnchor),
            paletteView.topAnchor.constraint(equalTo: paletteBackground.topAnchor),
            paletteView.bottomAnchor.constraint(equalTo: paletteBackground.bottomAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        toolboxView.onSelect = { [weak self] kind in self?.applyToolChange(kind) }
        optionsView.onZoomPreset = { [weak self] level in self?.canvasView?.setZoom(level) }
        statusBar.onZoomChange = { [weak self] level in self?.canvasView?.setZoom(level) }
        statusBar.onGridToggle = { [weak self] on in
            PaintSettings.shared.showGrid = on
            self?.canvasView?.invalidateAll()
        }

        document.addObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .paintSettingsDidChange, object: nil)

        installToolbar()
        statusBar.setCanvasSize(width: document.image.width, height: document.image.height)
        statusBar.setZoom(canvas.zoom)
        statusBar.setGrid(PaintSettings.shared.showGrid)
        previousTool = PaintSettings.shared.tool

        window.makeFirstResponder(canvas)
        DispatchQueue.main.async { [weak self] in self?.fitIfLargerThanWindow() }
    }

    private func makeSidebar() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.translatesAutoresizingMaskIntoConstraints = false

        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        toolboxView.translatesAutoresizingMaskIntoConstraints = false
        optionsView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toolboxView)
        container.addSubview(separator)
        container.addSubview(optionsView)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = container
        scroll.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),

            container.widthAnchor.constraint(equalTo: scroll.widthAnchor),

            toolboxView.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            toolboxView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toolboxView.widthAnchor.constraint(equalToConstant: toolboxView.intrinsicContentSize.width),
            toolboxView.heightAnchor.constraint(equalToConstant: toolboxView.intrinsicContentSize.height),

            separator.topAnchor.constraint(equalTo: toolboxView.bottomAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            optionsView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            optionsView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            optionsView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -14),
        ])

        let bottom = container.bottomAnchor.constraint(greaterThanOrEqualTo: optionsView.bottomAnchor,
                                                       constant: 14)
        bottom.priority = .defaultHigh
        bottom.isActive = true

        return effect
    }

    private func fitIfLargerThanWindow() {
        guard let canvas = canvasView, let clip = scrollView?.contentView else { return }
        if canvas.scaledImageSize.width > clip.bounds.width
            || canvas.scaledImageSize.height > clip.bounds.height {
            canvas.zoomToFit()
        }
    }

    // MARK: - Toolbar

    private enum ToolbarID {
        static let undo = NSToolbarItem.Identifier("undo")
        static let redo = NSToolbarItem.Identifier("redo")
        static let zoomOut = NSToolbarItem.Identifier("zoomOut")
        static let zoomIn = NSToolbarItem.Identifier("zoomIn")
        static let zoomFit = NSToolbarItem.Identifier("zoomFit")
        static let grid = NSToolbarItem.Identifier("grid")
        static let crop = NSToolbarItem.Identifier("crop")
    }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "PaintToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.undo, ToolbarID.redo, .flexibleSpace,
         ToolbarID.zoomOut, ToolbarID.zoomIn, ToolbarID.zoomFit,
         .space, ToolbarID.grid, ToolbarID.crop]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func item(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String,
                  _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = nil
            item.action = action
            item.isBordered = true
            return item
        }

        switch identifier {
        case ToolbarID.undo:
            return item(identifier, "Undo", "arrow.uturn.backward", #selector(paintUndo(_:)))
        case ToolbarID.redo:
            return item(identifier, "Redo", "arrow.uturn.forward", #selector(paintRedo(_:)))
        case ToolbarID.zoomOut:
            return item(identifier, "Zoom Out", "minus.magnifyingglass", #selector(zoomOut(_:)))
        case ToolbarID.zoomIn:
            return item(identifier, "Zoom In", "plus.magnifyingglass", #selector(zoomIn(_:)))
        case ToolbarID.zoomFit:
            return item(identifier, "Fit to Window", "arrow.up.left.and.arrow.down.right",
                        #selector(zoomToFit(_:)))
        case ToolbarID.grid:
            return item(identifier, "Grid", "square.grid.3x3", #selector(toggleGrid(_:)))
        case ToolbarID.crop:
            return item(identifier, "Crop to Selection", "crop", #selector(cropToSelection(_:)))
        default:
            return nil
        }
    }

    // MARK: - Settings

    @objc private func settingsChanged() {
        toolboxView.refresh()
        optionsView.refreshValues()
        paletteView.needsDisplay = true
        canvasView?.setTool(PaintSettings.shared.tool)
        canvasView?.refreshTextEditorAttributes()
        statusBar.setGrid(PaintSettings.shared.showGrid)
        window?.invalidateCursorRects(for: paletteView)
    }

    private func applyToolChange(_ kind: ToolKind) {
        canvasView?.setTool(kind)
        optionsView.rebuild()
    }

    private func selectTool(_ kind: ToolKind) {
        let current = PaintSettings.shared.tool
        if current != .pickColor { previousTool = current }
        PaintSettings.shared.tool = kind
        applyToolChange(kind)
    }

    // MARK: - CanvasViewDelegate

    func canvasView(_ view: CanvasView, didMoveCursorTo point: PixelPoint?) {
        statusBar.setCursor(point)
    }

    func canvasViewDidChangeZoom(_ view: CanvasView) {
        statusBar.setZoom(view.zoom)
        optionsView.currentZoom = view.zoom
        if let document = paintDocument {
            statusBar.setCanvasSize(width: document.image.width, height: document.image.height)
        }
    }

    func canvasView(_ view: CanvasView, didUpdateDragSize size: PixelRect?) {
        statusBar.setDragSize(size)
    }

    func canvasViewDidRequestToolRevert(_ view: CanvasView) {
        guard PaintSettings.shared.tool == .pickColor else { return }
        PaintSettings.shared.tool = previousTool
        applyToolChange(previousTool)
    }

    // MARK: - PaintDocumentObserver

    func paintDocumentDidChangeCanvasSize(_ document: PaintDocument) {
        statusBar.setCanvasSize(width: document.image.width, height: document.image.height)
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        canvasView?.finishCurrentTool()
        if let document = paintDocument { document.removeObserver(self) }
        NotificationCenter.default.removeObserver(self)
    }

    func windowDidResize(_ notification: Notification) {
        canvasView?.invalidateOverlay()
    }

    // MARK: - Edit menu

    /// `NSResponder.undoManager` resolves to nil on a window controller, so go
    /// to the document for it rather than silently getting a dead Undo menu.
    private var documentUndoManager: UndoManager? { paintDocument?.undoManager }

    @objc func paintUndo(_ sender: Any?) {
        // Land any half-finished shape or floating selection first, so one
        // Undo steps back over the whole gesture.
        canvasView?.finishCurrentTool()
        paintDocument?.commitSelection()
        documentUndoManager?.undo()
        canvasView?.invalidateAll()
    }

    @objc func paintRedo(_ sender: Any?) {
        canvasView?.finishCurrentTool()
        paintDocument?.commitSelection()
        documentUndoManager?.redo()
        canvasView?.invalidateAll()
    }

    @objc func cut(_ sender: Any?) {
        canvasView?.finishCurrentTool()
        paintDocument?.cutSelection()
        canvasView?.invalidateAll()
    }

    @objc func copy(_ sender: Any?) {
        paintDocument?.copySelectionToPasteboard()
    }

    @objc func paste(_ sender: Any?) {
        guard let document = paintDocument, let canvas = canvasView else { return }
        canvas.finishCurrentTool()
        // Drop the paste at the top-left of what the user can actually see.
        var origin = PixelPoint.zero
        if let clip = scrollView?.contentView {
            let visible = canvas.convert(clip.documentVisibleRect, from: clip)
            origin = canvas.pixel(at: NSPoint(x: max(0, visible.minX) + 4, y: max(0, visible.minY) + 4))
        }
        guard document.paste(at: origin) else { NSSound.beep(); return }
        if !PaintSettings.shared.tool.isSelection { selectTool(.rectangleSelect) }
        canvas.invalidateAll()
    }

    @objc func delete(_ sender: Any?) {
        paintDocument?.deleteSelection()
        canvasView?.invalidateAll()
    }

    @objc override func selectAll(_ sender: Any?) {
        canvasView?.finishCurrentTool()
        if !PaintSettings.shared.tool.isSelection { selectTool(.rectangleSelect) }
        paintDocument?.selectAll()
        canvasView?.invalidateOverlay()
    }

    @objc func clearSelection(_ sender: Any?) {
        paintDocument?.deselect()
        canvasView?.invalidateAll()
    }

    @objc func cropToSelection(_ sender: Any?) {
        paintDocument?.cropToSelection()
        canvasView?.invalidateAll()
    }

    @objc func copyTo(_ sender: Any?) {
        guard let document = paintDocument, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif]
        panel.nameFieldStringValue = "Selection.png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try document.writeSelection(to: url) } catch { self.showError(error) }
        }
    }

    @objc func pasteFrom(_ sender: Any?) {
        guard let document = paintDocument, let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try document.pasteSelection(from: url)
                if !PaintSettings.shared.tool.isSelection { self.selectTool(.rectangleSelect) }
                self.canvasView?.invalidateAll()
            } catch {
                self.showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: - Image menu

    @objc func flipHorizontal(_ sender: Any?) {
        canvasView?.finishCurrentTool()
        paintDocument?.flip(horizontal: true)
        canvasView?.invalidateAll()
    }

    @objc func flipVertical(_ sender: Any?) {
        canvasView?.finishCurrentTool()
        paintDocument?.flip(horizontal: false)
        canvasView?.invalidateAll()
    }

    @objc func rotate90(_ sender: Any?) { rotate(90) }
    @objc func rotate180(_ sender: Any?) { rotate(180) }
    @objc func rotate270(_ sender: Any?) { rotate(270) }

    private func rotate(_ degrees: Int) {
        canvasView?.finishCurrentTool()
        paintDocument?.rotate(degrees: degrees)
        canvasView?.invalidateAll()
    }

    @objc func invertColors(_ sender: Any?) {
        canvasView?.finishCurrentTool()
        paintDocument?.invertColors()
        canvasView?.invalidateAll()
    }

    @objc func clearImage(_ sender: Any?) {
        canvasView?.finishCurrentTool()
        paintDocument?.clearImage()
        canvasView?.invalidateAll()
    }

    @objc func imageAttributes(_ sender: Any?) {
        guard let document = paintDocument, let window else { return }
        canvasView?.finishCurrentTool()
        AttributesDialog.present(in: window, width: document.image.width,
                                 height: document.image.height) { [weak self] width, height in
            document.resizeCanvas(toWidth: width, height: height)
            self?.canvasView?.invalidateAll()
        }
    }

    @objc func stretchSkew(_ sender: Any?) {
        guard let document = paintDocument, let window else { return }
        canvasView?.finishCurrentTool()
        StretchSkewDialog.present(in: window) { [weak self] hp, vp, hs, vs in
            document.stretch(horizontalPercent: hp, verticalPercent: vp,
                             skewHorizontalDegrees: hs, skewVerticalDegrees: vs)
            self?.canvasView?.invalidateAll()
        }
    }

    @objc func toggleDrawOpaque(_ sender: Any?) {
        PaintSettings.shared.transparentSelection.toggle()
        optionsView.rebuild()
        canvasView?.invalidateAll()
    }

    // MARK: - View menu

    @objc func zoomIn(_ sender: Any?) {
        guard let canvas = canvasView else { return }
        canvas.zoomIn(around: PixelPoint(canvas.document.image.width / 2,
                                         canvas.document.image.height / 2))
    }

    @objc func zoomOut(_ sender: Any?) {
        guard let canvas = canvasView else { return }
        canvas.zoomOut(around: PixelPoint(canvas.document.image.width / 2,
                                          canvas.document.image.height / 2))
    }

    @objc func zoomActualSize(_ sender: Any?) {
        canvasView?.setZoom(1)
    }

    @objc func zoomToFit(_ sender: Any?) {
        canvasView?.zoomToFit()
    }

    @objc func toggleGrid(_ sender: Any?) {
        PaintSettings.shared.showGrid.toggle()
        canvasView?.invalidateAll()
    }

    // MARK: - Colours

    @objc func swapColors(_ sender: Any?) { PaintSettings.shared.swapColors() }
    @objc func resetColors(_ sender: Any?) { PaintSettings.shared.resetColors() }
    @objc func editForegroundColor(_ sender: Any?) { paletteView.openForegroundColorPanel() }
    @objc func editBackgroundColor(_ sender: Any?) { paletteView.openBackgroundColorPanel() }
    @objc func resetPalette(_ sender: Any?) { PaintSettings.shared.resetPalette() }

    // MARK: - Tools menu

    @objc func selectToolFromMenu(_ sender: NSMenuItem) {
        guard let kind = ToolKind(rawValue: sender.tag) else { return }
        selectTool(kind)
    }

    @objc func increaseToolSize(_ sender: Any?) {
        PaintSettings.shared.sizeForCurrentTool += 1
        optionsView.refreshValues()
    }

    @objc func decreaseToolSize(_ sender: Any?) {
        PaintSettings.shared.sizeForCurrentTool -= 1
        optionsView.refreshValues()
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        let document = paintDocument
        let hasSelection = document?.selection != nil

        // Bare-letter shortcuts must not fire while a text field has focus,
        // otherwise typing "p" in a dialog would swap tools.
        if isTextEditing, let action, Self.singleKeyActions.contains(action) {
            return false
        }

        switch action {
        case #selector(paintUndo(_:)):
            let name = documentUndoManager?.undoActionName ?? ""
            menuItem.title = name.isEmpty ? "Undo" : "Undo \(name)"
            // A floating selection or an unfinished shape is itself undoable
            // work, even before it has been written to the stack.
            return (documentUndoManager?.canUndo ?? false) || hasSelection || (document?.hasOpenEdit ?? false)
        case #selector(paintRedo(_:)):
            let name = documentUndoManager?.redoActionName ?? ""
            menuItem.title = name.isEmpty ? "Redo" : "Redo \(name)"
            return documentUndoManager?.canRedo ?? false
        case #selector(cut(_:)), #selector(delete(_:)), #selector(clearSelection(_:)),
             #selector(cropToSelection(_:)):
            return hasSelection
        case #selector(copy(_:)), #selector(copyTo(_:)):
            return document != nil
        case #selector(paste(_:)):
            return PaintDocument.pasteboardHasImage
        case #selector(toggleGrid(_:)):
            menuItem.state = PaintSettings.shared.showGrid ? .on : .off
            return true
        case #selector(toggleDrawOpaque(_:)):
            menuItem.state = PaintSettings.shared.transparentSelection ? .off : .on
            return true
        case #selector(selectToolFromMenu(_:)):
            menuItem.state = menuItem.tag == PaintSettings.shared.tool.rawValue ? .on : .off
            return true
        case #selector(zoomIn(_:)):
            return (canvasView?.zoom ?? 1) < CanvasView.zoomLevels.last!
        case #selector(zoomOut(_:)):
            return (canvasView?.zoom ?? 1) > CanvasView.zoomLevels.first!
        default:
            return true
        }
    }

    private var isTextEditing: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView { return true }
        if let view = responder as? NSView, view is NSText { return true }
        return false
    }

    /// Actions reachable through a modifier-less key equivalent.
    private static let singleKeyActions: Set<Selector> = [
        #selector(selectToolFromMenu(_:)),
        #selector(increaseToolSize(_:)),
        #selector(decreaseToolSize(_:)),
        #selector(swapColors(_:)),
        #selector(resetColors(_:)),
    ]
}
