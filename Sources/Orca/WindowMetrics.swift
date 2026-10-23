import AppKit

/// Geometry shared by the window chrome and the native surfaces drawn inside it.
enum WindowMetrics {
    /// Corner radius used when the running system does not answer the probe.
    static let fallbackCornerRadius: CGFloat = 10

    /// Reads the radius the window rounds its own corners with, falling back to the standard value.
    ///
    /// Recent macOS releases no longer store the radius on the window layers, so the value comes
    /// from AppKit's own accessor, guarded by both method presence and a plausible range.
    static func cornerRadius(for window: NSWindow?) -> CGFloat {
        let radius = probe(window) ?? window?.contentView?.superview?.layer?.cornerRadius ?? 0
        return (8 ... 24).contains(radius) ? radius : fallbackCornerRadius
    }

    /// Calls AppKit's private corner-radius accessor when this system still exposes it.
    private static func probe(_ window: NSWindow?) -> CGFloat? {
        guard let window else { return nil }
        let selector = NSSelectorFromString("_cornerRadius")
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Double
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return CGFloat(getter(window, selector))
    }
}
