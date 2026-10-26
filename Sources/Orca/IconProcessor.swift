import AppKit

/// Turns any user-picked raster image into a macOS-standard app icon.
///
/// The source format is irrelevant — jpg, jpeg, png, heic, tiff, gif and webp are all decoded by
/// `NSImage` and reduced the same way, so there is no per-extension branch to keep in sync.
///
/// The icon is composed on Apple's app-icon grid: a 1024 px canvas whose rounded-square body is
/// 824 px, inset 100 px. That margin is what keeps the icon at the same optical size as the system
/// icons in the Dock and Finder; a full-bleed square sits visibly larger than its neighbours. The
/// body is clipped to a continuous-curvature squircle (a superellipse) rather than a circular-arc
/// round, which is the shape macOS app icons actually use.
enum IconProcessor {
    /// Side of the composed icon canvas.
    static let canvas: CGFloat = 1024

    /// Transparent margin around the body; Apple's macOS grid insets the 824 px body by 100 px.
    static let margin: CGFloat = 100

    /// Side of the rounded body inside the canvas.
    static var bodySide: CGFloat { canvas - margin * 2 }

    /// Superellipse exponent; ~5 reproduces the continuous curvature of the system icon shape.
    static let squircleExponent: CGFloat = 5

    /// Composes `image` into a standard app icon: a centre-cropped square body on a padded canvas.
    static func icon(from image: NSImage) -> NSImage? {
        // Centre-crop to a square first, so the body never distorts whatever the source aspect is.
        guard let source = bitmap(image), let square = squareCrop(source) else { return nil }

        guard let context = context(side: canvas) else { return nil }

        let body = CGRect(x: margin, y: margin, width: bodySide, height: bodySide)
        context.interpolationQuality = .high
        // Clip to the squircle before drawing, so the artwork's own corners follow the shape.
        context.addPath(squircle(in: body))
        context.clip()
        context.draw(square, in: body)

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: canvas, height: canvas))
    }

    /// PNG bytes of an image, for the on-disk copy the startup surface reloads next launch.
    static func pngData(_ image: NSImage) -> Data? {
        guard let source = bitmap(image) else { return nil }
        return NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:])
    }

    /// PNG bytes of `image` scaled to `size`, for the smaller `.icns` container entries.
    static func pngData(_ image: NSImage, size: CGFloat) -> Data? {
        guard let source = bitmap(image) else { return nil }
        return png(source, size: size)
    }

    /// A small square PNG of a *composed* icon, cropped to its body so it fills a preview box.
    ///
    /// Composed icons keep their artwork inset by `margin`; cropping that away lets the settings
    /// chips show the icon itself instead of an icon floating in a transparent border.
    static func thumbnailPNG(_ icon: NSImage, size: CGFloat) -> Data? {
        guard let source = bitmap(icon) else { return nil }
        let pixels = CGFloat(source.width)
        guard pixels > 0 else { return nil }
        let factor = pixels / canvas
        let inset = margin * factor
        let side = pixels - inset * 2
        guard side > 0 else { return nil }
        guard let body = source.cropping(to: CGRect(x: inset, y: inset, width: side, height: side))
        else { return nil }
        return png(body, size: size)
    }

    /// Clips `image` to the app-icon silhouette, scaled to fill a `size × size` square.
    ///
    /// Composed icons are already drawn as this shape; this hands the same continuous-curvature
    /// squircle to a bare picture — the transparent character mark on the startup surface above
    /// all — so artwork whose own frame cuts the subject gets the app icon's corners instead of
    /// straight edges, and both surfaces read as one silhouette.
    static func rounded(_ image: NSImage, size: CGFloat) -> NSImage? {
        let pixels = Int(size.rounded())
        guard pixels > 0,
              let source = bitmap(image),
              let square = squareCrop(source),
              let context = context(side: CGFloat(pixels))
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels))
        context.interpolationQuality = .high
        context.addPath(squircle(in: rect))
        context.clip()
        context.draw(square, in: rect)
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: size, height: size))
    }

    /// Draws `source` into a `size × size` transparent bitmap and encodes it as PNG.
    private static func png(_ source: CGImage, size: CGFloat) -> Data? {
        let pixels = Int(size.rounded())
        guard pixels > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: pixels, height: pixels,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        guard let output = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
    }

    /// Composes transparent-background `artwork` over `background`, on the app-icon grid.
    ///
    /// Used by the SVG template: the artwork carries no background of its own, so the chosen
    /// colour fills the squircle and shows through the transparent gaps around the subject.
    static func template(artwork: NSImage, background: NSColor) -> NSImage? {
        guard let source = bitmap(artwork),
              let square = squareCrop(source),
              let color = background.usingColorSpace(.sRGB),
              let context = context(side: canvas)
        else { return nil }

        let body = CGRect(x: margin, y: margin, width: bodySide, height: bodySide)
        context.interpolationQuality = .high
        context.addPath(squircle(in: body))
        context.clip()
        context.setFillColor(color.cgColor)
        context.fill(body)
        // The SVG subject has a transparent background, so it sits over the colour untouched.
        context.draw(square, in: body)

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: canvas, height: canvas))
    }

    /// A transparent sRGB bitmap of `side × side` pixels, the canvas every composed icon is drawn on.
    private static func context(side: CGFloat) -> CGContext? {
        guard side > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: Int(side), height: Int(side),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// The largest centred square of `source`, so composing never distorts a non-square picture.
    private static func squareCrop(_ source: CGImage) -> CGImage? {
        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        let edge = min(width, height)
        guard edge > 0 else { return nil }
        return source.cropping(to: CGRect(
            x: (width - edge) / 2, y: (height - edge) / 2, width: edge, height: edge
        ))
    }

    /// A bitmap independent of any screen, so cropping and scaling never sample the wrong scale.
    private static func bitmap(_ image: NSImage) -> CGImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    /// A superellipse path — continuous curvature, the shape macOS app icons use.
    private static func squircle(in rect: CGRect) -> CGPath {
        let a = rect.width / 2
        let b = rect.height / 2
        let exponent = 2 / squircleExponent
        let path = CGMutablePath()
        let steps = 360
        for step in 0...steps {
            let theta = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let cosTheta = cos(theta)
            let sinTheta = sin(theta)
            let point = CGPoint(
                x: rect.midX + a * copysign(pow(abs(cosTheta), exponent), cosTheta),
                y: rect.midY + b * copysign(pow(abs(sinTheta), exponent), sinTheta)
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
