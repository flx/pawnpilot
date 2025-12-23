import Foundation

public enum EngineScore: Equatable {
    case cp(Int)
    case mate(Int)

    public var description: String {
        switch self {
        case .cp(let v):
            return "\(v)cp"
        case .mate(let plies):
            return "mate \(plies)"
        }
    }
}

public struct EngineLine: Identifiable, Equatable {
    public let id = UUID()
    public let multipv: Int
    public let score: EngineScore
    public let depth: Int
    public let nodes: Int?
    public let nps: Int?
    public let moves: [String] // UCI strings

    public nonisolated init(
        multipv: Int,
        score: EngineScore,
        depth: Int,
        nodes: Int? = nil,
        nps: Int? = nil,
        moves: [String]
    ) {
        self.multipv = multipv
        self.score = score
        self.depth = depth
        self.nodes = nodes
        self.nps = nps
        self.moves = moves
    }
}

public struct EngineOptions {
    public var multiPV: Int
    public var movetimeMs: Int?
    public var depth: Int?
    public var strength: Int
    public var limitStrength: Bool
    public var elo: Int
    public var hash: Int
    public var threads: Int

    public init(
        multiPV: Int = 3,
        movetimeMs: Int? = 2000,
        depth: Int? = nil,
        strength: Int = 3,
        limitStrength: Bool = false,
        elo: Int = 1600,
        hash: Int = 128,
        threads: Int = 4
    ) {
        self.multiPV = multiPV
        self.movetimeMs = movetimeMs
        self.depth = depth
        self.strength = strength
        self.limitStrength = limitStrength
        self.elo = elo
        self.hash = hash
        self.threads = threads
    }
}

public protocol EngineAnalyzing: Sendable {
    func analyze(
        fen: String,
        options: EngineOptions,
        requireFullDepth: Bool
    ) async throws -> [EngineLine]
}
