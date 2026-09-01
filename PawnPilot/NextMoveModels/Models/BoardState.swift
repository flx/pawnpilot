import Foundation

/// Side to move, with the FEN single-character encoding kept at the serialization boundary.
public enum PieceColor: String, Hashable {
    case white = "w"
    case black = "b"

    public init(fenField: String) {
        self = fenField == "b" ? .black : .white
    }

    public var fenField: String { rawValue }
    public var opposite: PieceColor { self == .white ? .black : .white }
}

public struct BoardState: Equatable {
    public var board: Board
    public var activeColor: String // "w" or "b"
    public var castling: String    // e.g. "KQkq" or "-"
    public var enPassant: String   // e.g. "-" or "e3"
    public var halfmoveClock: Int
    public var fullmoveNumber: Int

    public init(
        board: Board = Board.standardSetup(),
        activeColor: String = "w",
        castling: String = "KQkq",
        enPassant: String = "-",
        halfmoveClock: Int = 0,
        fullmoveNumber: Int = 1
    ) {
        self.board = board
        self.activeColor = activeColor
        self.castling = castling
        self.enPassant = enPassant
        self.halfmoveClock = halfmoveClock
        self.fullmoveNumber = fullmoveNumber
    }

    public init(fromDetection detection: DetectionOutput) {
        self.board = detection.board
        self.activeColor = "w"
        self.castling = castlingString(from: detection.suggestedCastling)
        self.enPassant = "-"
        self.halfmoveClock = 0
        self.fullmoveNumber = 1
    }

    public var fen: String {
        FENBuilder().makeFEN(
            board: board,
            activeColor: activeColor,
            castlingAvailability: Self.sanitizedCastling(castling, board: board),
            enPassant: Self.sanitizedEnPassant(enPassant, board: board, activeColor: activeColor),
            halfmoveClock: halfmoveClock,
            fullmoveNumber: fullmoveNumber
        )
    }

    /// Drop castling rights that the board can no longer support (king or rook not on its home
    /// square). Manual edits, board rotation, and side-to-move flips can leave the stored rights
    /// inconsistent with the pieces; this keeps every emitted FEN internally valid.
    static func sanitizedCastling(_ castling: String, board: Board) -> String {
        guard castling != "-" else { return "-" }
        let whiteKingHome = board[4, 0] == .whiteKing
        let blackKingHome = board[4, 7] == .blackKing
        var result = ""
        if castling.contains("K"), whiteKingHome, board[7, 0] == .whiteRook { result.append("K") }
        if castling.contains("Q"), whiteKingHome, board[0, 0] == .whiteRook { result.append("Q") }
        if castling.contains("k"), blackKingHome, board[7, 7] == .blackRook { result.append("k") }
        if castling.contains("q"), blackKingHome, board[0, 7] == .blackRook { result.append("q") }
        return result.isEmpty ? "-" : result
    }

    /// Keep the en-passant target only when it corresponds to a pawn that could have just made a
    /// two-square advance (correct rank, the moved pawn present, the target square empty).
    static func sanitizedEnPassant(_ enPassant: String, board: Board, activeColor: String) -> String {
        guard enPassant != "-", let square = parseSquare(enPassant) else { return "-" }
        if activeColor == "b" {
            // White just pushed: target on rank 3 (index 2), white pawn on rank 4 (index 3).
            guard square.rank == 2, board[square.file, 2] == nil, board[square.file, 3] == .whitePawn else { return "-" }
        } else {
            // Black just pushed: target on rank 6 (index 5), black pawn on rank 5 (index 4).
            guard square.rank == 5, board[square.file, 5] == nil, board[square.file, 4] == .blackPawn else { return "-" }
        }
        return enPassant
    }

    public mutating func apply(move: ChessMove) {
        guard let piece = board[move.from.file, move.from.rank] else { return }
        let wasBlackMove = activeColor == "b"
        let isPawn = piece == .whitePawn || piece == .blackPawn
        let dx = move.to.file - move.from.file
        let dy = move.to.rank - move.from.rank
        let forward = piece.isWhite ? 1 : -1

        let capturedOnTarget = board[move.to.file, move.to.rank]
        var isCapture = capturedOnTarget != nil

        // En-passant capture handling.
        if isPawn && abs(dx) == 1 && dy == forward && board[move.to.file, move.to.rank] == nil {
            if let ep = enPassantSquare(), ep == move.to {
                let capturedRank = move.to.rank - forward
                if let captured = board[move.to.file, capturedRank], captured.isWhite != piece.isWhite {
                    board[move.to.file, capturedRank] = nil
                    isCapture = true
                }
            }
        }

        board[move.from.file, move.from.rank] = nil

        // Castling rook move.
        if (piece == .whiteKing || piece == .blackKing) && abs(dx) == 2 && dy == 0 {
            let rank = piece.isWhite ? 0 : 7
            if dx > 0 {
                // King-side.
                moveRook(fromFile: 7, toFile: 5, rank: rank)
            } else {
                // Queen-side.
                moveRook(fromFile: 0, toFile: 3, rank: rank)
            }
        }

        let placedPiece: Piece
        if isPawn, move.promotion == nil, move.to.rank == (piece.isWhite ? 7 : 0) {
            placedPiece = piece.isWhite ? .whiteQueen : .blackQueen
        } else {
            placedPiece = move.promotion ?? piece
        }
        board[move.to.file, move.to.rank] = placedPiece

        updateCastlingRights(movedPiece: piece, from: move.from, to: move.to, capturedPiece: capturedOnTarget)

        if isPawn && abs(dy) == 2 {
            let epRank = move.from.rank + forward
            enPassant = BoardSquare(file: move.from.file, rank: epRank).label
        } else {
            enPassant = "-"
        }

        if isPawn || isCapture {
            halfmoveClock = 0
        } else {
            halfmoveClock += 1
        }

        if wasBlackMove {
            fullmoveNumber += 1
        }

        toggleSideToMove()
    }

    public mutating func toggleSideToMove() {
        activeColor = activeColor == "w" ? "b" : "w"
    }

    public func move(fromUCI uci: String) -> ChessMove? {
        guard uci.count >= 4 else { return nil }
        let chars = Array(uci)
        guard
            let fromFile = fileIndex(for: chars[0]),
            let fromRank = rankIndex(for: chars[1]),
            let toFile = fileIndex(for: chars[2]),
            let toRank = rankIndex(for: chars[3])
        else { return nil }
        var promo: Piece?
        if chars.count >= 5 {
            promo = promotionPiece(for: chars[4], activeColor: activeColor)
        }
        return ChessMove(
            from: BoardSquare(file: fromFile, rank: fromRank),
            to: BoardSquare(file: toFile, rank: toRank),
            promotion: promo
        )
    }

    /// Typed accessor for `activeColor`; the stored `String` remains the FEN-facing value.
    public var sideToMove: PieceColor {
        get { PieceColor(fenField: activeColor) }
        set { activeColor = newValue.fenField }
    }

    public func piece(at square: BoardSquare) -> Piece? {
        board[square.file, square.rank]
    }

    public func rotated180() -> BoardState {
        var rotated = BoardState(
            board: Board(),
            activeColor: activeColor,
            castling: castling,
            enPassant: rotatedEnPassant(enPassant),
            halfmoveClock: halfmoveClock,
            fullmoveNumber: fullmoveNumber
        )
        for rank in 0..<8 {
            for file in 0..<8 {
                if let p = board[file, rank] {
                    rotated.board[7 - file, 7 - rank] = p
                }
            }
        }
        return rotated
    }

    private mutating func updateCastlingRights(movedPiece: Piece, from: BoardSquare, to: BoardSquare, capturedPiece: Piece?) {
        var rights = Set(castling == "-" ? [] : Array(castling))
        func remove(_ c: Character) { rights.remove(c) }

        if movedPiece == .whiteKing {
            remove("K")
            remove("Q")
        } else if movedPiece == .blackKing {
            remove("k")
            remove("q")
        } else if movedPiece == .whiteRook {
            if from.file == 0, from.rank == 0 { remove("Q") }
            if from.file == 7, from.rank == 0 { remove("K") }
        } else if movedPiece == .blackRook {
            if from.file == 0, from.rank == 7 { remove("q") }
            if from.file == 7, from.rank == 7 { remove("k") }
        }

        if let capturedPiece {
            if capturedPiece == .whiteRook {
                if to.file == 0, to.rank == 0 { remove("Q") }
                if to.file == 7, to.rank == 0 { remove("K") }
            } else if capturedPiece == .blackRook {
                if to.file == 0, to.rank == 7 { remove("q") }
                if to.file == 7, to.rank == 7 { remove("k") }
            }
        }

        let ordered: [Character] = ["K", "Q", "k", "q"]
        let newRights = ordered.filter { rights.contains($0) }
        castling = newRights.isEmpty ? "-" : String(newRights)
    }

    private mutating func moveRook(fromFile: Int, toFile: Int, rank: Int) {
        guard let rook = board[fromFile, rank] else { return }
        board[fromFile, rank] = nil
        board[toFile, rank] = rook
    }

    private func enPassantSquare() -> BoardSquare? {
        parseSquare(enPassant)
    }

    private func rotatedEnPassant(_ value: String) -> String {
        guard let square = parseSquare(value) else { return value }
        let rotated = BoardSquare(file: 7 - square.file, rank: 7 - square.rank)
        return rotated.label
    }
}

public struct BoardSquare: Hashable {
    public let file: Int
    public let rank: Int

    public init(file: Int, rank: Int) {
        self.file = file
        self.rank = rank
    }

    public var label: String {
        let files = "abcdefgh"
        return "\(files[files.index(files.startIndex, offsetBy: file)])\(rank + 1)"
    }
}

public struct ChessMove: Hashable {
    public let from: BoardSquare
    public let to: BoardSquare
    public let promotion: Piece?

    public init(from: BoardSquare, to: BoardSquare, promotion: Piece? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    public var uci: String {
        "\(from.fileName)\(from.rankName)\(to.fileName)\(to.rankName)" + (promotion?.rawValue.lowercased() ?? "")
    }
}

private extension BoardSquare {
    var fileName: String {
        let files = Array("abcdefgh")
        return String(files[file])
    }

    var rankName: String {
        "\(rank + 1)"
    }
}

private func fileIndex(for char: Character) -> Int? {
    let files = Array("abcdefgh")
    return files.firstIndex(of: char)
}

private func rankIndex(for char: Character) -> Int? {
    guard let value = Int(String(char)) else { return nil }
    return value - 1
}

private func parseSquare(_ notation: String) -> BoardSquare? {
    guard notation.count == 2 else { return nil }
    let chars = Array(notation)
    guard let file = fileIndex(for: chars[0]), let rank = rankIndex(for: chars[1]) else { return nil }
    return BoardSquare(file: file, rank: rank)
}

private func promotionPiece(for char: Character, activeColor: String) -> Piece? {
    let lower = String(char).lowercased()
    let isWhite = activeColor == "w"
    switch lower {
    case "q":
        return isWhite ? .whiteQueen : .blackQueen
    case "r":
        return isWhite ? .whiteRook : .blackRook
    case "b":
        return isWhite ? .whiteBishop : .blackBishop
    case "n":
        return isWhite ? .whiteKnight : .blackKnight
    default:
        return nil
    }
}

private func castlingString(from suggestion: CastlingSuggestion) -> String {
    var rights = ""
    if suggestion.white {
        rights.append(contentsOf: "KQ")
    }
    if suggestion.black {
        rights.append(contentsOf: "kq")
    }
    return rights.isEmpty ? "-" : rights
}
