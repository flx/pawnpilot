import Foundation

nonisolated public struct FENBuilder: Sendable {
    public init() {}

    /// Build a FEN string from the current board and metadata.
    /// Defaults follow a neutral position: white to move, no castling/en-passant info, zero halfmove, fullmove 1.
    public func makeFEN(
        board: Board,
        activeColor: String = "w",
        castlingAvailability: String = "-",
        enPassant: String = "-",
        halfmoveClock: Int = 0,
        fullmoveNumber: Int = 1
    ) -> String {
        let placement = Self.placement(from: board)
        return [
            placement,
            activeColor,
            castlingAvailability,
            enPassant,
            "\(halfmoveClock)",
            "\(fullmoveNumber)"
        ].joined(separator: " ")
    }

    private static func placement(from board: Board) -> String {
        // Ranks 8 down to 1; internal board ranks are 7 down to 0.
        let ranks = stride(from: 7, through: 0, by: -1).map { rank -> String in
            var acc = ""
            var emptyCount = 0
            for file in 0..<8 {
                if let piece = board[file, rank] {
                    if emptyCount > 0 {
                        acc += "\(emptyCount)"
                        emptyCount = 0
                    }
                    acc.append(piece.rawValue)
                } else {
                    emptyCount += 1
                }
            }
            if emptyCount > 0 { acc += "\(emptyCount)" }
            return acc
        }
        return ranks.joined(separator: "/")
    }
}
