import AppKit
import Darwin

/// Keeps the installed bundle's code signature valid after the app rewrites its own icon.
///
/// `Contents/Resources/AppIcon.icns` is a sealed resource: `build.sh` signs the bundle after
/// assembling it, so a runtime write leaves `codesign --verify` failing with
/// `file modified: …/AppIcon.icns`. Leaving the app on disk in that state is not acceptable — macOS
/// validates the bundle again on later launches, and anything keyed to the code identity reads a
/// signature that no longer describes the bytes. A sealed resource cannot be changed and stay
/// sealed, so a write is followed by a fresh ad-hoc signature that keeps the identifier, the
/// entitlements and the stable designated requirement `build.sh` uses — that requirement is what
/// makes TCC grants survive rebuilds, so letting it fall back to the cdhash would re-ask for
/// permissions on every icon change.
///
/// Signing is coalesced because dragging a colour well writes the icon repeatedly and only the last
/// state needs a seal, and it runs off the main thread because `codesign` takes long enough to stall
/// the page's replies. A quit flushes whatever is still outstanding, so leaving right after a colour
/// change does not strand the bundle sealed against the previous icon.
enum AppBundleSeal {
    /// Quiet period after the last icon write before the bundle is signed again.
    private static let quietPeriod: TimeInterval = 0.9

    /// Signing runs one at a time; a flush waits for the run in flight instead of racing it.
    private static let queue = DispatchQueue(label: "com.xu.orca.app-seal")

    /// The debounced sign, if one is waiting. Main thread only.
    private static var pending: DispatchWorkItem?

    /// Counter that marks an icon write as newer than the last completed signature. Main thread
    /// only; every bump is one change that still owes a seal.
    private static var writes = 0

    /// Bumped on every write; a run that finishes with the same value leaves nothing outstanding.
    private static var sealed = 0

    /// Queues a signature for `appPath` once the icon writes have settled.
    static func schedule(for appPath: String) {
        writes += 1
        let mark = writes
        pending?.cancel()
        let work = DispatchWorkItem {
            queue.async {
                let ok = runCodesign(appPath)
                DispatchQueue.main.async {
                    if ok { sealed = max(sealed, mark) }
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }

    /// Applies an outstanding signature off the main thread, then calls back on the main queue.
    ///
    /// The synchronous variant below parked the caller on `queue.sync` for the whole `codesign` run,
    /// with no timeout of its own: quitting right after an icon change froze the app and could be
    /// killed by the system's termination watchdog mid-signature, which leaves the bundle half-sealed
    /// and unlaunchable. This returns immediately and answers when the seal is done.
    /// - Parameters:
    ///   - appPath: the bundle whose resources changed.
    ///   - completion: called on the main queue once the signature is applied or given up on.
    static func flush(for appPath: String, completion: @escaping () -> Void) {
        pending?.cancel()
        pending = nil
        guard sealed < writes else {
            completion()
            return
        }
        let mark = writes
        queue.async {
            let ok = runCodesign(appPath)
            DispatchQueue.main.async {
                if ok { sealed = max(sealed, mark) }
                completion()
            }
        }
    }

    /// Applies an outstanding signature before the process goes away.
    ///
    /// Disabled in favour of the asynchronous form above: it blocks its caller for the whole run.
    /// Kept for a caller that genuinely cannot continue until the bundle is sealed, which the app's
    /// termination path is not — it answers `.terminateLater` instead.
    //
    // static func flush(for appPath: String) {
    //     pending?.cancel()
    //     pending = nil
    //     guard sealed < writes else { return }
    //     queue.sync { _ = runCodesign(appPath) }
    //     sealed = writes
    // }

    /// Re-signs the bundle ad-hoc, mirroring the identity `build.sh` applies.
    ///
    /// `codesign` refuses a bundle that carries Finder information (`resource fork, Finder
    /// information, or similar detritus not allowed`). That record came from
    /// `NSWorkspace.setIcon`, which is no longer used: the icon now lives in the bundle's sealed
    /// `AppIcon.icns`, which is the file Finder and the next launch read anyway. Bundles written by
    /// older builds can still carry the record, so it is cleared here rather than assumed absent.
    private static func runCodesign(_ appPath: String) -> Bool {
        removexattr(appPath, "com.apple.FinderInfo", 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--force",
            "--sign", "-",
            "--identifier", "com.xu.orca",
            "--preserve-metadata=entitlements",
            "-r=designated => identifier \"com.xu.orca\"",
            appPath,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("[Orca] cannot start codesign for %@: %@", appPath, error.localizedDescription)
            return false
        }
        // Bounded wait: `waitUntilExit()` has no timeout, and a stuck codesign must not hold a quit
        // open indefinitely. Thirty seconds is far past a normal re-seal of this bundle's size.
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            NSLog("[Orca] codesign timed out for %@", appPath)
            process.terminate()
            return false
        }
        if process.terminationStatus != 0 {
            NSLog("[Orca] codesign exited %d for %@", process.terminationStatus, appPath)
            return false
        }
        return true
    }
}
