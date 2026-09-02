import Foundation
import CoreGraphics

/// Chess piece representation compatible with FEN symbols.
nonisolated public enum Piece: String, CaseIterable, Codable, Hashable, Sendable {
    case whitePawn = "P"
    case whiteKnight = "N"
    case whiteBishop = "B"
    case whiteRook = "R"
    case whiteQueen = "Q"
    case whiteKing = "K"
    case blackPawn = "p"
    case blackKnight = "n"
    case blackBishop = "b"
    case blackRook = "r"
    case blackQueen = "q"
    case blackKing = "k"

    public var isWhite: Bool {
        rawValue == rawValue.uppercased()
    }
}

/// Board indices follow FEN order: rank 8 (index 7) down to rank 1 (index 0); files a (0) to h (7).
nonisolated public struct Board: Codable, Hashable, Sendable {
    public static let squareCount = 64
    public private(set) var squares: [Piece?]

    public init() {
        self.squares = Array(repeating: nil, count: Board.squareCount)
    }

    public init(squares: [Piece?]) {
        precondition(squares.count == Board.squareCount, "Board must have 64 squares")
        self.squares = squares
    }

    /// Access by file (0...7) and rank (0...7) where rank 0 == rank 1 in chess notation.
    public subscript(file: Int, rank: Int) -> Piece? {
        get {
            squares[Board.index(file: file, rank: rank)]
        }
        set {
            squares[Board.index(file: file, rank: rank)] = newValue
        }
    }

    private static func index(file: Int, rank: Int) -> Int {
        precondition((0..<8).contains(file) && (0..<8).contains(rank), "Out of range square")
        return rank * 8 + file
    }

    public static func standardSetup() -> Board {
        var b = Board()
        let whiteBack: [Piece] = [.whiteRook, .whiteKnight, .whiteBishop, .whiteQueen, .whiteKing, .whiteBishop, .whiteKnight, .whiteRook]
        let blackBack: [Piece] = [.blackRook, .blackKnight, .blackBishop, .blackQueen, .blackKing, .blackBishop, .blackKnight, .blackRook]
        for file in 0..<8 {
            b[file, 0] = whiteBack[file]
            b[file, 1] = .whitePawn
            b[file, 6] = .blackPawn
            b[file, 7] = blackBack[file]
        }
        return b
    }
}
