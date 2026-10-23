import AppKit

// Single-window AppKit shell; there is no nib, so the delegate builds every surface in code.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
