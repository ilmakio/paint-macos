import AppKit

/// The sixteen tools of the classic toolbox, in the order they appear in the
/// original 2×8 grid (row-major: Free-Form Select and Select on the top row).
enum ToolKind: Int, CaseIterable {
    case freeFormSelect
    case rectangleSelect
    case eraser
    case fill
    case pickColor
    case magnifier
    case pencil
    case brush
    case airbrush
    case text
    case line
    case curve
    case rectangle
    case polygon
    case ellipse
    case roundedRectangle

    var title: String {
        switch self {
        case .freeFormSelect: return "Free-Form Select"
        case .rectangleSelect: return "Select"
        case .eraser: return "Eraser"
        case .fill: return "Fill With Color"
        case .pickColor: return "Pick Color"
        case .magnifier: return "Magnifier"
        case .pencil: return "Pencil"
        case .brush: return "Brush"
        case .airbrush: return "Airbrush"
        case .text: return "Text"
        case .line: return "Line"
        case .curve: return "Curve"
        case .rectangle: return "Rectangle"
        case .polygon: return "Polygon"
        case .ellipse: return "Ellipse"
        case .roundedRectangle: return "Rounded Rectangle"
        }
    }

    /// SF Symbol, or nil where we draw the glyph ourselves.
    var symbolName: String? {
        switch self {
        case .freeFormSelect: return "lasso"
        case .rectangleSelect: return "rectangle.dashed"
        case .eraser: return "eraser.fill"
        case .fill: return nil                       // hand-drawn bucket
        case .pickColor: return "eyedropper"
        case .magnifier: return "magnifyingglass"
        case .pencil: return "pencil"
        case .brush: return "paintbrush.fill"
        case .airbrush: return nil                   // hand-drawn spray can
        case .text: return "textformat"
        case .line: return "line.diagonal"
        case .curve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .rectangle: return "rectangle"
        case .polygon: return "pentagon"
        case .ellipse: return "circle"
        case .roundedRectangle: return nil           // hand-drawn rounded rect
        }
    }

    /// Single-key shortcut, following the muscle memory most raster editors share.
    var shortcut: String {
        switch self {
        case .freeFormSelect: return "s"
        case .rectangleSelect: return "m"
        case .eraser: return "e"
        case .fill: return "f"
        case .pickColor: return "i"
        case .magnifier: return "z"
        case .pencil: return "p"
        case .brush: return "b"
        case .airbrush: return "a"
        case .text: return "t"
        case .line: return "l"
        case .curve: return "c"
        case .rectangle: return "r"
        case .polygon: return "g"
        case .ellipse: return "o"
        case .roundedRectangle: return "u"
        }
    }

    var helpText: String { "\(title)  (\(shortcut.uppercased()))" }

    // MARK: Capabilities — these drive which controls the options panel shows.

    /// Tools whose thickness comes from the size stepper.
    var usesSize: Bool {
        switch self {
        case .pencil, .brush, .eraser, .line, .curve, .rectangle, .polygon,
             .ellipse, .roundedRectangle, .airbrush:
            return true
        default:
            return false
        }
    }

    var usesBrushShape: Bool { self == .brush }

    /// Shapes that can be outlined, filled, or both.
    var usesFillStyle: Bool {
        switch self {
        case .rectangle, .polygon, .ellipse, .roundedRectangle: return true
        default: return false
        }
    }

    var usesTolerance: Bool {
        switch self {
        case .fill, .pickColor: return true
        default: return false
        }
    }

    var isSelection: Bool {
        switch self {
        case .rectangleSelect, .freeFormSelect: return true
        default: return false
        }
    }

    var cursor: NSCursor {
        switch self {
        case .text: return .iBeam
        case .magnifier: return .crosshair
        case .pickColor, .fill: return .crosshair
        case .rectangleSelect, .freeFormSelect: return .crosshair
        default: return .crosshair
        }
    }
}

/// How a shape tool renders: Paint's three-way outline / fill / both.
enum ShapeFillStyle: Int, CaseIterable {
    case outline
    case filled
    case outlineAndFill

    var title: String {
        switch self {
        case .outline: return "Outline"
        case .filled: return "Filled"
        case .outlineAndFill: return "Outline + Fill"
        }
    }

    var drawsOutline: Bool { self != .filled }
    var drawsFill: Bool { self != .outline }
}
