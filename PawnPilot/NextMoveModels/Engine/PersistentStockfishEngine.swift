import Foundation

public actor PersistentStockfishEngine: EngineAnalyzing {
    private let engineURL: URL?
    private let timeoutSeconds: Double?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var writer: FileHandle?
    private var reader: FileHandle?
    private var didHandshake = false

    public init(engineURL: URL?, timeoutSeconds: Double? = 300.0) {
        self.engineURL = engineURL
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
        guard let reader, let writer else { throw StockfishError.startFailed }

        return try await withTaskCancellationHandler {
            var latestLines: [Int: EngineLine] = [:]
            var stopSent = false
            let targetDepth = options.depth

            func send(_ command: String) {
                if let data = (command + "\n").data(using: .utf8) {
                    writer.write(data)
                }
            }

            func hasAllLinesAtDepth() -> Bool {
                guard let targetDepth else { return true }
                for idx in 1...max(1, options.multiPV) {
                    guard let line = latestLines[idx], line.depth >= targetDepth else {
                        return false
                    }
                }
                return true
            }

            send("setoption name Threads value \(options.threads)")
            send("setoption name Hash value \(options.hash)")
            send("setoption name MultiPV value \(options.multiPV)")
            if options.limitStrength {
                send("setoption name UCI_LimitStrength value true")
                send("setoption name UCI_Elo value \(options.elo)")
            } else {
                send("setoption name UCI_LimitStrength value false")
            }

            send("isready")
            try await readUntil("readyok", from: reader)
            send("position fen \(fen)")
            if let depth = options.depth {
                send("go depth \(depth)")
            } else if let moveTime = options.movetimeMs {
                send("go movetime \(moveTime)")
            } else {
                send("go depth 12")
            }

            for try await line in reader.bytes.lines {
                if let info = parseInfo(line: line) {
                    latestLines[info.multipv] = info
                }
                if requireFullDepth, targetDepth != nil, !stopSent, hasAllLinesAtDepth() {
                    send("stop")
                    stopSent = true
                }
                if line.hasPrefix("bestmove ") {
                    // `bestmove` marks end of this search; return best available lines even when
                    // strict depth could not fill every requested MultiPV slot.
                    break
                }
            }

            return latestLines.values.sorted { $0.multipv < $1.multipv }
        } onCancel: {
            Task { await shutdownProcess() }
        }
    }

    private func ensureProcess() async throws {
        if process == nil {
            try startProcess()
        }
        if !didHandshake {
            guard let reader, let writer else { throw StockfishError.startFailed }
            if let data = "uci\n".data(using: .utf8) {
                writer.write(data)
            }
            try await readUntil("uciok", from: reader)
            if let data = "isready\n".data(using: .utf8) {
                writer.write(data)
            }
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
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe

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
        self.writer = stdinPipe.fileHandleForWriting
        self.reader = stdoutPipe.fileHandleForReading
    }

    private func shutdownProcess() {
        if let writer {
            if let data = "quit\n".data(using: .utf8) {
                writer.write(data)
            }
            writer.closeFile()
        }
        reader?.readabilityHandler = nil
        reader?.closeFile()
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        writer = nil
        reader = nil
        didHandshake = false
    }

    private func readUntil(_ target: String, from reader: FileHandle) async throws {
        for try await line in reader.bytes.lines {
            if line == target { return }
        }
        throw StockfishError.startFailed
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
