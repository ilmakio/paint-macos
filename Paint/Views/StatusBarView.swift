import AppKit

/// The thin readout along the bottom: pointer position, live drag size, canvas
/// size, and the zoom control.
final class StatusBarView: NSView {
    var onZoomChange: ((CGFloat) -> Void)?
    var onGridToggle: ((Bool) -> Void)?

    private let cursorLabel = StatusBarView.makeLabel(width: 96)
    private let sizeLabel = StatusBarView.makeLabel(width: 116)
    private let canvasLabel = StatusBarView.makeLabel(width: 116)
    private let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gridToggle = NSButton()

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }

    init() {
        super.init(frame: .zero)

        zoomPopup.controlSize = .small
        zoomPopup.font = .systemFont(ofSize: 10)
        zoomPopup.bezelStyle = .roundRect
        zoomPopup.target = self
        zoomPopup.action = #selector(zoomPicked(_:))
        for level in CanvasView.zoomLevels {
            let title = level < 1 ? "\(Int(level * 100))%" : "\(Int(level))00%"
            zoomPopup.addItem(withTitle: level < 1 ? title : "\(Int(level))×")
            zoomPopup.lastItem?.tag = Int(level * 100)
        }

        gridToggle.title = "Grid"
        gridToggle.setButtonType(.pushOnPushOff)
        gridToggle.bezelStyle = .roundRect
        gridToggle.controlSize = .small
        gridToggle.font = .systemFont(ofSize: 10)
        gridToggle.target = self
        gridToggle.action = #selector(gridToggled(_:))
        gridToggle.state = PaintSettings.shared.showGrid ? .on : .off
        gridToggle.toolTip = "Show the pixel grid (needs 4× zoom or more)"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [cursorLabel, separator(), sizeLabel, separator(),
                                        canvasLabel, spacer, gridToggle, zoomPopup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setCursor(nil)
        setDragSize(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    private static func makeLabel(width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func separator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return view
    }

    // MARK: Updates

    func setCursor(_ point: PixelPoint?) {
        cursorLabel.stringValue = point.map { "\($0.x), \($0.y)" } ?? "—"
    }

    func setDragSize(_ rect: PixelRect?) {
        if let rect {
            sizeLabel.stringValue = "↔ \(rect.width) × \(rect.height)"
        } else {
            sizeLabel.stringValue = ""
        }
    }

    func setCanvasSize(width: Int, height: Int) {
        canvasLabel.stringValue = "Canvas \(width) × \(height)"
    }

    func setZoom(_ zoom: CGFloat) {
        let tag = Int(zoom * 100)
        if let index = zoomPopup.itemArray.firstIndex(where: { $0.tag == tag }) {
            zoomPopup.selectItem(at: index)
        }
    }

    func setGrid(_ on: Bool) {
        gridToggle.state = on ? .on : .off
    }

    @objc private func zoomPicked(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        onZoomChange?(CGFloat(item.tag) / 100)
    }

    @objc private func gridToggled(_ sender: NSButton) {
        onGridToggle?(sender.state == .on)
    }
}
