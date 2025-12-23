import Foundation
//import FENDetectorKit

public struct MoveValidator {
    public init() {}

    /// Returns true if the move obeys piece rules, turns, color capture rules, and does not leave own king in check.
    public func isLegal(move: ChessMove, in state: BoardState) -> Bool {
        let board = state.board
        guard let piece = board[move.from.file, move.from.rank] else { return false }
        let movingWhite = piece.isWhite
        let sideToMoveIsWhite = state.activeColor == "w"
        guard movingWhite == sideToMoveIsWhite else { return false }
        guard move.from != move.to else { return false }

        if let destPiece = board[move.to.file, move.to.rank], destPiece.isWhite == movingWhite {
            return false
        }
        guard obeysPieceRules(piece: piece, move: move, state: state) else { return false }
        guard !kingInCheckAfterMove(move: move, piece: piece, state: state) else { return false }
        return true
    }

    public func isInCheck(state: BoardState) -> Bool {
        let activeIsWhite = state.activeColor == "w"
        guard let kingPos = kingSquare(isWhite: activeIsWhite, board: state.board) else { return false }
        return isSquareAttacked(square: kingPos, byWhite: !activeIsWhite, board: state.board)
    }

    private func obeysPieceRules(piece: Piece, move: ChessMove, state: BoardState) -> Bool {
        let board = state.board
        let dx = move.to.file - move.from.file
        let dy = move.to.rank - move.from.rank
        let absDx = abs(dx)
        let absDy = abs(dy)
        switch piece {
        case .whitePawn, .blackPawn:
            let forward = piece.isWhite ? 1 : -1
            let startRank = piece.isWhite ? 1 : 6
            let promotionRank = piece.isWhite ? 7 : 0
            let isPromotionMove = move.to.rank == promotionRank
            if let promo = move.promotion {
                guard promo.isWhite == piece.isWhite else { return false }
                guard isPromotionMove else { return false }
            }
            if dx == 0 {
                if dy == forward, board[move.to.file, move.to.rank] == nil {
                    return true
                }
                if move.from.rank == startRank, dy == 2 * forward {
                    let midRank = move.from.rank + forward
                    if board[move.to.file, move.to.rank] == nil,
                       board[move.to.file, midRank] == nil {
                        return true
                    }
                }
                return false
            } else if absDx == 1, dy == forward {
                if let target = board[move.to.file, move.to.rank], target.isWhite != piece.isWhite {
                    return true
                }
                if isEnPassantCapture(move: move, piece: piece, state: state) {
                    return true
                }
                return false
            }
            return false
        case .whiteKnight, .blackKnight:
            return (absDx == 1 && absDy == 2) || (absDx == 2 && absDy == 1)
        case .whiteBishop, .blackBishop:
            return absDx == absDy && pathClear(from: move.from, to: move.to, board: board)
        case .whiteRook, .blackRook:
            return (dx == 0 || dy == 0) && pathClear(from: move.from, to: move.to, board: board)
        case .whiteQueen, .blackQueen:
            let straight = (dx == 0 || dy == 0)
            let diagonal = absDx == absDy
            return (straight || diagonal) && pathClear(from: move.from, to: move.to, board: board)
        case .whiteKing, .blackKing:
            if max(absDx, absDy) == 1 {
                return true
            }
            if absDx == 2 && dy == 0 {
                return canCastle(move: move, piece: piece, state: state)
            }
            return false
        }
    }

    private func canCastle(move: ChessMove, piece: Piece, state: BoardState) -> Bool {
        let board = state.board
        let isWhite = piece.isWhite
        let rank = isWhite ? 0 : 7
        guard move.from.file == 4, move.from.rank == rank else { return false }

        let kingSide = move.to.file == 6 && move.to.rank == rank
        let queenSide = move.to.file == 2 && move.to.rank == rank
        guard kingSide || queenSide else { return false }

        let right: Character = isWhite ? (kingSide ? "K" : "Q") : (kingSide ? "k" : "q")
        guard state.castling.contains(right) else { return false }

        let rookFile = kingSide ? 7 : 0
        let expectedRook = isWhite ? Piece.whiteRook : .blackRook
        guard board[rookFile, rank] == expectedRook else { return false }

        let emptyFiles = kingSide ? [5, 6] : [1, 2, 3]
        for f in emptyFiles {
            if board[f, rank] != nil { return false }
        }

        let checkFiles = kingSide ? [4, 5, 6] : [4, 3, 2]
        for f in checkFiles {
            let square = BoardSquare(file: f, rank: rank)
            if isSquareAttacked(square: square, byWhite: !isWhite, board: board) { return false }
        }

        return true
    }

    private func pathClear(from: BoardSquare, to: BoardSquare, board: Board) -> Bool {
        let dx = to.file - from.file
        let dy = to.rank - from.rank
        let stepX = dx == 0 ? 0 : (dx > 0 ? 1 : -1)
        let stepY = dy == 0 ? 0 : (dy > 0 ? 1 : -1)
        var x = from.file + stepX
        var y = from.rank + stepY
        while x != to.file || y != to.rank {
            if board[x, y] != nil { return false }
            x += stepX
            y += stepY
        }
        return true
    }

    private func kingInCheckAfterMove(move: ChessMove, piece: Piece, state: BoardState) -> Bool {
        var nextBoard = state.board
        let isPawn = piece == .whitePawn || piece == .blackPawn
        let dx = move.to.file - move.from.file
        let dy = move.to.rank - move.from.rank
        let forward = piece.isWhite ? 1 : -1
        let isCastling = (piece == .whiteKing || piece == .blackKing) && abs(dx) == 2 && dy == 0

        nextBoard[move.from.file, move.from.rank] = nil

        if isEnPassantCapture(move: move, piece: piece, state: state) {
            let capturedRank = move.to.rank - forward
            nextBoard[move.to.file, capturedRank] = nil
        }

        if isCastling {
            let rank = piece.isWhite ? 0 : 7
            if dx > 0 {
                moveRook(fromFile: 7, toFile: 5, rank: rank, board: &nextBoard)
            } else {
                moveRook(fromFile: 0, toFile: 3, rank: rank, board: &nextBoard)
            }
        }

        let placedPiece: Piece
        if isPawn, move.promotion == nil, move.to.rank == (piece.isWhite ? 7 : 0) {
            placedPiece = piece.isWhite ? .whiteQueen : .blackQueen
        } else {
            placedPiece = move.promotion ?? piece
        }
        nextBoard[move.to.file, move.to.rank] = placedPiece

        let movingWhite = piece.isWhite
        let kingPos: BoardSquare
        if piece == .whiteKing || piece == .blackKing {
            kingPos = move.to
        } else if let found = kingSquare(isWhite: movingWhite, board: nextBoard) {
            kingPos = found
        } else {
            return false
        }

        return isSquareAttacked(square: kingPos, byWhite: !movingWhite, board: nextBoard)
    }

    private func kingSquare(isWhite: Bool, board: Board) -> BoardSquare? {
        for rank in 0..<8 {
            for file in 0..<8 {
                if let p = board[file, rank], p.isWhite == isWhite, (p == .whiteKing || p == .blackKing) {
                    return BoardSquare(file: file, rank: rank)
                }
            }
        }
        return nil
    }

    private func isSquareAttacked(square: BoardSquare, byWhite: Bool, board: Board) -> Bool {
        let pawnDir = byWhite ? 1 : -1
        let pawnFiles = [square.file - 1, square.file + 1]
        for f in pawnFiles {
            let r = square.rank - pawnDir
            if (0..<8).contains(f), (0..<8).contains(r),
               let p = board[f, r],
               byWhite ? p == .whitePawn : p == .blackPawn {
                return true
            }
        }

        let knightOffsets = [(1,2),(2,1),(-1,2),(-2,1),(1,-2),(2,-1),(-1,-2),(-2,-1)]
        for (dx, dy) in knightOffsets {
            let f = square.file + dx
            let r = square.rank + dy
            if (0..<8).contains(f), (0..<8).contains(r),
               let p = board[f, r],
               byWhite ? p == .whiteKnight : p == .blackKnight {
                return true
            }
        }

        let directions = [(1,0),(-1,0),(0,1),(0,-1),(1,1),(-1,1),(1,-1),(-1,-1)]
        for (dx, dy) in directions {
            var f = square.file + dx
            var r = square.rank + dy
            while (0..<8).contains(f), (0..<8).contains(r) {
                if let p = board[f, r] {
                    if attackerMatches(piece: p, byWhite: byWhite, dx: dx, dy: dy) { return true }
                    break
                }
                f += dx
                r += dy
            }
        }

        for dx in -1...1 {
            for dy in -1...1 {
                if dx == 0 && dy == 0 { continue }
                let f = square.file + dx
                let r = square.rank + dy
                if (0..<8).contains(f), (0..<8).contains(r),
                   let p = board[f, r],
                   byWhite ? p == .whiteKing : p == .blackKing {
                    return true
                }
            }
        }
        return false
    }

    private func attackerMatches(piece: Piece, byWhite: Bool, dx: Int, dy: Int) -> Bool {
        let straight = dx == 0 || dy == 0
        let diagonal = abs(dx) == abs(dy)
        if byWhite {
            if piece == .whiteQueen { return true }
            if piece == .whiteRook && straight { return true }
            if piece == .whiteBishop && diagonal { return true }
        } else {
            if piece == .blackQueen { return true }
            if piece == .blackRook && straight { return true }
            if piece == .blackBishop && diagonal { return true }
        }
        return false
    }

    private func isEnPassantCapture(move: ChessMove, piece: Piece, state: BoardState) -> Bool {
        guard piece == .whitePawn || piece == .blackPawn else { return false }
        let forward = piece.isWhite ? 1 : -1
        guard move.to.rank - move.from.rank == forward else { return false }
        guard abs(move.to.file - move.from.file) == 1 else { return false }
        guard state.board[move.to.file, move.to.rank] == nil else { return false }
        guard let epSquare = enPassantSquare(from: state.enPassant), epSquare == move.to else { return false }
        let capturedRank = move.to.rank - forward
        let captured = state.board[move.to.file, capturedRank]
        if piece.isWhite {
            return captured == .blackPawn
        } else {
            return captured == .whitePawn
        }
    }

    private func moveRook(fromFile: Int, toFile: Int, rank: Int, board: inout Board) {
        guard let rook = board[fromFile, rank] else { return }
        board[fromFile, rank] = nil
        board[toFile, rank] = rook
    }
}

public struct LegalMoveGenerator {
    private let validator = MoveValidator()

    public init() {}

    public func legalDestinations(from square: BoardSquare, in state: BoardState) -> [BoardSquare] {
        guard let piece = state.board[square.file, square.rank] else { return [] }
        let moves = candidateMoves(for: piece, from: square, board: state.board)
        return moves.compactMap { dest in
            let mv = ChessMove(from: square, to: dest)
            return validator.isLegal(move: mv, in: state) ? dest : nil
        }
    }

    public func hasAnyLegalMove(in state: BoardState) -> Bool {
        let activeIsWhite = state.activeColor == "w"
        for rank in 0..<8 {
            for file in 0..<8 {
                let square = BoardSquare(file: file, rank: rank)
                guard let piece = state.board[file, rank], piece.isWhite == activeIsWhite else { continue }
                for dest in candidateMoves(for: piece, from: square, board: state.board) {
                    let mv = ChessMove(from: square, to: dest)
                    if validator.isLegal(move: mv, in: state) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func candidateMoves(for piece: Piece, from: BoardSquare, board: Board) -> [BoardSquare] {
        var dests: [BoardSquare] = []
        let file = from.file
        let rank = from.rank
        func add(_ f: Int, _ r: Int) {
            if (0..<8).contains(f), (0..<8).contains(r) {
                dests.append(BoardSquare(file: f, rank: r))
            }
        }

        switch piece {
        case .whitePawn, .blackPawn:
            let dir = piece.isWhite ? 1 : -1
            add(file, rank + dir)
            add(file, rank + 2 * dir)
            add(file + 1, rank + dir)
            add(file - 1, rank + dir)
        case .whiteKnight, .blackKnight:
            let offsets = [(1,2),(2,1),(-1,2),(-2,1),(1,-2),(2,-1),(-1,-2),(-2,-1)]
            for (dx, dy) in offsets { add(file + dx, rank + dy) }
        case .whiteBishop, .blackBishop:
            for d in 1...7 { add(file + d, rank + d); add(file - d, rank + d); add(file + d, rank - d); add(file - d, rank - d) }
        case .whiteRook, .blackRook:
            for d in 1...7 { add(file + d, rank); add(file - d, rank); add(file, rank + d); add(file, rank - d) }
        case .whiteQueen, .blackQueen:
            for d in 1...7 {
                add(file + d, rank); add(file - d, rank); add(file, rank + d); add(file, rank - d)
                add(file + d, rank + d); add(file - d, rank + d); add(file + d, rank - d); add(file - d, rank - d)
            }
        case .whiteKing, .blackKing:
            for dx in -1...1 {
                for dy in -1...1 where !(dx == 0 && dy == 0) {
                    add(file + dx, rank + dy)
                }
            }
            add(file + 2, rank)
            add(file - 2, rank)
        }
        return dests
    }
}

private func enPassantSquare(from value: String) -> BoardSquare? {
    guard value.count == 2 else { return nil }
    let chars = Array(value)
    let files = Array("abcdefgh")
    guard let file = files.firstIndex(of: chars[0]), let rank = Int(String(chars[1])) else { return nil }
    return BoardSquare(file: file, rank: rank - 1)
}
