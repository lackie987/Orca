import AppKit

/// Translation between the `#rrggbb` strings web themes speak and AppKit colours.
enum ColorHex {
    /// Parses `#rrggbb`, tolerating a missing prefix and either case; nil for anything else.
    static func color(_ value: String?) -> NSColor? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6, let rgb = UInt32(text, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }

    /// Renders a colour back to lowercase `#rrggbb`; nil when it has no sRGB representation.
    static func string(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { component in
            String(format: "%02x", Int((component * 255).rounded()))
        }
        return "#" + components.joined()
    }

    /// Reports whether a colour reads as a dark plane, using the sRGB luma of its three channels.
    static func isDark(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let luma = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luma < 0.5
    }
}
