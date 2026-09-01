import Foundation

public actor PersistentStockfishEngine: EngineAnalyzing {
    private let engineURL: URL?
    private let arguments: [String]
    private let timeoutSeconds: Double?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var writer: EngineStdinWriter?
    private var reader: FileHandle?
    private var didHandshake = false
    private var childExited = false

    /// - Parameter arguments: passed to the child verbatim. Empty for Stockfish; the tests
    ///   use it to run a scripted fake through `/bin/sh` (the sandboxed test host cannot
    ///   exec a script file written into its own container).
    public init(engineURL: URL?, arguments: [String] = [], timeoutSeconds: Double? = 300.0) {
        self.engineURL = engineURL
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }

    public func analyze(
        fen: String,
        options: EngineOptions,
        requireFullDepth: Bool = true
    ) async throws -> [EngineLine] {
        guard engineURL != nil else { throw StockfishError.notFound }
        do {
            if let timeoutSeconds {
                return try await withThrowingTaskGroup(of: [EngineLine].self) { group in
                    group.addTask { [self] in
                        try await runSearch(fen: fen, options: options, requireFullDepth: requireFullDepth)
                    }
                    group.addTask { [timeoutSeconds] in
                        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                        throw StockfishError.timeout
                    }
                    guard let result = try await group.next() else {
                        throw StockfishError.startFailed
                    }
                    group.cancelAll()
                    return result
                }
            } else {
                return try await runSearch(fen: fen, options: options, requireFullDepth: requireFullDepth)
            }
        } catch {
            shutdownProcess()
            throw error
        }
    }

    private func runSearch(
        fen: String,
        options: EngineOptions,
        requireFullDepth: Bool
    ) async throws -> [EngineLine] {
        try await ensureProcess()
        guard let reader else { throw StockfishError.startFailed }

        return try await withTaskCancellationHandler {
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
            try await readUntil("readyok", from: reader)
            try send("position fen \(fen)")
            if let depth = options.depth {
                try send("go depth \(depth)")
            } else if let moveTime = options.movetimeMs {
                try send("go movetime \(moveTime)")
            } else {
                try send("go depth 12")
            }

            for try await line in reader.bytes.lines {
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

            if !sawBestmove {
                // The loop ended on EOF, not on `bestmove`: the child died mid-search.
                // `analyze`'s catch tears the process down. Nothing here may touch actor
                // state: by now `writer`/`process` can belong to a replacement child started
                // after a cancellation tore this one down (review finding, 2026-09-01).
                throw StockfishError.engineGone
            }

            return latestLines.values.sorted { $0.multipv < $1.multipv }
        } onCancel: {
            Task { await shutdownProcess() }
        }
    }

    private func ensureProcess() async throws {
        if let process, childExited || !process.isRunning {
            shutdownProcess()          // dead child: tear down so we start fresh
        }
        if process == nil {
            try startProcess()
        }
        if !didHandshake {
            guard let reader else { throw StockfishError.startFailed }
            try send("uci")
            try await readUntil("uciok", from: reader)
            try send("isready")
            try await readUntil("readyok", from: reader)
            didHandshake = true
        }
    }

    private func startProcess() throws {
        guard let engineURL else { throw StockfishError.notFound }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        process.executableURL = engineURL
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe

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

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.writer = writer
        self.reader = stdoutPipe.fileHandleForReading
        self.childExited = false
    }

    /// Called from `process.terminationHandler`; compares by pid (not object
    /// identity — `Process` is not `Sendable`) so a stale callback from an
    /// already-replaced child is a no-op.
    private func childDidExit(pid: Int32) {
        guard process?.processIdentifier == pid else { return }
        childExited = true
        writer?.markGone()
    }

    private func shutdownProcess() {
        writer?.send("quit")
        writer?.close()
        reader?.closeFile()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        writer = nil
        reader = nil
        didHandshake = false
        childExited = false
    }

    /// Every write to the child's stdin goes through here; a dead child
    /// throws instead of writing to a closed pipe.
    private func send(_ command: String) throws {
        guard let writer, writer.send(command) else { throw StockfishError.engineGone }
    }

    private func readUntil(_ target: String, from reader: FileHandle) async throws {
        for try await line in reader.bytes.lines {
            if line == target { return }
        }
        throw StockfishError.startFailed
    }

    // for tests
    func childProcessIdentifierForTesting() -> Int32? {
        process?.processIdentifier
    }

    // for tests
    func isChildRunningForTesting() -> Bool {
        process?.isRunning ?? false
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
