//
//  PawnPilotTests.swift
//  PawnPilotTests
//
//  Created by Felix Matschke on 12/23/25.
//

import XCTest
@testable import PawnPilot

final class PawnPilotTests: XCTestCase {

    // MARK: - Helpers

    private func square(_ uci: String) -> BoardSquare {
        let chars = Array(uci)
        let file = Int(chars[0].asciiValue! - Character("a").asciiValue!)
        let rank = Int(String(chars[1]))! - 1
        return BoardSquare(file: file, rank: rank)
    }

    private func minimalState(activeColor: String = "w", castling: String = "-") -> BoardState {
        var board = Board()
        board[4, 0] = .whiteKing
        board[4, 7] = .blackKing
        return BoardState(board: board, activeColor: activeColor, castling: castling)
    }

    // MARK: - FEN building

    func testStandardStartPositionFEN() {
        let state = BoardState()
        XCTAssertEqual(state.fen, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    }

    func testFENFieldOrder() {
        let state = BoardState()
        let fields = state.fen.split(separator: " ")
        XCTAssertEqual(fields.count, 6)
        XCTAssertEqual(String(fields[1]), "w")
        XCTAssertEqual(String(fields[4]), "0")
        XCTAssertEqual(String(fields[5]), "1")
    }

    // MARK: - Castling sanitization (#1)

    func testSanitizedCastlingKeepsValidRights() {
        XCTAssertEqual(BoardState.sanitizedCastling("KQkq", board: .standardSetup()), "KQkq")
    }

    func testSanitizedCastlingDropsRightWhenRookMissing() {
        var board = Board.standardSetup()
        board[7, 0] = nil // remove h1 rook -> white king-side ("K") invalid
        XCTAssertEqual(BoardState.sanitizedCastling("KQkq", board: board), "Qkq")
    }

    func testSanitizedCastlingDropsBothWhenKingNotHome() {
        var board = Board.standardSetup()
        board[4, 0] = nil // remove white king -> both white rights invalid
        XCTAssertEqual(BoardState.sanitizedCastling("KQkq", board: board), "kq")
    }

    func testSanitizedCastlingDashStaysDash() {
        XCTAssertEqual(BoardState.sanitizedCastling("-", board: .standardSetup()), "-")
    }

    func testEditedBoardProducesSanitizedFEN() {
        var board = Board.standardSetup()
        board[7, 0] = nil // remove h1 rook
        let state = BoardState(board: board, activeColor: "w", castling: "KQkq")
        let castlingField = String(state.fen.split(separator: " ")[2])
        XCTAssertEqual(castlingField, "Qkq")
    }

    // MARK: - En-passant sanitization (#1)

    func testSanitizedEnPassantKeptWhenPawnPresent() {
        var board = Board()
        board[4, 3] = .whitePawn // white pawn on e4, target e3, black to move
        XCTAssertEqual(BoardState.sanitizedEnPassant("e3", board: board, activeColor: "b"), "e3")
    }

    func testSanitizedEnPassantDroppedWhenNoPawn() {
        XCTAssertEqual(BoardState.sanitizedEnPassant("e3", board: Board(), activeColor: "b"), "-")
    }

    func testSanitizedEnPassantDroppedOnWrongRank() {
        var board = Board()
        board[4, 3] = .whitePawn
        XCTAssertEqual(BoardState.sanitizedEnPassant("e6", board: board, activeColor: "b"), "-")
    }

    // MARK: - move(fromUCI:)

    func testMoveFromUCIParsesCoordinates() {
        let state = BoardState()
        let move = state.move(fromUCI: "e2e4")
        XCTAssertEqual(move?.from, square("e2"))
        XCTAssertEqual(move?.to, square("e4"))
        XCTAssertNil(move?.promotion)
    }

    func testMoveFromUCIRejectsShortString() {
        XCTAssertNil(BoardState().move(fromUCI: "e2"))
    }

    func testMoveFromUCIParsesPromotion() {
        let state = minimalState(activeColor: "w")
        XCTAssertEqual(state.move(fromUCI: "a7a8q")?.promotion, .whiteQueen)
        XCTAssertEqual(state.move(fromUCI: "a7a8n")?.promotion, .whiteKnight)
    }

    // MARK: - apply(move:)

    func testApplyDoublePushSetsEnPassantAndTogglesSide() {
        var state = BoardState()
        state.apply(move: state.move(fromUCI: "e2e4")!)
        XCTAssertEqual(state.activeColor, "b")
        XCTAssertEqual(state.enPassant, "e3")
        XCTAssertEqual(state.fullmoveNumber, 1)
        XCTAssertEqual(state.halfmoveClock, 0)
        XCTAssertEqual(state.piece(at: square("e4")), .whitePawn)
        XCTAssertNil(state.piece(at: square("e2")))
    }

    func testFullmoveIncrementsAfterBlackMove() {
        var state = BoardState()
        state.apply(move: state.move(fromUCI: "e2e4")!)
        state.apply(move: state.move(fromUCI: "e7e5")!)
        XCTAssertEqual(state.activeColor, "w")
        XCTAssertEqual(state.fullmoveNumber, 2)
    }

    func testHalfmoveClockIncrementsOnQuietMove() {
        var state = minimalState(activeColor: "w")
        // King shuffle e1-e2: not a pawn move, not a capture.
        state.apply(move: state.move(fromUCI: "e1e2")!)
        XCTAssertEqual(state.halfmoveClock, 1)
    }

    func testCaptureResetsHalfmoveClock() {
        var board = Board()
        board[4, 0] = .whiteKing
        board[4, 7] = .blackKing
        board[3, 3] = .whiteRook  // d4
        board[3, 5] = .blackPawn  // d6
        var state = BoardState(board: board, activeColor: "w", castling: "-")
        state.halfmoveClock = 9
        state.apply(move: state.move(fromUCI: "d4d6")!)
        XCTAssertEqual(state.halfmoveClock, 0)
        XCTAssertEqual(state.piece(at: square("d6")), .whiteRook)
    }

    func testEnPassantCaptureRemovesPawn() {
        var state = BoardState()
        state.apply(move: state.move(fromUCI: "e2e4")!)
        state.apply(move: state.move(fromUCI: "a7a6")!)
        state.apply(move: state.move(fromUCI: "e4e5")!)
        state.apply(move: state.move(fromUCI: "d7d5")!) // sets en-passant target d6
        XCTAssertEqual(state.enPassant, "d6")
        state.apply(move: state.move(fromUCI: "e5d6")!) // en-passant capture
        XCTAssertEqual(state.piece(at: square("d6")), .whitePawn)
        XCTAssertNil(state.piece(at: square("d5")), "Captured pawn must be removed")
    }

    func testAutoPromotionToQueenWhenNoPromotionGiven() {
        var state = minimalState(activeColor: "w")
        state.board[0, 6] = .whitePawn // a7
        state.apply(move: state.move(fromUCI: "a7a8")!)
        XCTAssertEqual(state.piece(at: square("a8")), .whiteQueen)
    }

    func testExplicitUnderpromotion() {
        var state = minimalState(activeColor: "w")
        state.board[0, 6] = .whitePawn
        state.apply(move: state.move(fromUCI: "a7a8n")!)
        XCTAssertEqual(state.piece(at: square("a8")), .whiteKnight)
    }

    func testKingsideCastleMovesRookAndClearsRights() {
        var board = Board()
        board[4, 0] = .whiteKing
        board[7, 0] = .whiteRook
        board[4, 7] = .blackKing
        var state = BoardState(board: board, activeColor: "w", castling: "K")
        state.apply(move: state.move(fromUCI: "e1g1")!)
        XCTAssertEqual(state.piece(at: square("g1")), .whiteKing)
        XCTAssertEqual(state.piece(at: square("f1")), .whiteRook)
        XCTAssertNil(state.piece(at: square("h1")))
        XCTAssertEqual(state.castling, "-")
    }

    func testRookMoveRemovesCastlingRight() {
        var board = Board.standardSetup()
        // Clear b1, c1, d1 so the queenside rook can move.
        board[1, 0] = nil
        board[2, 0] = nil
        board[3, 0] = nil
        var state = BoardState(board: board, activeColor: "w", castling: "KQkq")
        state.apply(move: state.move(fromUCI: "a1d1")!)
        XCTAssertFalse(state.castling.contains("Q"), "Queenside right must be gone after a1 rook moves")
        XCTAssertTrue(state.castling.contains("K"), "Kingside right must remain")
    }

    // MARK: - rotated180

    func testRotated180MovesPieceToOppositeCorner() {
        var board = Board()
        board[0, 0] = .whiteRook // a1
        let state = BoardState(board: board)
        let rotated = state.rotated180()
        XCTAssertEqual(rotated.piece(at: square("h8")), .whiteRook)
        XCTAssertNil(rotated.piece(at: square("a1")))
    }

    // MARK: - EngineMoveSelector

    func testPickLineEmptyReturnsNil() {
        XCTAssertNil(EngineMoveSelector().pickLine(from: [], strength: 1))
    }

    func testPickLineStrengthOneReturnsBest() {
        let lines = [
            EngineLine(multipv: 1, score: .cp(60), depth: 12, moves: ["e2e4"]),
            EngineLine(multipv: 2, score: .cp(30), depth: 12, moves: ["d2d4"])
        ]
        XCTAssertEqual(EngineMoveSelector().pickLine(from: lines, strength: 1)?.moves.first, "e2e4")
    }

    // MARK: - MoveTreeLogic (#7)

    func testPathKeyAndPrefix() {
        XCTAssertEqual(MoveTreeLogic.pathKey([0, 2, 1]), "0.2.1")
        XCTAssertTrue(MoveTreeLogic.pathHasPrefix([0, 2, 1], [0, 2]))
        XCTAssertFalse(MoveTreeLogic.pathHasPrefix([0, 2, 1], [1]))
        XCTAssertTrue(MoveTreeLogic.pathHasPrefix([0], []))
    }

    func testCompareChoicePathOrdersLexicographically() {
        XCTAssertTrue(MoveTreeLogic.compareChoicePath([0, 1], [0, 2]))
        XCTAssertTrue(MoveTreeLogic.compareChoicePath([0], [0, 0]))
        XCTAssertFalse(MoveTreeLogic.compareChoicePath([1], [0, 9]))
    }

    func testCountUniqueFirstMoves() {
        let lines = [
            EngineLine(multipv: 1, score: .cp(10), depth: 8, moves: ["e2e4", "e7e5"]),
            EngineLine(multipv: 2, score: .cp(8), depth: 8, moves: ["e2e4", "c7c5"]),
            EngineLine(multipv: 3, score: .cp(5), depth: 8, moves: ["d2d4"])
        ]
        XCTAssertEqual(MoveTreeLogic.countUniqueFirstMoves(in: lines), 2)
    }

    func testBuildChunkNodesDeduplicatesAndCaps() {
        let lines = [
            EngineLine(multipv: 1, score: .cp(20), depth: 10, moves: ["e2e4"]),
            EngineLine(multipv: 2, score: .cp(15), depth: 10, moves: ["e2e4"]), // duplicate first move
            EngineLine(multipv: 3, score: .cp(10), depth: 10, moves: ["d2d4"]),
            EngineLine(multipv: 4, score: .cp(5), depth: 10, moves: ["g1f3"])
        ]
        let nodes = MoveTreeLogic.buildChunkNodes(
            lines: lines,
            basePath: [],
            basePlyIndex: -1,
            branchCount: 2,
            scorePerspective: .white,
            existing: [:]
        )
        XCTAssertEqual(nodes.map(\.uci), ["e2e4", "d2d4"], "Duplicates removed and capped at branchCount")
    }

    // MARK: - MoveTreeLogic.frames (apply-move-then-animate)

    /// Nodes along a single spine: `[0]`, `[0, 0]`, `[0, 0, 0]`.
    private func spineNodes(_ ucis: [String]) -> [TreeMoveNode] {
        var path: [Int] = []
        return ucis.map { uci in
            path.append(0)
            return TreeMoveNode(
                parentID: nil,
                plyIndex: path.count - 1,
                choicePath: path,
                uci: uci,
                score: .cp(0),
                depth: 8,
                scorePerspective: path.count.isMultiple(of: 2) ? .black : .white,
                isUserMove: !path.count.isMultiple(of: 2)
            )
        }
    }

    func testFramesChainStatesAndStartWithoutAHighlight() {
        let nodes = spineNodes(["e2e4", "e7e5", "g1f3"])
        let map = MoveTreeLogic.nodeMap(from: nodes)
        let replay = MoveTreeLogic.frames(forPath: [0, 0, 0], rootState: BoardState(), nodeMap: map)

        XCTAssertEqual(replay.frames.count, 3)
        XCTAssertEqual(replay.frames[0].stateBefore, BoardState())
        XCTAssertNil(replay.frames[0].lastMoveBefore, "frame 0 starts from the root, so it has no highlight")
        XCTAssertEqual(replay.frames[0].piece, .whitePawn)

        for index in 1..<replay.frames.count {
            var expected = replay.frames[index - 1].stateBefore
            expected.apply(move: replay.frames[index - 1].move)
            XCTAssertEqual(replay.frames[index].stateBefore, expected, "frame \(index) must start where frame \(index - 1) ended")
            XCTAssertEqual(replay.frames[index].lastMoveBefore, replay.frames[index - 1].move)
        }

        var expectedFinal = replay.frames[2].stateBefore
        expectedFinal.apply(move: replay.frames[2].move)
        XCTAssertEqual(replay.finalState, expectedFinal)
        XCTAssertEqual(replay.finalLastMove, replay.frames[2].move)
        XCTAssertEqual(
            replay.finalState,
            MoveTreeLogic.state(forPath: [0, 0, 0], rootState: BoardState(), nodeMap: map)?.state,
            "the frames must end where the plain replay ends"
        )
    }

    func testFramesStopAtAMissingNodeAndReturnThePrefix() {
        let nodes = spineNodes(["e2e4", "e7e5"]) // no node at [0, 0, 0]
        let map = MoveTreeLogic.nodeMap(from: nodes)
        let replay = MoveTreeLogic.frames(forPath: [0, 0, 0], rootState: BoardState(), nodeMap: map)

        XCTAssertEqual(replay.frames.count, 2, "the walk stops at the first missing node")
        XCTAssertEqual(
            replay.finalState,
            MoveTreeLogic.state(forPath: [0, 0], rootState: BoardState(), nodeMap: map)?.state,
            "the prefix's state is the two-ply state"
        )
        var expected = BoardState()
        expected.apply(move: expected.move(fromUCI: "e2e4")!)
        XCTAssertEqual(replay.finalLastMove, expected.move(fromUCI: "e7e5")!, "the prefix's last move is the second ply")
    }

    func testFramesStopAtAnUnplayableMove() {
        let unparseable = MoveTreeLogic.nodeMap(from: spineNodes(["e2e4", "zz99"]))
        let stopped = MoveTreeLogic.frames(forPath: [0, 0], rootState: BoardState(), nodeMap: unparseable)
        XCTAssertEqual(stopped.frames.count, 1, "an unparseable UCI truncates the replay")

        // a3 is empty at the start, so the move has no piece to fly: the walk stops before it.
        let emptyFrom = MoveTreeLogic.nodeMap(from: spineNodes(["a3a4"]))
        let none = MoveTreeLogic.frames(forPath: [0], rootState: BoardState(), nodeMap: emptyFrom)
        XCTAssertTrue(none.frames.isEmpty)
        XCTAssertEqual(none.finalState, BoardState(), "nothing was applied")
        XCTAssertNil(none.finalLastMove)
    }

    func testFramesForAnEmptyPathYieldTheRoot() {
        let replay = MoveTreeLogic.frames(forPath: [], rootState: BoardState(), nodeMap: [:])
        XCTAssertTrue(replay.frames.isEmpty)
        XCTAssertEqual(replay.finalState, BoardState())
        XCTAssertNil(replay.finalLastMove)
    }

    // MARK: - PieceColor (#8)

    func testPieceColorFromFENField() {
        XCTAssertEqual(PieceColor(fenField: "w"), .white)
        XCTAssertEqual(PieceColor(fenField: "b"), .black)
        XCTAssertEqual(PieceColor(fenField: "anything"), .white, "Non-\"b\" maps to white, matching the old normalizer")
    }

    func testPieceColorOppositeAndFENRoundTrip() {
        XCTAssertEqual(PieceColor.white.opposite, .black)
        XCTAssertEqual(PieceColor.black.opposite, .white)
        XCTAssertEqual(PieceColor.white.fenField, "w")
        XCTAssertEqual(PieceColor.black.fenField, "b")
    }

    func testSideToMoveBridgesActiveColor() {
        var state = BoardState()
        XCTAssertEqual(state.sideToMove, .white)
        state.sideToMove = .black
        XCTAssertEqual(state.activeColor, "b")
    }

    // MARK: - setPiece (piece editor + #1 reconciliation)

    @MainActor
    func testSetPieceRejectsUnknownCode() {
        let vm = AppViewModel()
        let result = vm.setPiece(at: square("e4"), code: "zz")
        XCTAssertNotNil(result, "Unknown piece code should return an error message")
    }

    @MainActor
    func testSetPieceClearsSquare() {
        let vm = AppViewModel()
        XCTAssertNotNil(vm.boardState.piece(at: square("e2")))
        let result = vm.setPiece(at: square("e2"), code: "empty")
        XCTAssertNil(result)
        XCTAssertNil(vm.boardState.piece(at: square("e2")))
    }

    @MainActor
    func testSetPieceReconcilesCastlingWhenRookRemoved() {
        let vm = AppViewModel() // standard start: castling KQkq
        XCTAssertTrue(vm.boardState.castling.contains("K"))
        _ = vm.setPiece(at: square("h1"), code: "empty") // remove white king-side rook
        XCTAssertFalse(vm.boardState.castling.contains("K"), "King-side right must drop after h1 rook removed")
        XCTAssertTrue(vm.boardState.castling.contains("q"), "Black rights remain")
    }
}
