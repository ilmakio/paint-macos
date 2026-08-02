import AppKit

extension Notification.Name {
    /// Posted whenever any shared setting changes. Windows listen and refresh
    /// their toolbox, options panel and palette so multiple documents stay in
    /// step, exactly as they would if Paint had ever grown a second window.
    static let paintSettingsDidChange = Notification.Name("PaintSettingsDidChange")
}

/// Everything that lives outside the image itself: the selected tool, the two
/// active colours, nib sizes, and the palette.
final class PaintSettings {
    static let shared = PaintSettings()

    private var suppressNotifications = false

    private func changed() {
        guard !suppressNotifications else { return }
        save()
        NotificationCenter.default.post(name: .paintSettingsDidChange, object: self)
    }

    // MARK: Tool

    var tool: ToolKind = .pencil {
        didSet { if tool != oldValue { changed() } }
    }

    // MARK: Colours

    /// Left mouse button paints with this.
    var foreground: Pixel = .black { didSet { if foreground != oldValue { changed() } } }
    /// Right mouse button paints with this; it is also what the eraser lays down.
    var background: Pixel = .white { didSet { if background != oldValue { changed() } } }

    var palette: [Pixel] = Palette.classic { didSet { changed() } }

    func swapColors() {
        suppressNotifications = true
        let f = foreground
        foreground = background
        background = f
        suppressNotifications = false
        changed()
    }

    func resetColors() {
        suppressNotifications = true
        foreground = .black
        background = .white
        suppressNotifications = false
        changed()
    }

    func resetPalette() {
        palette = Palette.classic
    }

    // MARK: Nib sizes

    var brushSize: Int = 4 { didSet { brushSize = clampSize(brushSize); if brushSize != oldValue { changed() } } }
    var brushShape: BrushShape = .round { didSet { if brushShape != oldValue { changed() } } }
    var pencilSize: Int = 1 { didSet { pencilSize = clampSize(pencilSize); if pencilSize != oldValue { changed() } } }
    var eraserSize: Int = 12 { didSet { eraserSize = clampSize(eraserSize); if eraserSize != oldValue { changed() } } }
    var lineWidth: Int = 1 { didSet { lineWidth = clampSize(lineWidth); if lineWidth != oldValue { changed() } } }
    var airbrushRadius: Int = 9 { didSet { airbrushRadius = clampSize(airbrushRadius); if airbrushRadius != oldValue { changed() } } }
    var airbrushDensity: Int = 12 { didSet { if airbrushDensity != oldValue { changed() } } }

    private func clampSize(_ v: Int) -> Int { max(1, min(200, v)) }

    /// The size control is shared, but each tool remembers its own value.
    var sizeForCurrentTool: Int {
        get {
            switch tool {
            case .brush: return brushSize
            case .pencil: return pencilSize
            case .eraser: return eraserSize
            case .airbrush: return airbrushRadius
            default: return lineWidth
            }
        }
        set {
            switch tool {
            case .brush: brushSize = newValue
            case .pencil: pencilSize = newValue
            case .eraser: eraserSize = newValue
            case .airbrush: airbrushRadius = newValue
            default: lineWidth = newValue
            }
        }
    }

    /// The nib the current tool should stamp with.
    func currentStamp() -> BrushStamp {
        switch tool {
        case .brush: return BrushStamp.make(shape: brushShape, size: brushSize)
        case .pencil: return BrushStamp.make(shape: .square, size: pencilSize)
        case .eraser: return BrushStamp.make(shape: .square, size: eraserSize)
        default: return BrushStamp.make(shape: .round, size: lineWidth)
        }
    }

    // MARK: Shape and fill options

    var shapeStyle: ShapeFillStyle = .outline { didSet { if shapeStyle != oldValue { changed() } } }
    var fillTolerance: Int = 0 { didSet { fillTolerance = max(0, min(255, fillTolerance)); if fillTolerance != oldValue { changed() } } }

    // MARK: Selection

    /// When on, pasting and moving a selection treats the background colour as
    /// see-through — Paint's "transparent background" toggle.
    var transparentSelection: Bool = false { didSet { if transparentSelection != oldValue { changed() } } }

    // MARK: Text

    var fontName: String = "Helvetica"
    var fontSize: CGFloat = 24
    var fontBold: Bool = false
    var fontItalic: Bool = false
    var fontUnderline: Bool = false

    func currentFont() -> NSFont {
        var font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        var traits: NSFontTraitMask = []
        if fontBold { traits.insert(.boldFontMask) }
        if fontItalic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        return font
    }

    func notifyTextAttributesChanged() { changed() }

    // MARK: View

    var showGrid: Bool = false { didSet { if showGrid != oldValue { changed() } } }
    var showThumbnail: Bool = false { didSet { if showThumbnail != oldValue { changed() } } }

    // MARK: Persistence

    private enum Key {
        static let tool = "tool"
        static let foreground = "foregroundColor"
        static let background = "backgroundColor"
        static let palette = "palette"
        static let brushSize = "brushSize"
        static let brushShape = "brushShape"
        static let pencilSize = "pencilSize"
        static let eraserSize = "eraserSize"
        static let lineWidth = "lineWidth"
        static let airbrushRadius = "airbrushRadius"
        static let shapeStyle = "shapeStyle"
        static let tolerance = "fillTolerance"
        static let transparentSelection = "transparentSelection"
        static let showGrid = "showGrid"
        static let fontName = "fontName"
        static let fontSize = "fontSize"
    }

    private init() {
        suppressNotifications = true
        let d = UserDefaults.standard
        if let raw = d.object(forKey: Key.tool) as? Int, let t = ToolKind(rawValue: raw) { tool = t }
        if let hex = d.string(forKey: Key.foreground), let p = Pixel(hexString: hex) { foreground = p }
        if let hex = d.string(forKey: Key.background), let p = Pixel(hexString: hex) { background = p }
        if let hexes = d.array(forKey: Key.palette) as? [String], hexes.count == Palette.classic.count {
            palette = hexes.compactMap { Pixel(hexString: $0) }
            if palette.count != Palette.classic.count { palette = Palette.classic }
        }
        if let v = d.object(forKey: Key.brushSize) as? Int { brushSize = v }
        if let v = d.object(forKey: Key.brushShape) as? Int, let s = BrushShape(rawValue: v) { brushShape = s }
        if let v = d.object(forKey: Key.pencilSize) as? Int { pencilSize = v }
        if let v = d.object(forKey: Key.eraserSize) as? Int { eraserSize = v }
        if let v = d.object(forKey: Key.lineWidth) as? Int { lineWidth = v }
        if let v = d.object(forKey: Key.airbrushRadius) as? Int { airbrushRadius = v }
        if let v = d.object(forKey: Key.shapeStyle) as? Int, let s = ShapeFillStyle(rawValue: v) { shapeStyle = s }
        if let v = d.object(forKey: Key.tolerance) as? Int { fillTolerance = v }
        if let v = d.object(forKey: Key.transparentSelection) as? Bool { transparentSelection = v }
        if let v = d.object(forKey: Key.showGrid) as? Bool { showGrid = v }
        if let v = d.string(forKey: Key.fontName) { fontName = v }
        if let v = d.object(forKey: Key.fontSize) as? Double, v > 0 { fontSize = CGFloat(v) }
        suppressNotifications = false
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(tool.rawValue, forKey: Key.tool)
        d.set(foreground.hexString, forKey: Key.foreground)
        d.set(background.hexString, forKey: Key.background)
        d.set(palette.map(\.hexString), forKey: Key.palette)
        d.set(brushSize, forKey: Key.brushSize)
        d.set(brushShape.rawValue, forKey: Key.brushShape)
        d.set(pencilSize, forKey: Key.pencilSize)
        d.set(eraserSize, forKey: Key.eraserSize)
        d.set(lineWidth, forKey: Key.lineWidth)
        d.set(airbrushRadius, forKey: Key.airbrushRadius)
        d.set(shapeStyle.rawValue, forKey: Key.shapeStyle)
        d.set(fillTolerance, forKey: Key.tolerance)
        d.set(transparentSelection, forKey: Key.transparentSelection)
        d.set(showGrid, forKey: Key.showGrid)
        d.set(fontName, forKey: Key.fontName)
        d.set(Double(fontSize), forKey: Key.fontSize)
    }
}
