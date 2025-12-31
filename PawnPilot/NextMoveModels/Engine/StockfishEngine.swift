import Foundation

public enum StockfishError: Error, LocalizedError {
    case notFound
    case startFailed
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return String(localized: "Stockfish engine not found in app bundle.")
        case .startFailed:
            return String(localized: "Stockfish failed to launch.")
        case .timeout:
            return String(localized: "Engine timed out while searching.")
        }
    }
}

public final class StockfishEngine: EngineAnalyzing, @unchecked Sendable {
    private let engineURL: URL?
    private let timeoutSeconds: Double?

    public init(engineURL: URL?, timeoutSeconds: Double? = 300.0) {
        self.engineURL = engineURL
        self.timeoutSeconds = timeoutSeconds
    }

    /// Run a single search and return parsed multi-PV lines.
    public func analyze(fen: String, options: EngineOptions, requireFullDepth: Bool = true) async throws -> [EngineLine] {
        guard let engineURL else { throw StockfishError.notFound }

        return try await runEngine(
            url: engineURL,
            fen: fen,
            options: options,
            requireFullDepth: requireFullDepth,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func runEngine(
        url: URL,
        fen: String,
        options: EngineOptions,
        requireFullDepth: Bool,
        timeoutSeconds: Double?
    ) async throws -> [EngineLine] {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        process.executableURL = url
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

        let writer = stdinPipe.fileHandleForWriting
        func send(_ command: String) {
            if let data = (command + "\n").data(using: .utf8) {
                writer.write(data)
            }
        }

        var latestLines: [Int: EngineLine] = [:]
        var gotUciOK = false
        var readySent = false
        var stopSent = false
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

        let reader = stdoutPipe.fileHandleForReading
        defer {
            send("quit")
            writer.closeFile()
            reader.readabilityHandler = nil
            process.terminate()
        }

        let timeoutBox = TimeoutBox()
        let timeoutTask: Task<Void, Never>? = {
            guard let timeoutSeconds else { return nil }
            return Task { [timeoutSeconds] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await timeoutBox.fire()
                process.terminate()
            }
        }()
        defer { timeoutTask?.cancel() }

        send("uci")

        for try await line in reader.bytes.lines {
            if await timeoutBox.isFired() {
                throw StockfishError.timeout
            }

            if line == "uciok" {
                gotUciOK = true
                apply(options: options, send: send)
                send("isready")
            } else if line == "readyok" && gotUciOK && !readySent {
                readySent = true
                send("position fen \(fen)")
                if let depth = options.depth {
                    send("go depth \(depth)")
                } else if let moveTime = options.movetimeMs {
                    send("go movetime \(moveTime)")
                } else {
                    send("go depth 12")
                }
            } else if line.hasPrefix("info ") {
                if let info = parseInfo(line: line) {
                    latestLines[info.multipv] = info
                }
                if requireFullDepth, targetDepth != nil, !stopSent, hasAllLinesAtDepth() {
                    send("stop")
                    stopSent = true
                }
            } else if line.hasPrefix("bestmove ") {
                if !requireFullDepth || hasAllLinesAtDepth() {
                    break
                }
            }
        }

        if await timeoutBox.isFired() {
            throw StockfishError.timeout
        }

        let lines = latestLines.values.sorted { $0.multipv < $1.multipv }
        return lines
    }

    private func apply(options: EngineOptions, send: (String) -> Void) {
        send("setoption name Threads value \(options.threads)")
        send("setoption name Hash value \(options.hash)")
        send("setoption name MultiPV value \(options.multiPV)")
        if options.limitStrength {
            send("setoption name UCI_LimitStrength value true")
            send("setoption name UCI_Elo value \(options.elo)")
        } else {
            send("setoption name UCI_LimitStrength value false")
        }
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

        // Extract PV moves after "pv"
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

    private actor TimeoutBox {
        private var fired = false

        func fire() {
            fired = true
        }

        func isFired() -> Bool {
            fired
        }
    }
}

public struct EngineMoveSelector {
    public init() {}

    /// Choose a line according to strength (1 = best only; higher = random among top N, capped at 5) while avoiding large eval drops.
    public func pickLine(from lines: [EngineLine], strength: Int, maxDropCentipawns: Int = 200) -> EngineLine? {
        guard !lines.isEmpty else { return nil }
        let cappedStrength = max(1, min(strength, 5))
        let top = Array(lines.prefix(cappedStrength))

        guard let bestScore = lines.first?.score else { return lines.first }
        let filtered = top.filter { withinDrop(best: bestScore, candidate: $0.score, maxDrop: maxDropCentipawns) }
        let candidates = filtered.isEmpty ? top : filtered

        if candidates.count == 1 {
            return candidates.first
        }
        let idx = Int.random(in: 0..<(candidates.count))
        return candidates[idx]
    }

    private func withinDrop(best: EngineScore, candidate: EngineScore, maxDrop: Int) -> Bool {
        switch (best, candidate) {
        case let (.cp(b), .cp(c)):
            return (b - c) <= maxDrop
        case (.mate, .mate):
            return true
        case (.mate, .cp):
            // Mate scores are decisive; allow none worse than a huge drop.
            return false
        case (.cp, .mate):
            // Mate is always acceptable if found.
            return true
        }
    }
}

private extension Array where Element == Substring {
    nonisolated subscript(safe index: Int) -> Substring? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
