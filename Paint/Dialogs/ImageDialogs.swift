import AppKit

/// Small helpers for building the two numeric sheets, so they stay visually
/// identical to each other and to the rest of the app.
private enum DialogKit {
    static func field(_ value: String, width: CGFloat = 70) -> NSTextField {
        let field = NSTextField(string: value)
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    static func suffix(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }

    static func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .trailing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

/// Image ▸ Attributes: set the canvas size in pixels.
enum AttributesDialog {
    static func present(in window: NSWindow, width: Int, height: Int,
                        completion: @escaping (Int, Int) -> Void) {
        let widthField = DialogKit.field("\(width)")
        let heightField = DialogKit.field("\(height)")

        let content = DialogKit.column([
            DialogKit.row([DialogKit.label("Width:"), widthField, DialogKit.suffix("px")]),
            DialogKit.row([DialogKit.label("Height:"), heightField, DialogKit.suffix("px")]),
        ])
        content.frame = NSRect(x: 0, y: 0, width: 250, height: 66)

        let alert = NSAlert()
        alert.messageText = "Image Attributes"
        alert.informativeText = "The image is anchored to the top-left corner; "
            + "new space is filled with the background colour."
        alert.accessoryView = content
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = widthField

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let w = max(1, min(20000, widthField.integerValue))
            let h = max(1, min(20000, heightField.integerValue))
            completion(w, h)
        }
    }
}

/// Image ▸ Stretch/Skew: percentage resample plus a shear, exactly the two
/// knobs Paint offered.
enum StretchSkewDialog {
    static func present(in window: NSWindow,
                        completion: @escaping (_ hPercent: Double, _ vPercent: Double,
                                               _ hSkew: Double, _ vSkew: Double) -> Void) {
        let hStretch = DialogKit.field("100")
        let vStretch = DialogKit.field("100")
        let hSkew = DialogKit.field("0")
        let vSkew = DialogKit.field("0")

        let stretchHeader = NSTextField(labelWithString: "Stretch")
        stretchHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        let skewHeader = NSTextField(labelWithString: "Skew")
        skewHeader.font = .systemFont(ofSize: 11, weight: .semibold)

        let content = DialogKit.column([
            stretchHeader,
            DialogKit.row([DialogKit.label("Horizontal:"), hStretch, DialogKit.suffix("%")]),
            DialogKit.row([DialogKit.label("Vertical:"), vStretch, DialogKit.suffix("%")]),
            skewHeader,
            DialogKit.row([DialogKit.label("Horizontal:"), hSkew, DialogKit.suffix("°")]),
            DialogKit.row([DialogKit.label("Vertical:"), vSkew, DialogKit.suffix("°")]),
        ])
        content.frame = NSRect(x: 0, y: 0, width: 260, height: 190)

        let alert = NSAlert()
        alert.messageText = "Stretch and Skew"
        alert.accessoryView = content
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = hStretch

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let hp = clampPercent(hStretch.doubleValue)
            let vp = clampPercent(vStretch.doubleValue)
            let hs = clampAngle(hSkew.doubleValue)
            let vs = clampAngle(vSkew.doubleValue)
            guard hp != 100 || vp != 100 || hs != 0 || vs != 0 else { return }
            completion(hp, vp, hs, vs)
        }
    }

    private static func clampPercent(_ value: Double) -> Double {
        value <= 0 ? 100 : min(max(value, 1), 2000)
    }

    /// Beyond ±80° the shear runs away to a canvas nobody wants.
    private static func clampAngle(_ value: Double) -> Double {
        min(max(value, -80), 80)
    }
}
