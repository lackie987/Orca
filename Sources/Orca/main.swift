import AppKit

// Single-window AppKit shell; there is no nib, so the delegate builds every surface in code.
// The launch clock starts here, before any surface exists, so the log accounts for the app's own
// startup and not only for what happens once the window is up.
LaunchTrace.begin()

// The service comes before AppKit does.
//
// The two longest stages of a start belong to something other than this process: the child's own
// boot (`dsh web` plus its plugins, 7-9 s on this machine when one has to be started) and, on a
// launch that adopts the service the previous one left running, the health probe against it. Both
// are waits, not work, so starting the chain before `NSApplication` initialises puts the whole
// native prelude — dyld, AppKit, the window, the splash, the menu — on top of that wait instead of
// in front of it. The service chain is Foundation only for exactly this reason.
let service = ServiceController(preferences: Preferences.shared)
service.start()

let application = NSApplication.shared
let delegate = AppDelegate(service: service)
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
