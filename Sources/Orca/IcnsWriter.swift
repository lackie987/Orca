import AppKit

/// Writes a composed icon as a real `.icns`, so an SVG template can become a normal macOS icon.
///
/// Modern macOS reads PNG-backed entries, so each size is rendered as PNG and wrapped in the
/// container directly — no `iconutil` subprocess and no temporary `.iconset` folder.
enum IcnsWriter {
    /// Modern PNG-backed entry types, smallest first.
    private static let entries: [(type: String, side: CGFloat)] = [
        ("icp4", 16), ("icp5", 32), ("icp6", 64),
        ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
    ]

    /// Writes `icon` to `url`; returns whether the file was written.
    @discardableResult
    static func write(_ icon: NSImage, to url: URL) -> Bool {
        var body = Data()
        for entry in entries {
            guard let png = IconProcessor.pngData(icon, size: entry.side),
                  let type = entry.type.data(using: .ascii)
            else { return false }
            body.append(type)
            body.append(bigEndian(UInt32(png.count + 8)))
            body.append(png)
        }
        var file = Data("icns".utf8)
        file.append(bigEndian(UInt32(body.count + 8)))
        file.append(body)
        return (try? file.write(to: url, options: .atomic)) != nil
    }

    /// Big-endian 32-bit, the byte order every ICNS length field uses.
    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
