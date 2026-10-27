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
        guard let file = container(for: icon) else { return false }
        return (try? file.write(to: url, options: .atomic)) != nil
    }

    /// Writes `icon` to `url` only when the bytes on disk differ; returns whether it wrote.
    ///
    /// The installed bundle's `AppIcon.icns` is a sealed resource, so every real write costs a
    /// re-sign (see `AppBundleSeal`). Re-applying the icon that is already there — at launch, on
    /// activation, after a theme change that leaves the template colour alone — must not pay that.
    @discardableResult
    static func writeIfChanged(_ icon: NSImage, to url: URL) -> Bool {
        guard let file = container(for: icon) else { return false }
        if let existing = try? Data(contentsOf: url), existing == file { return false }
        return (try? file.write(to: url, options: .atomic)) != nil
    }

    /// The `.icns` container for `icon`, or nil when one of the sizes cannot be rendered.
    private static func container(for icon: NSImage) -> Data? {
        var body = Data()
        for entry in entries {
            guard let png = IconProcessor.pngData(icon, size: entry.side),
                  let type = entry.type.data(using: .ascii)
            else { return nil }
            body.append(type)
            body.append(bigEndian(UInt32(png.count + 8)))
            body.append(png)
        }
        var file = Data("icns".utf8)
        file.append(bigEndian(UInt32(body.count + 8)))
        file.append(body)
        return file
    }

    /// Big-endian 32-bit, the byte order every ICNS length field uses.
    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
