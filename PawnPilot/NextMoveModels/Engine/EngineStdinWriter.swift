import Foundation

/// Owns the write end of a child's stdin pipe. After the first failed write
/// (EPIPE: the child is gone), after `markGone()`, or after `close()`, every
/// further `send` is a no-op returning `false`. Never raises SIGPIPE: the
/// descriptor is flagged `F_SETNOSIGPIPE` (local to this fd — no global
/// `signal()` handler). Never raises an ObjC exception: uses the throwing
/// `write(contentsOf:)`.
nonisolated final class EngineStdinWriter {
    private let handle: FileHandle
    private(set) var isGone = false
    private var isClosed = false

    init(handle: FileHandle) {
        self.handle = handle
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Writes `command` + "\n". Returns `false` if the engine is gone.
    @discardableResult
    func send(_ command: String) -> Bool {
        guard !isGone, !isClosed, let data = (command + "\n").data(using: .utf8) else { return false }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            isGone = true       // EPIPE or any other write failure: treat as gone
            return false
        }
    }

    /// The reader saw EOF or the child was observed to exit.
    func markGone() { isGone = true }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }
}
