import AppKit

enum ColorFormat: String, CaseIterable {
    case hex = "HEX"
    case rgb = "RGB"
    case rgba = "RGBA"
    case hsl = "HSL"
}

struct ParsedColor {
    let r: CGFloat  // 0-255
    let g: CGFloat  // 0-255
    let b: CGFloat  // 0-255
    let a: CGFloat  // 0-1
    let originalFormat: ColorFormat

    var nsColor: NSColor {
        NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    func formatted(_ format: ColorFormat) -> String {
        switch format {
        case .hex:
            let ri = Int(round(r)), gi = Int(round(g)), bi = Int(round(b))
            if a < 1 {
                let ai = Int(round(a * 255))
                return String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
            }
            return String(format: "#%02X%02X%02X", ri, gi, bi)
        case .rgb:
            return "rgb(\(Int(round(r))), \(Int(round(g))), \(Int(round(b))))"
        case .rgba:
            let aStr = a == 1 ? "1" : String(format: "%.2g", a)
            return "rgba(\(Int(round(r))), \(Int(round(g))), \(Int(round(b))), \(aStr))"
        case .hsl:
            let (h, s, l) = rgbToHSL(r: r / 255, g: g / 255, b: b / 255)
            return "hsl(\(Int(round(h))), \(Int(round(s)))%, \(Int(round(l)))%)"
        }
    }

    /// The "other" format for the command palette second action
    var alternateFormat: ColorFormat {
        originalFormat == .hex ? .rgb : .hex
    }
}

enum ColorConverter {

    static func parse(_ text: String) -> ParsedColor? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let result = parseHex(t) { return result }
        if let result = parseRGB(t) { return result }
        if let result = parseHSL(t) { return result }
        return nil
    }

    static func from(nsColor: NSColor) -> ParsedColor {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        return ParsedColor(
            r: round(c.redComponent * 255),
            g: round(c.greenComponent * 255),
            b: round(c.blueComponent * 255),
            a: c.alphaComponent,
            originalFormat: .hex
        )
    }

    // MARK: - Parsers

    private static func parseHex(_ t: String) -> ParsedColor? {
        guard t.hasPrefix("#") else { return nil }
        let hex = String(t.dropFirst())
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)

        switch hex.count {
        case 3:
            let r = CGFloat((rgb >> 8) & 0xF) * 17
            let g = CGFloat((rgb >> 4) & 0xF) * 17
            let b = CGFloat(rgb & 0xF) * 17
            return ParsedColor(r: r, g: g, b: b, a: 1, originalFormat: .hex)
        case 6:
            let r = CGFloat((rgb >> 16) & 0xFF)
            let g = CGFloat((rgb >> 8) & 0xFF)
            let b = CGFloat(rgb & 0xFF)
            return ParsedColor(r: r, g: g, b: b, a: 1, originalFormat: .hex)
        case 8:
            let r = CGFloat((rgb >> 24) & 0xFF)
            let g = CGFloat((rgb >> 16) & 0xFF)
            let b = CGFloat((rgb >> 8) & 0xFF)
            let a = CGFloat(rgb & 0xFF) / 255
            return ParsedColor(r: r, g: g, b: b, a: a, originalFormat: .hex)
        default: return nil
        }
    }

    private static func parseRGB(_ t: String) -> ParsedColor? {
        guard t.hasPrefix("rgb") else { return nil }
        let nums = t.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        let hasAlpha = t.hasPrefix("rgba") && nums.count >= 4
        return ParsedColor(
            r: nums[0], g: nums[1], b: nums[2],
            a: hasAlpha ? nums[3] : 1,
            originalFormat: hasAlpha ? .rgba : .rgb
        )
    }

    private static func parseHSL(_ t: String) -> ParsedColor? {
        guard t.hasPrefix("hsl") else { return nil }
        let nums = t.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        let (r, g, b) = hslToRGB(h: nums[0], s: nums[1], l: nums[2])
        let hasAlpha = t.hasPrefix("hsla") && nums.count >= 4
        return ParsedColor(
            r: r * 255, g: g * 255, b: b * 255,
            a: hasAlpha ? nums[3] : 1,
            originalFormat: .hsl
        )
    }
}

// MARK: - Color Space Conversion

private func rgbToHSL(r: CGFloat, g: CGFloat, b: CGFloat) -> (h: CGFloat, s: CGFloat, l: CGFloat) {
    let maxC = max(r, g, b), minC = min(r, g, b)
    let l = (maxC + minC) / 2

    guard maxC != minC else { return (0, 0, l * 100) }

    let d = maxC - minC
    let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
    var h: CGFloat
    switch maxC {
    case r: h = (g - b) / d + (g < b ? 6 : 0)
    case g: h = (b - r) / d + 2
    default: h = (r - g) / d + 4
    }
    h *= 60
    return (h, s * 100, l * 100)
}

private func hslToRGB(h: Double, s: Double, l: Double) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    let s = s / 100, l = l / 100
    guard s > 0 else { return (l, l, l) }

    let c = (1 - abs(2 * l - 1)) * s
    let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = l - c / 2

    let (r, g, b): (Double, Double, Double)
    switch h {
    case 0..<60: (r, g, b) = (c, x, 0)
    case 60..<120: (r, g, b) = (x, c, 0)
    case 120..<180: (r, g, b) = (0, c, x)
    case 180..<240: (r, g, b) = (0, x, c)
    case 240..<300: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return (r + m, g + m, b + m)
}
