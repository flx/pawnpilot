import Darwin
import Foundation

/// One long-lived Stockfish child, driven one search at a time.
///
/// Three invariants carry the design (`plans/…/persistent-engine-serialize-searches.plan.md`):
///
/// - **One child, one iterator.** `Child.lines` is made once in `startChild()` and
///   is the only iterator over that child's stdout for its whole life. Opening a
///   second `bytes.lines` would strand whatever the first had already buffered.
/// - **One search at a time.** A caller takes the slot (`acquireSlot`) before it
///   writes a single byte to the child and holds it until its search is over, so
///   two searches can never interleave on the one pipe.
/// - **Every teardown is generation-keyed.** A late timeout or a late error names
///   the child it belongs to, so it can never kill a child started by a later call.
///
/// Aborting is task cancellation, not a `stop()` method: cancellation is
/// ticket-keyed, so a stale abort cannot truncate a newer search.
public actor PersistentStockfishEngine: EngineAnalyzing {

    /// One spawned child and everything owned by it. Replaced wholesale on restart;
    /// `generation` is what every teardown path keys on.
    private nonisolated struct Child {
        let generation: Int
        let process: Process
        let writer: EngineStdinWriter
        let reader: FileHandle
        /// The ONE iterator over this child's stdout, for the child's whole life.
        var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
        var handshaken = false
        /// Set by `terminationHandler` (pid-keyed) or by `killChild`.
        var exited = false
        /// `killChild` closed the read end; `teardown` must not close it twice and
        /// `nextLine` must not write a stale iterator back.
        var readerClosed = false
    }

    private nonisolated enum Phase {
        case preparing
        case searching
        case finished
    }

    /// The ticket that currently holds the slot, plus the signals latched for it.
    /// Signals are latched rather than acted on immediately so that a cancel or a
    /// timeout arriving in any phase is honoured at the next checkpoint instead of
    /// being dropped.
    private nonisolated struct Running {
        let ticket: Int
        var phase: Phase = .preparing
        /// The child generation this ticket uses. Written by `ensureChild` before
        /// any await, so `timeOut` kills exactly the child in use — and never a
        /// healthy child left behind by the previous search.
        var generation: Int?
        var timedOut = false
        var cancelRequested = false
    }

    private let engineURL: URL?
    private let arguments: [String]
    private let timeoutSeconds: Double?

    private var child: Child?
    private var generationCounter = 0

    /// Monotonic and never reused: a signal for a ticket that is neither waiting
    /// nor running is a no-op.
    private var nextTicket = 0
    private var running: Running?
    private var waiters: [(ticket: Int, continuation: CheckedContinuation<Void, Error>)] = []

    /// - Parameter arguments: passed to the child verbatim. Empty for Stockfish; the tests
    ///   use it to run a scripted fake through `/bin/sh` (the sandboxed test host cannot
    ///   exec a script file written into its own container).
    public init(engineURL: URL?, arguments: [String] = [], timeoutSeconds: Double? = 300.0) {
        self.engineURL = engineURL
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }

    /// `Process` retains itself while its child runs, so dropping the actor would
    /// otherwise leave an orphaned Stockfish holding the pipe open for the rest of
    /// the process's life (the tests would leak one child per actor). Closing the
    /// child's stdin is EOF to it; nothing is written (no `quit`), so a child that
    /// is mid-search on a diverted stdout cannot append anything anywhere.
    deinit {
        guard let current = child else { return }
        current.writer.close()
        if !current.readerClosed {
            try? current.reader.close()
        }
        if current.process.isRunning {
            current.process.terminate()
        }
    }

    // MARK: - Public entry point

    public func analyze(
        fen: String,
        options: EngineOptions,
        requireFullDepth: Bool = true
    ) async throws -> [EngineLine] {
        guard engineURL != nil else { throw StockfishError.notFound }

        let ticket = nextTicket
        nextTicket += 1

        // The clock runs from entry and covers queue wait, restart, handshake and
        // search. It is unstructured, so the caller's cancellation does not stop it;
        // the `defer` does.
        let clock: Task<Void, Never>? = timeoutSeconds.map { seconds in
            let nanoseconds = Self.nanoseconds(from: seconds)
            return Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return          // cancelled: this call already finished
                }
                await self?.timeOut(ticket: ticket)
            }
        }
        defer { clock?.cancel() }

        return try await withTaskCancellationHandler {
            try await acquireSlot(ticket: ticket)
            defer { releaseSlot(ticket: ticket) }
            // Cancelled while taking the slot (idle path, or promoted from the queue
            // before its `onCancel` hop ran): nothing has been sent for this ticket yet.
            try Task.checkCancellation()
            // Unstructured and actor-isolated: the caller's cancellation never
            // interrupts it, so a cancelled search still drains to `bestmove`
            // and leaves the child aligned.
            let search = Task { [self] in
                try await self.performSearch(
                    ticket: ticket,
                    fen: fen,
                    options: options,
                    requireFullDepth: requireFullDepth
                )
            }
            let lines = try await search.value
            // Cancelled after `stop` (or during the drain): the child is alive and
            // aligned, and the caller gets `CancellationError`, never partial lines.
            try Task.checkCancellation()
            return lines
        } onCancel: {
            Task { [weak self] in await self?.cancel(ticket: ticket) }
        }
    }

    // MARK: - The slot: one search at a time, FIFO

    /// Takes the slot, or queues until the running search releases it. Throws
    /// `CancellationError` if the caller was already cancelled, and `.timeout` if
    /// the clock fires while queued.
    private func acquireSlot(ticket: Int) async throws {
        if running == nil {
            running = Running(ticket: ticket)
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Runs synchronously on the actor before the suspension, so an
            // `onCancel` that fired before this waiter existed cannot strand it.
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters.append((ticket: ticket, continuation: continuation))
        }
    }

    /// Hands the slot to the next waiter in one synchronous actor step, so no third
    /// caller can slip in between the release and the promotion.
    private func releaseSlot(ticket: Int) {
        guard running?.ticket == ticket else { return }
        running = nil
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        running = Running(ticket: next.ticket)
        next.continuation.resume()
    }

    /// The caller's task was cancelled. A queued ticket is dropped; a running one
    /// gets `stop` if it is already searching, and in every case latches the
    /// request for the next checkpoint.
    private func cancel(ticket: Int) {
        if let index = waiters.firstIndex(where: { $0.ticket == ticket }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        guard let current = running, current.ticket == ticket else { return }
        running?.cancelRequested = true
        // Keyed like every other write: only the child this ticket is searching on.
        if current.phase == .searching, let generation = current.generation, child?.generation == generation {
            try? send("stop")
        }
    }

    /// The clock fired. A queued ticket is dropped with `.timeout`; a running one
    /// latches `timedOut` and kills the child it is using — a ticket that has not
    /// chosen a child yet kills nothing. A ticket already `.finished` is left
    /// alone: its lines are returned and its child lives on.
    private func timeOut(ticket: Int) {
        if let index = waiters.firstIndex(where: { $0.ticket == ticket }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: StockfishError.timeout)
            return
        }
        guard let current = running, current.ticket == ticket, current.phase != .finished else { return }
        running?.timedOut = true
        if let generation = current.generation {
            killChild(generation: generation)
        }
    }

    /// The three checkpoints of `performSearch` funnel through here. Precedence is
    /// total: timeout beats cancellation.
    private func checkSignals(ticket: Int) throws {
        guard let current = running, current.ticket == ticket else { throw StockfishError.engineGone }
        if current.timedOut { throw StockfishError.timeout }
        if current.cancelRequested { throw CancellationError() }
    }

    // MARK: - The search

    /// Runs inside the unstructured task created by `analyze`, and only while this
    /// ticket holds the slot.
    private func performSearch(
        ticket: Int,
        fen: String,
        options: EngineOptions,
        requireFullDepth: Bool
    ) async throws -> [EngineLine] {
        var searchGeneration: Int?
        do {
            // (1) Timed out or cancelled while queued and then promoted: start nothing.
            try checkSignals(ticket: ticket)

            // Inside the `do` on purpose: a timeout during the handshake must map
            // to `.timeout`, not to `startFailed`.
            let generation = try await ensureChild(for: ticket)
            searchGeneration = generation

            // (2) After the handshake.
            try checkSignals(ticket: ticket)

            try send("setoption name Threads value \(options.threads)")
            try send("setoption name Hash value \(options.hash)")
            try send("setoption name MultiPV value \(options.multiPV)")
            if options.limitStrength {
                try send("setoption name UCI_LimitStrength value true")
                try send("setoption name UCI_Elo value \(options.elo)")
            } else {
                try send("setoption name UCI_LimitStrength value false")
            }
            try send("isready")
            // Everything the previous search left in the pipe (a stale `info` line
            // printed after its `bestmove`) is discarded here.
            try await drain(until: "readyok", generation: generation)

            // (3) The stream is aligned at `readyok`; a cancel latched during
            // preparation throws HERE, before `go`. The child has seen only
            // `setoption`s and one answered `isready`, so it is idle and aligned.
            try checkSignals(ticket: ticket)

            var latestLines: [Int: EngineLine] = [:]
            var stopSent = false
            var sawBestmove = false
            let targetDepth = options.depth

            func hasAllLinesAtDepth() -> Bool {
                guard let targetDepth else { return true }
                for idx in 1...max(1, options.multiPV) {
                    guard let line = latestLines[idx], line.depth >= targetDepth else {
                        return false
                    }
                }
                return true
            }

            try send("position fen \(fen)")
            if let depth = options.depth {
                try send("go depth \(depth)")
            } else if let moveTime = options.movetimeMs {
                try send("go movetime \(moveTime)")
            } else {
                try send("go depth 12")
            }
            setPhase(.searching, ticket: ticket)

            while let line = await nextLine(generation: generation) {
                if let info = parseInfo(line: line) {
                    latestLines[info.multipv] = info
                }
                if requireFullDepth, targetDepth != nil, !stopSent, hasAllLinesAtDepth() {
                    try send("stop")
                    stopSent = true
                }
                if line.hasPrefix("bestmove ") {
                    // `bestmove` marks end of this search; return best available lines even when
                    // strict depth could not fill every requested MultiPV slot.
                    sawBestmove = true
                    break
                }
            }
            setPhase(.finished, ticket: ticket)

            guard sawBestmove else {
                // The loop ended on EOF, not on `bestmove`: the child died mid-search.
                throw StockfishError.engineGone
            }
            return latestLines.values.sorted { $0.multipv < $1.multipv }
        } catch {
            setPhase(.finished, ticket: ticket)
            // Precedence: a latched timeout beats every other outcome.
            if let current = running, current.ticket == ticket, current.timedOut {
                if let searchGeneration {
                    teardown(generation: searchGeneration)
                }
                throw StockfishError.timeout
            }
            if error is CancellationError {
                // Thrown only at a checkpoint: the child is alive and aligned.
                throw error
            }
            if error is StockfishError, let searchGeneration {
                // `engineGone` from this search; a handshake failure tore its own
                // generation down already and left `searchGeneration` nil.
                teardown(generation: searchGeneration)
            }
            throw error
        }
    }

    /// Reads lines until `target`. `nil` (EOF, or a closed/replaced child) is
    /// `engineGone`; `ensureChild` maps that to `startFailed` for the handshake.
    private func drain(until target: String, generation: Int) async throws {
        while let line = await nextLine(generation: generation) {
            if line == target { return }
        }
        throw StockfishError.engineGone
    }

    // MARK: - The child

    /// Returns the generation of a live, handshaken child, starting one if needed.
    private func ensureChild(for ticket: Int) async throws -> Int {
        if let current = child, current.exited || current.readerClosed || !current.process.isRunning {
            teardown(generation: current.generation)     // dead child: tear down so we start fresh
        }
        if child == nil {
            _ = try startChild()
        }
        guard let current = child else { throw StockfishError.startFailed }
        let generation = current.generation
        // Recorded BEFORE any await, so a timeout kills exactly this child.
        if running?.ticket == ticket {
            running?.generation = generation
        }

        if !current.handshaken {
            do {
                try send("uci")
                try await drain(until: "uciok", generation: generation)
                try send("isready")
                try await drain(until: "readyok", generation: generation)
            } catch {
                teardown(generation: generation)
                // `performSearch`'s catch maps this to `.timeout` when the ticket
                // was timed out; otherwise the child never came up.
                throw StockfishError.startFailed
            }
            if child?.generation == generation {
                child?.handshaken = true
            }
        }
        return generation
    }

    /// Spawns a child and installs it as the current one. Returns its generation.
    private func startChild() throws -> Int {
        guard let engineURL else { throw StockfishError.notFound }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        process.executableURL = engineURL
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe

        // Constructed before `run()`: the fd is flagged `F_SETNOSIGPIPE` before the
        // child can ever exit.
        let writer = EngineStdinWriter(handle: stdinPipe.fileHandleForWriting)

        process.terminationHandler = { [weak self] exited in
            let pid = exited.processIdentifier
            Task { await self?.childDidExit(pid: pid) }
        }

        do {
            try process.run()
        } catch {
            throw StockfishError.startFailed
        }

        stdinPipe.fileHandleForReading.closeFile()
        stdoutPipe.fileHandleForWriting.closeFile()

        generationCounter += 1
        let generation = generationCounter
        let reader = stdoutPipe.fileHandleForReading
        child = Child(
            generation: generation,
            process: process,
            writer: writer,
            reader: reader,
            lines: reader.bytes.lines.makeAsyncIterator()
        )
        return generation
    }

    /// The ONLY place `next()` is called on the child's iterator: the iterator is
    /// copied out, advanced, and copied back, and the copy-back is skipped when the
    /// child has been replaced or its read end closed underneath us.
    private func nextLine(generation: Int) async -> String? {
        guard let current = child, current.generation == generation, !current.readerClosed else { return nil }
        var iterator = current.lines
        let line: String?
        do {
            line = try await iterator.next()
        } catch {
            line = nil          // a closed descriptor reads as EOF
        }
        guard let still = child, still.generation == generation, !still.readerClosed else {
            // `killChild` ran while we were suspended (or the child was replaced): a
            // line that was already buffered must not let a timed-out search finish
            // as a success — it reads as EOF, and the catch maps it to `.timeout`.
            return nil
        }
        child?.lines = iterator
        if line == nil {
            // A pipe reads EOF only once every write end is closed: this child
            // will never speak again, so nothing may write to its stdin either
            // (CLAUDE.md § Standing constraints).
            still.writer.markGone()
        }
        return line
    }

    /// Called from `process.terminationHandler`; compares by pid (not object
    /// identity — `Process` is not `Sendable`) so a stale callback from an
    /// already-replaced child is a no-op.
    private func childDidExit(pid: Int32) {
        guard let current = child, current.process.processIdentifier == pid else { return }
        child?.exited = true
        current.writer.markGone()
    }

    /// Orderly shutdown of one generation. Idempotent: a generation that is no
    /// longer current is a no-op.
    private func teardown(generation: Int) {
        guard let current = child, current.generation == generation else { return }
        current.writer.send("quit")     // a no-op once the writer is gone
        current.writer.close()
        if !current.readerClosed {
            try? current.reader.close()
        }
        if current.process.isRunning {
            current.process.terminate()
        }
        child = nil
    }

    /// The timeout's escape hatch. Closing the read end guarantees a blocked
    /// `next()` returns even if a grandchild still holds the write end; SIGKILL
    /// guarantees the child itself is gone; `exited` + `readerClosed` guarantee
    /// `ensureChild` never reuses it and `nextLine` never writes a stale iterator
    /// back. The `Child` is kept (not cleared) so the search that owns it can tell
    /// its generation apart in its own teardown.
    private func killChild(generation: Int) {
        guard let current = child, current.generation == generation, !current.readerClosed else { return }
        if current.process.isRunning {
            _ = kill(current.process.processIdentifier, SIGKILL)
        }
        current.writer.markGone()
        try? current.reader.close()
        child?.readerClosed = true
        child?.exited = true
    }

    /// Every write from a search goes through here (`teardown` writes its `quit`
    /// on the writer directly); a dead child throws instead of writing to a
    /// closed pipe.
    private func send(_ command: String) throws {
        guard let writer = child?.writer, writer.send(command) else { throw StockfishError.engineGone }
    }

    private func setPhase(_ phase: Phase, ticket: Int) {
        guard running?.ticket == ticket else { return }
        running?.phase = phase
    }

    /// Saturating: a non-positive or non-finite timeout fires immediately and one
    /// too large for `UInt64` clamps, rather than trapping in the conversion.
    private nonisolated static func nanoseconds(from seconds: Double) -> UInt64 {
        let scaled = seconds * 1_000_000_000
        guard scaled > 0 else { return 0 }
        guard scaled < Double(UInt64.max) else { return .max }
        return UInt64(scaled)
    }

    // for tests
    func childProcessIdentifierForTesting() -> Int32? {
        child?.process.processIdentifier
    }

    // for tests
    func isChildRunningForTesting() -> Bool {
        child?.process.isRunning ?? false
    }

    private func parseInfo(line: String) -> EngineLine? {
        let parts = line.split(separator: " ")
        guard parts.contains(where: { $0 == "pv" }) else { return nil }

        var multipv = 1
        var depth = 0
        var nodes: Int?
        var nps: Int?
        var score: EngineScore?

        for (index, token) in parts.enumerated() {
            switch token {
            case "multipv":
                if let v = parts[safe: index + 1], let int = Int(v) { multipv = int }
            case "depth":
                if let v = parts[safe: index + 1], let int = Int(v) { depth = int }
            case "nodes":
                if let v = parts[safe: index + 1], let int = Int(v) { nodes = int }
            case "nps":
                if let v = parts[safe: index + 1], let int = Int(v) { nps = int }
            case "score":
                if let type = parts[safe: index + 1] {
                    if type == "cp", let val = parts[safe: index + 2], let int = Int(val) {
                        score = .cp(int)
                    } else if type == "mate", let val = parts[safe: index + 2], let int = Int(val) {
                        score = .mate(int)
                    }
                }
            default:
                continue
            }
        }

        guard let score else { return nil }

        guard let pvIndex = parts.firstIndex(of: "pv") else { return nil }
        let moveTokens = parts[(pvIndex + 1)...]
        let moves = moveTokens.map { String($0) }.filter { !$0.isEmpty }

        return EngineLine(
            multipv: multipv,
            score: score,
            depth: depth,
            nodes: nodes,
            nps: nps,
            moves: moves
        )
    }
}

private extension Array where Element == Substring {
    nonisolated subscript(safe index: Int) -> Substring? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
