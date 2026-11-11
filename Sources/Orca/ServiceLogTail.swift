// Follows the log file the service writes itself. The child inherits the write descriptor, so its
// output survives Orca quitting; this type owns the shell's copy, the reader that follows appended
// bytes, and the short tail kept for failure messages.

import Foundation

/// Tails `service.log` for the startup banner and keeps a short tail for crash reports.
///
/// Every mutable field is touched on `queue`: the reader runs from a timer while the controller
/// resets and reads that state from the main thread. The write descriptor is handed to the child
/// process, which is why the shell closing its own copies must not close the log for the service.
final class ServiceLogTail {
    /// Called on the main queue once the tokenized access URL appears in the log.
    var onAccessURL: ((URL) -> Void)?

    private let queue = DispatchQueue(label: "com.xu.orca.service-output")
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?
    private var timer: Timer?
    private var outputBuffer = ""
    private var recentLines: [String] = []
    private var didDiscoverAccessURL = false

    /// How often the shell looks for bytes the service appended.
    private static let pollInterval: TimeInterval = 0.05
    /// Rotation happens only here, before a child inherits the descriptor.
    private static let rotationLimit = 4_000_000
    private static let recentLineLimit = 80
    private static let bufferLimit = 200_000
    private static let bufferTrimmedTo = 100_000
    /// Compiled once. Building an `NSRegularExpression` costs more than running it, and this one
    /// ran on every chunk the child printed until the banner appeared.
    private static let accessURLPattern = try? NSRegularExpression(pattern: #"dsh web:\s+(http://\S+)"#)

    deinit {
        timer?.invalidate()
    }

    /// Opens the log and starts following it.
    /// - Returns: the append-only descriptor the child inherits as stdout and stderr.
    func open() -> FileHandle? {
        timer?.invalidate()
        timer = nil
        let writable = queue.sync { () -> FileHandle? in
            self.closeHandles()
            guard let handle = LogFile.openAppendOnly(
                AppPaths.serviceLog,
                rotatingBeyond: Self.rotationLimit
            ) else {
                return nil
            }
            self.writeHandle = handle
            LogFile.append(Data("\n==== Orca launch \(LogFile.stamp()) ====\n".utf8), to: handle)
            // The banner belongs to the *new* process; anything before this offset is history.
            let offset = handle.offsetInFile
            self.readHandle = try? FileHandle(forReadingFrom: AppPaths.serviceLog)
            try? self.readHandle?.seek(toOffset: offset)
            return handle
        }
        guard let writable else { return nil }
        let poller = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.drain()
        }
        // `.common`: startup must keep reading while a menu is open or the window is being dragged.
        RunLoop.main.add(poller, forMode: .common)
        timer = poller
        return writable
    }

    /// Closes the shell's own descriptors. The child's copies are unaffected, which is exactly why
    /// a kept-alive service keeps writing after Orca is gone.
    func close() {
        timer?.invalidate()
        timer = nil
        queue.async { [weak self] in self?.closeHandles() }
    }

    /// Clears what the previous child printed, on the queue that owns it.
    func reset() {
        queue.async { [weak self] in
            self?.outputBuffer.removeAll(keepingCapacity: true)
            self?.recentLines.removeAll(keepingCapacity: true)
            self?.didDiscoverAccessURL = false
        }
    }

    /// A copy of the last lines captured, read on the queue that owns them.
    func capturedLines() -> [String] {
        queue.sync { recentLines }
    }

    /// Appends one Orca note to the log without rotating it: a kept-alive service may still hold
    /// the descriptor, and rotating under it would split the log between two inodes.
    ///
    /// Static because a note opens and closes its own descriptor; it never touches the tail state.
    /// - Parameter line: the note to record, already phrased for a reader.
    static func note(_ line: String) {
        let handle = LogFile.openAppendOnly(AppPaths.serviceLog)
        LogFile.append(Data("[orca] \(line)\n".utf8), to: handle)
        try? handle?.close()
    }

    /// Closes both descriptors; must run on `queue`.
    private func closeHandles() {
        try? readHandle?.close()
        readHandle = nil
        try? writeHandle?.close()
        writeHandle = nil
    }

    /// Reads bytes appended since the last tick, on the queue that owns the captured output.
    private func drain() {
        queue.async { [weak self] in
            guard let self, let handle = self.readHandle else { return }
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty else { return }
            self.parse(data)
        }
    }

    /// Parses one chunk the service appended: keeps the tail, looks for the banner.
    private func parse(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            recentLines.append(String(line))
        }
        if recentLines.count > Self.recentLineLimit {
            recentLines.removeFirst(recentLines.count - Self.recentLineLimit)
        }
        // Past the banner, `outputBuffer` exists only to be searched for it. Concatenating every
        // later chunk onto a buffer that grows to 200 KB, then running the pattern over the whole
        // of it, was work done for the entire life of the service rather than for its startup.
        // `recentLines` above is what a crash still reads, so the tail stays useful.
        guard !didDiscoverAccessURL else { return }
        outputBuffer += text
        if outputBuffer.count > Self.bufferLimit {
            outputBuffer = String(outputBuffer.suffix(Self.bufferTrimmedTo))
        }
        guard let url = Self.parseAccessURL(in: outputBuffer) else { return }
        didDiscoverAccessURL = true
        DispatchQueue.main.async { [weak self] in
            self?.onAccessURL?(url)
        }
    }

    /// Pulls the tokenized access URL out of the server banner (`dsh web: http://…`).
    private static func parseAccessURL(in text: String) -> URL? {
        guard let regex = accessURLPattern,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return URL(string: String(text[range]))
    }
}
