import AppKit

/// Live preview of the current nib, drawn at real pixel proportions.
final class NibPreviewView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 92, height: 46) }

    override func draw(_ dirtyRect: NSRect) {
        let settings = PaintSettings.shared
        NSColor.textBackgroundColor.setFill()
        let box = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        box.fill()
        NSColor.separatorColor.setStroke()
        box.lineWidth = 1
        box.stroke()

        let stamp: BrushStamp
        if settings.tool == .airbrush {
            stamp = BrushStamp.make(shape: .round, size: settings.airbrushRadius * 2)
        } else {
            stamp = settings.currentStamp()
        }
        let footprint = stamp.bounds
        guard footprint.width > 0, footprint.height > 0 else { return }

        // Scale down only if the nib is bigger than the well.
        let scale = min(1, min((bounds.width - 10) / CGFloat(footprint.width),
                               (bounds.height - 10) / CGFloat(footprint.height)))
        let originX = bounds.midX - CGFloat(footprint.width) * scale / 2
        let originY = bounds.midY - CGFloat(footprint.height) * scale / 2

        // The preview is about shape and size, not colour — drawing it in the
        // label colour keeps it legible whatever the foreground happens to be.
        NSColor.labelColor.setFill()
        for span in stamp.spans {
            let rect = NSRect(x: originX + CGFloat(span.dx0 - footprint.x) * scale,
                              y: originY + CGFloat(span.dy - footprint.y) * scale,
                              width: CGFloat(span.dx1 - span.dx0 + 1) * scale,
                              height: scale)
            rect.fill()
        }
    }
}

/// The contextual panel under the toolbox. Rebuilds itself whenever the active
/// tool changes so only relevant controls are on screen.
final class ToolOptionsView: NSView {
    var onZoomPreset: ((CGFloat) -> Void)?
    var currentZoom: CGFloat = 1 { didSet { if currentZoom != oldValue { updateZoomSelection() } } }

    private let stack = NSStackView()
    private var sizeSlider: NSSlider?
    private var sizeValueLabel: NSTextField?
    private var toleranceSlider: NSSlider?
    private var toleranceValueLabel: NSTextField?
    private var nibPreview: NibPreviewView?
    private var zoomButtons: [NSButton] = []
    private var builtFor: ToolKind?

    private let contentWidth: CGFloat = 92

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: Building

    func rebuild() {
        let tool = PaintSettings.shared.tool
        builtFor = tool

        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        sizeSlider = nil
        sizeValueLabel = nil
        toleranceSlider = nil
        toleranceValueLabel = nil
        nibPreview = nil
        zoomButtons = []

        if tool.usesBrushShape { addBrushShapeSection() }
        if tool.usesSize { addSizeSection(for: tool) }
        if tool.usesFillStyle { addFillStyleSection() }
        if tool.usesTolerance { addToleranceSection() }
        if tool.isSelection { addTransparencySection(title: "Selection") }
        if tool == .text { addTextSection() }
        if tool == .magnifier { addZoomSection() }

        needsLayout = true
    }

    /// Cheap refresh for value-only changes, avoiding a full teardown.
    func refreshValues() {
        if builtFor != PaintSettings.shared.tool {
            rebuild()
            return
        }
        let settings = PaintSettings.shared
        if let sizeSlider {
            sizeSlider.integerValue = settings.sizeForCurrentTool
            sizeValueLabel?.stringValue = "\(settings.sizeForCurrentTool) px"
        }
        if let toleranceSlider {
            toleranceSlider.integerValue = settings.fillTolerance
            toleranceValueLabel?.stringValue = "\(settings.fillTolerance)"
        }
        nibPreview?.needsDisplay = true
    }

    private func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func addSizeSection(for tool: ToolKind) {
        stack.addArrangedSubview(header(tool == .airbrush ? "Spread" : "Size"))

        let preview = NibPreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 46).isActive = true
        stack.addArrangedSubview(preview)
        nibPreview = preview

        let slider = NSSlider(value: Double(PaintSettings.shared.sizeForCurrentTool),
                              minValue: 1, maxValue: tool == .airbrush ? 40 : 64,
                              target: self, action: #selector(sizeChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        stack.addArrangedSubview(slider)
        sizeSlider = slider

        let value = NSTextField(labelWithString: "\(PaintSettings.shared.sizeForCurrentTool) px")
        value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        value.textColor = .secondaryLabelColor
        stack.addArrangedSubview(value)
        sizeValueLabel = value
    }

    private func addBrushShapeSection() {
        stack.addArrangedSubview(header("Shape"))
        let control = NSSegmentedControl(images: BrushShape.allCases.map(shapeIcon),
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(shapeChanged(_:)))
        control.segmentStyle = .texturedRounded
        control.selectedSegment = PaintSettings.shared.brushShape.rawValue
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        for index in BrushShape.allCases.indices {
            control.setWidth(contentWidth / CGFloat(BrushShape.allCases.count), forSegment: index)
        }
        stack.addArrangedSubview(control)
    }

    private func addFillStyleSection() {
        stack.addArrangedSubview(header("Fill"))
        let control = NSSegmentedControl(images: ShapeFillStyle.allCases.map(fillStyleIcon),
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(fillStyleChanged(_:)))
        control.segmentStyle = .texturedRounded
        control.selectedSegment = PaintSettings.shared.shapeStyle.rawValue
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        for index in ShapeFillStyle.allCases.indices {
            control.setWidth(contentWidth / CGFloat(ShapeFillStyle.allCases.count), forSegment: index)
            control.setToolTip(ShapeFillStyle.allCases[index].title, forSegment: index)
        }
        stack.addArrangedSubview(control)
    }

    private func addToleranceSection() {
        stack.addArrangedSubview(header("Tolerance"))
        let slider = NSSlider(value: Double(PaintSettings.shared.fillTolerance),
                              minValue: 0, maxValue: 255,
                              target: self, action: #selector(toleranceChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        stack.addArrangedSubview(slider)
        toleranceSlider = slider

        let value = NSTextField(labelWithString: "\(PaintSettings.shared.fillTolerance)")
        value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        value.textColor = .secondaryLabelColor
        stack.addArrangedSubview(value)
        toleranceValueLabel = value
    }

    private func addTransparencySection(title: String) {
        stack.addArrangedSubview(header(title))
        let check = NSButton(checkboxWithTitle: "Transparent", target: self,
                             action: #selector(transparencyChanged(_:)))
        check.state = PaintSettings.shared.transparentSelection ? .on : .off
        check.font = .systemFont(ofSize: 11)
        check.toolTip = "Treat the background colour as see-through"
        stack.addArrangedSubview(check)
    }

    private func addTextSection() {
        stack.addArrangedSubview(header("Font"))

        let familyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        familyPopup.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        familyPopup.selectItem(withTitle: PaintSettings.shared.fontName)
        if familyPopup.indexOfSelectedItem < 0, let first = familyPopup.itemTitles.first {
            familyPopup.selectItem(withTitle: first)
        }
        familyPopup.target = self
        familyPopup.action = #selector(fontFamilyChanged(_:))
        familyPopup.controlSize = .small
        familyPopup.font = .systemFont(ofSize: 10)
        familyPopup.translatesAutoresizingMaskIntoConstraints = false
        familyPopup.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        stack.addArrangedSubview(familyPopup)

        let sizeField = NSTextField(string: "\(Int(PaintSettings.shared.fontSize))")
        sizeField.controlSize = .small
        sizeField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sizeField.target = self
        sizeField.action = #selector(fontSizeChanged(_:))
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let stepper = NSStepper()
        stepper.minValue = 4
        stepper.maxValue = 288
        stepper.increment = 1
        stepper.integerValue = Int(PaintSettings.shared.fontSize)
        stepper.target = self
        stepper.action = #selector(fontStepperChanged(_:))
        stepper.controlSize = .small

        let sizeRow = NSStackView(views: [sizeField, stepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 3
        stack.addArrangedSubview(sizeRow)
        fontSizeField = sizeField
        fontStepper = stepper

        let traits = NSSegmentedControl(labels: ["B", "I", "U"], trackingMode: .selectAny,
                                        target: self, action: #selector(fontTraitsChanged(_:)))
        traits.segmentStyle = .texturedRounded
        traits.setSelected(PaintSettings.shared.fontBold, forSegment: 0)
        traits.setSelected(PaintSettings.shared.fontItalic, forSegment: 1)
        traits.setSelected(PaintSettings.shared.fontUnderline, forSegment: 2)
        traits.translatesAutoresizingMaskIntoConstraints = false
        traits.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        for index in 0 ..< 3 { traits.setWidth(contentWidth / 3, forSegment: index) }
        stack.addArrangedSubview(traits)

        addTransparencySection(title: "Background")
    }

    private var fontSizeField: NSTextField?
    private var fontStepper: NSStepper?

    private func addZoomSection() {
        stack.addArrangedSubview(header("Zoom"))
        let presets: [CGFloat] = [1, 2, 4, 8]
        var row: NSStackView?
        for (index, level) in presets.enumerated() {
            let button = NSButton(title: "\(Int(level))×", target: self, action: #selector(zoomPreset(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10)
            button.tag = Int(level)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 42).isActive = true
            zoomButtons.append(button)
            if index % 2 == 0 {
                let newRow = NSStackView(views: [button])
                newRow.orientation = .horizontal
                newRow.spacing = 4
                stack.addArrangedSubview(newRow)
                row = newRow
            } else {
                row?.addArrangedSubview(button)
            }
        }
        updateZoomSelection()
    }

    private func updateZoomSelection() {
        for button in zoomButtons {
            button.state = CGFloat(button.tag) == currentZoom ? .on : .off
        }
    }

    // MARK: Icons

    private func shapeIcon(_ shape: BrushShape) -> NSImage {
        let image = NSImage(size: NSSize(width: 15, height: 15), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            switch shape {
            case .round:
                NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 9, height: 9)).fill()
            case .square:
                NSBezierPath(rect: NSRect(x: 3, y: 3, width: 9, height: 9)).fill()
            case .forwardSlash:
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 3.5, y: 11.5))
                path.line(to: NSPoint(x: 11.5, y: 3.5))
                path.lineWidth = 2.2
                path.stroke()
            case .backSlash:
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 3.5, y: 3.5))
                path.line(to: NSPoint(x: 11.5, y: 11.5))
                path.lineWidth = 2.2
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func fillStyleIcon(_ style: ShapeFillStyle) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 15), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let outer = NSRect(x: 2.5, y: 3.5, width: 11, height: 8)
            switch style {
            case .outline:
                let path = NSBezierPath(rect: outer)
                path.lineWidth = 1.4
                path.stroke()
            case .filled:
                NSBezierPath(rect: outer).fill()
            case .outlineAndFill:
                let path = NSBezierPath(rect: outer)
                path.lineWidth = 1.4
                path.stroke()
                NSBezierPath(rect: outer.insetBy(dx: 2.6, dy: 2.2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Actions

    @objc private func sizeChanged(_ sender: NSSlider) {
        PaintSettings.shared.sizeForCurrentTool = sender.integerValue
        sizeValueLabel?.stringValue = "\(sender.integerValue) px"
        nibPreview?.needsDisplay = true
    }

    @objc private func shapeChanged(_ sender: NSSegmentedControl) {
        guard let shape = BrushShape(rawValue: sender.selectedSegment) else { return }
        PaintSettings.shared.brushShape = shape
        nibPreview?.needsDisplay = true
    }

    @objc private func fillStyleChanged(_ sender: NSSegmentedControl) {
        guard let style = ShapeFillStyle(rawValue: sender.selectedSegment) else { return }
        PaintSettings.shared.shapeStyle = style
    }

    @objc private func toleranceChanged(_ sender: NSSlider) {
        PaintSettings.shared.fillTolerance = sender.integerValue
        toleranceValueLabel?.stringValue = "\(sender.integerValue)"
    }

    @objc private func transparencyChanged(_ sender: NSButton) {
        PaintSettings.shared.transparentSelection = sender.state == .on
    }

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        PaintSettings.shared.fontName = title
        PaintSettings.shared.notifyTextAttributesChanged()
    }

    @objc private func fontSizeChanged(_ sender: NSTextField) {
        let value = max(4, min(288, sender.integerValue))
        PaintSettings.shared.fontSize = CGFloat(value)
        sender.stringValue = "\(value)"
        fontStepper?.integerValue = value
        PaintSettings.shared.notifyTextAttributesChanged()
    }

    @objc private func fontStepperChanged(_ sender: NSStepper) {
        PaintSettings.shared.fontSize = CGFloat(sender.integerValue)
        fontSizeField?.stringValue = "\(sender.integerValue)"
        PaintSettings.shared.notifyTextAttributesChanged()
    }

    @objc private func fontTraitsChanged(_ sender: NSSegmentedControl) {
        PaintSettings.shared.fontBold = sender.isSelected(forSegment: 0)
        PaintSettings.shared.fontItalic = sender.isSelected(forSegment: 1)
        PaintSettings.shared.fontUnderline = sender.isSelected(forSegment: 2)
        PaintSettings.shared.notifyTextAttributesChanged()
    }

    @objc private func zoomPreset(_ sender: NSButton) {
        onZoomPreset?(CGFloat(sender.tag))
    }
}
