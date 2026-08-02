import AppKit

enum Palette {
    /// The 28 colours from the bottom of every Paint window, in the original
    /// order: 14 dark on the top row, their 14 bright counterparts below.
    static let classic: [Pixel] = [
        Pixel(r: 0, g: 0, b: 0),       Pixel(r: 128, g: 128, b: 128),
        Pixel(r: 128, g: 0, b: 0),     Pixel(r: 128, g: 128, b: 0),
        Pixel(r: 0, g: 128, b: 0),     Pixel(r: 0, g: 128, b: 128),
        Pixel(r: 0, g: 0, b: 128),     Pixel(r: 128, g: 0, b: 128),
        Pixel(r: 128, g: 128, b: 64),  Pixel(r: 0, g: 64, b: 64),
        Pixel(r: 0, g: 128, b: 255),   Pixel(r: 0, g: 64, b: 128),
        Pixel(r: 128, g: 0, b: 255),   Pixel(r: 128, g: 64, b: 0),

        Pixel(r: 255, g: 255, b: 255), Pixel(r: 192, g: 192, b: 192),
        Pixel(r: 255, g: 0, b: 0),     Pixel(r: 255, g: 255, b: 0),
        Pixel(r: 0, g: 255, b: 0),     Pixel(r: 0, g: 255, b: 255),
        Pixel(r: 0, g: 0, b: 255),     Pixel(r: 255, g: 0, b: 255),
        Pixel(r: 255, g: 255, b: 128), Pixel(r: 0, g: 255, b: 128),
        Pixel(r: 128, g: 255, b: 255), Pixel(r: 128, g: 128, b: 255),
        Pixel(r: 255, g: 0, b: 128),   Pixel(r: 255, g: 128, b: 64),
    ]

    static let columns = 14
    static let rows = 2
}

// MARK: - AppKit bridging

extension Pixel {
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        self.init(
            r: UInt8(clamping: Int((rgb.redComponent * 255).rounded())),
            g: UInt8(clamping: Int((rgb.greenComponent * 255).rounded())),
            b: UInt8(clamping: Int((rgb.blueComponent * 255).rounded())),
            a: UInt8(clamping: Int((rgb.alphaComponent * 255).rounded()))
        )
    }

    var nsColor: NSColor {
        let s = straight
        return NSColor(srgbRed: CGFloat(s.r) / 255, green: CGFloat(s.g) / 255,
                       blue: CGFloat(s.b) / 255, alpha: CGFloat(s.a) / 255)
    }

    var cgColor: CGColor { nsColor.cgColor }

    /// `#RRGGBB`, shown in the status bar and used to persist custom swatches.
    var hexString: String {
        let s = straight
        return String(format: "#%02X%02X%02X", s.r, s.g, s.b)
    }

    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(r: UInt8((value >> 16) & 0xFF), g: UInt8((value >> 8) & 0xFF), b: UInt8(value & 0xFF))
    }

    /// Picks black or white text so a label stays readable on this swatch.
    var contrastingColor: NSColor {
        let s = straight
        let luma = 0.299 * Double(s.r) + 0.587 * Double(s.g) + 0.114 * Double(s.b)
        return luma > 140 ? .black : .white
    }
}
