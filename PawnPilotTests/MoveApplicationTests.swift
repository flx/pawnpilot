import Foundation
import XCTest
@testable import PawnPilot

/// Acceptance net for `(apply-move-then-animate)`: the model changes before the entry point
/// returns and the animation is a visual tail — see
/// `plans/…/apply-move-then-animate.plan.md` D1–D13.
///
/// Every test drives the real `AppViewModel` over the real engine classes wrapped around
/// `FakeUCIEngine`, so nothing here depends on Stockfish. The waits are `Task.sleep` on the main
/// actor, which is what lets the view model's own main-actor tasks run; they are calibrated for
/// `MoveAnimation.duration` (0.35 s), asserted in `makeViewModel`.
@MainActor
final class MoveApplicationTests: XCTestCase {

    // MARK: - Fixtures

    private func square(_ label: String) -> BoardSquare {
        let chars = Array(label)
        let file = Int(chars[0].asciiValue! - Character("a").asciiValue!)
        let rank = Int(String(chars[1]))! - 1
        return BoardSquare(file: file, rank: rank)
    }

    /// A view model over two scripted fakes: `engine` (per-search) drives `analyze`/`engineMove`,
    /// `treeEngine` (persistent) drives the move tree. Both launches are cleaned up in teardown.
    private func makeViewModel(
        depth: Int = 3,
        engineBestmove: String = "e2e4",
        engineInfoDelayMs: Int = 0
    ) throws -> (viewModel: AppViewModel, engineLaunch: FakeUCIEngine.Launch, treeLaunch: FakeUCIEngine.Launch) {
        XCTAssertEqual(
            MoveAnimation.duration,
            0.35,
            "the fixed waits in this file are calibrated for a 0.35 s animation"
        )
        let engineLaunch = try FakeUCIEngine.makeLaunch(
            .init(depth: depth, infoDelayMs: engineInfoDelayMs, bestmove: engineBestmove)
        )
        addTeardownBlock { engineLaunch.cleanUp() }
        let treeLaunch = try FakeUCIEngine.makeLaunch(.init(depth: depth))
        addTeardownBlock { treeLaunch.cleanUp() }

        let engine = StockfishEngine(
            engineURL: engineLaunch.executable,
            arguments: engineLaunch.arguments,
            timeoutSeconds: 5.0
        )
        let treeEngine = PersistentStockfishEngine(
            engineURL: treeLaunch.executable,
            arguments: treeLaunch.arguments,
            timeoutSeconds: 5.0
        )
        let viewModel = AppViewModel(engine: engine, treeEngine: treeEngine)
        viewModel.searchDepth = depth
        return (viewModel, engineLaunch, treeLaunch)
    }

    /// Yields the main actor for `seconds`, so the view model's animation tasks can run.
    private func advance(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Polls a main-actor condition to a deadline; fails rather than hanging the suite.
    private func waitUntil(
        _ description: String,
        timeout: Double = 3.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("timed out after \(timeout)s waiting for \(description)", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The position after 1. f3 e5 2. g4: black to move, `d8h4` is mate.
    private func foolsMatePosition() throws -> BoardState {
        var state = BoardState()
        for uci in ["f2f3", "e7e5", "g2g4"] {
            let move = try XCTUnwrap(state.move(fromUCI: uci), "could not parse \(uci)")
            state.apply(move: move)
        }
        XCTAssertEqual(state.sideToMove, .black)
        return state
    }

    /// White to move with the king-side castle available (f1/g1 cleared from the start position).
    private func castlingReadyPosition() -> BoardState {
        var board = Board.standardSetup()
        board[5, 0] = nil // f1
        board[6, 0] = nil // g1
        return BoardState(board: board, activeColor: "w", castling: "KQkq")
    }

    /// White pawn on e5 against a black pawn still on d7, white to move.
    private func enPassantReadyPosition() -> BoardState {
        var board = Board()
        board[4, 0] = .whiteKing  // e1
        board[4, 7] = .blackKing  // e8
        board[4, 4] = .whitePawn  // e5
        board[3, 6] = .blackPawn  // d7
        return BoardState(board: board, activeColor: "w", castling: "-")
    }

    // MARK: - D1: the model is authoritative the instant the entry point returns

    func testD1_secondRapidMoveIsRefusedWhileTheFirstIsStillInFlight() async throws {
        let vm = try makeViewModel().viewModel

        vm.applyUserMove(from: square("e2"), to: square("e4"))

        XCTAssertEqual(vm.boardState.sideToMove, .black)
        XCTAssertEqual(vm.boardState.piece(at: square("e4")), .whitePawn)
        XCTAssertNil(vm.boardState.piece(at: square("e2")))
        XCTAssertTrue(vm.canUndo)
        XCTAssertEqual(vm.animatingPiece?.from, square("e2"))

        vm.applyUserMove(from: square("d2"), to: square("d4"))

        XCTAssertEqual(vm.statusMessage, String(localized: "Illegal move."))
        XCTAssertNil(vm.boardState.piece(at: square("d4")))
        XCTAssertEqual(vm.boardState.piece(at: square("d2")), .whitePawn)
        XCTAssertEqual(vm.animatingPiece?.from, square("e2"), "a refused click must not end the flight")

        try await advance(0.8)

        XCTAssertNil(vm.animatingPiece)
        XCTAssertEqual(vm.boardState.piece(at: square("e4")), .whitePawn)
        XCTAssertNil(vm.boardState.piece(at: square("d4")))
        XCTAssertEqual(vm.lastMove, ChessMove(from: square("e2"), to: square("e4")))
    }

    // MARK: - D2: undo during the animation

    func testD2_undoDuringTheAnimationRestoresTheBoardAtOnce() async throws {
        let vm = try makeViewModel().viewModel

        vm.applyUserMove(from: square("e2"), to: square("e4"))
        vm.undo()

        XCTAssertEqual(vm.boardState, BoardState())
        XCTAssertFalse(vm.canUndo)
        XCTAssertTrue(vm.canRedo)
        XCTAssertNil(vm.animatingPiece)
        XCTAssertEqual(vm.statusMessage, String(localized: "Undid move."))

        try await advance(0.8)

        XCTAssertEqual(vm.boardState, BoardState())
        XCTAssertFalse(vm.canUndo)
        XCTAssertTrue(vm.canRedo)
        XCTAssertNil(vm.animatingPiece)
        XCTAssertEqual(vm.statusMessage, String(localized: "Undid move."))
    }

    // MARK: - D3: reset during the animation, with keep-playing armed

    func testD3_resetDuringTheAnimationCancelsTheKeepPlayingReply() async throws {
        let context = try makeViewModel()
        let vm = context.viewModel
        vm.interactionMode = .playAgainstComputer
        vm.keepPlaying = true

        vm.applyUserMove(from: square("e2"), to: square("e4"))
        vm.resetBoard()

        XCTAssertEqual(vm.boardState, BoardState())
        XCTAssertNil(vm.lastMove)
        XCTAssertFalse(vm.canUndo)
        XCTAssertNil(vm.animatingPiece)
        XCTAssertEqual(vm.statusMessage, String(localized: "Board cleared."))
        XCTAssertFalse(vm.isEngineThinking)

        try await advance(0.8)

        XCTAssertEqual(vm.boardState, BoardState())
        XCTAssertNil(vm.lastMove)
        XCTAssertFalse(vm.canUndo)
        XCTAssertNil(vm.animatingPiece)
        XCTAssertEqual(vm.statusMessage, String(localized: "Board cleared."))
        XCTAssertFalse(vm.isEngineThinking)
        XCTAssertTrue(
            context.engineLaunch.commandLog().allSatisfy { !$0.hasPrefix("go") },
            "the snapped move must not chain an engine reply; log: \(context.engineLaunch.commandLog())"
        )
    }

    // MARK: - D4: two-click tree selection

    func testD4_twoTreeSelectionsInOneStepLandOnTheSecondAndReplayIncrementally() async throws {
        let vm = try makeViewModel().viewModel
        let tree = SeededTree.standard()
        vm.seedTreeForTesting(rootState: tree.rootState, nodes: tree.nodes)

        let nodeA = try tree.node([0])
        let nodeB = try tree.node([0, 1])

        vm.selectTreeNode(nodeA.id)
        vm.selectTreeNode(nodeB.id)

        XCTAssertEqual(vm.boardState, try tree.state([0, 1]))
        XCTAssertEqual(vm.lastMove, try tree.lastMove([0, 1]))
        XCTAssertEqual(vm.selectedTreeNodeID, nodeB.id)
        XCTAssertEqual(vm.displayBoardState, try tree.state([0]), "frame 0 of the incremental replay")

        try await advance(1.0)

        XCTAssertEqual(vm.displayBoardState, vm.boardState)
        XCTAssertNil(vm.animatingPiece)
    }

    // MARK: - D4b: a multi-frame replay, and deselecting mid-replay

    func testD4b_multiFrameReplayWalksTheFramesAndDeselectRestoresAtOnce() async throws {
        let vm = try makeViewModel().viewModel
        let tree = SeededTree.standard()
        vm.seedTreeForTesting(rootState: tree.rootState, nodes: tree.nodes)

        let nodeB = try tree.node([0, 1])
        let nodeD = try tree.node([1, 0, 0])

        vm.selectTreeNode(nodeB.id)
        try await advance(1.0)
        XCTAssertNil(vm.animatingPiece, "the two-ply replay of B must have settled")

        vm.selectTreeNode(nodeD.id)

        XCTAssertEqual(vm.boardState, try tree.state([1, 0, 0]))
        XCTAssertEqual(vm.displayBoardState, tree.rootState)
        XCTAssertNil(vm.displayLastMove)

        try await advance(0.5)
        XCTAssertEqual(vm.displayBoardState, try tree.state([1]))
        XCTAssertEqual(vm.displayLastMove, try tree.lastMove([1]))

        try await advance(0.4) // 0.9 s
        XCTAssertEqual(vm.displayBoardState, try tree.state([1, 0]))
        XCTAssertEqual(vm.displayLastMove, try tree.lastMove([1, 0]))

        try await advance(0.4) // 1.3 s
        XCTAssertEqual(vm.displayBoardState, vm.boardState)
        XCTAssertNil(vm.animatingPiece)

        // Deselecting mid-replay restores the pre-selection snapshot in the same step.
        vm.selectTreeNode(nil)
        let beforeSelection = vm.boardState

        vm.selectTreeNode(nodeD.id)
        XCTAssertNotEqual(vm.boardState, beforeSelection, "the model jumps to the selection at once")
        XCTAssertNotNil(vm.animatingPiece)

        vm.selectTreeNode(nil)
        XCTAssertEqual(vm.boardState, beforeSelection)
        XCTAssertNil(vm.animatingPiece)
    }

    // MARK: - D5: the display lags the model by exactly the animation

    func testD5_displayClockShowsThePreMoveFrameWhileTheModelIsPastIt() async throws {
        let vm = try makeViewModel().viewModel

        vm.applyUserMove(from: square("e2"), to: square("e4"))

        XCTAssertEqual(vm.displayBoardState, BoardState())
        XCTAssertNil(vm.displayLastMove)
        XCTAssertEqual(vm.animatingPiece?.piece, .whitePawn)

        try await advance(0.8)

        XCTAssertEqual(vm.displayBoardState, vm.boardState)
        XCTAssertEqual(vm.displayLastMove, vm.lastMove)
        XCTAssertEqual(vm.displayLastMove, ChessMove(from: square("e2"), to: square("e4")))
    }

    // MARK: - D6: castling and en-passant frames

    func testD6_castlingRookIsOnTheModelButNotYetOnTheDisplay() async throws {
        let vm = try makeViewModel().viewModel
        vm.boardState = castlingReadyPosition()

        vm.applyUserMove(from: square("e1"), to: square("g1"))

        XCTAssertEqual(vm.boardState.board[5, 0], .whiteRook, "f1: the model has castled")
        XCTAssertEqual(vm.displayBoardState.board[7, 0], .whiteRook, "h1: the display is still pre-move")
        XCTAssertNil(vm.displayBoardState.board[5, 0])

        try await advance(0.8)

        XCTAssertEqual(vm.displayBoardState, vm.boardState)
        XCTAssertEqual(vm.boardState.board[5, 0], .whiteRook)
        XCTAssertNil(vm.boardState.board[7, 0])
    }

    func testD6_enPassantCapturedPawnIsStillOnTheDisplayDuringTheFlight() async throws {
        let vm = try makeViewModel().viewModel
        vm.boardState = enPassantReadyPosition()
        vm.setSideToMove(.black)

        vm.applyUserMove(from: square("d7"), to: square("d5"))
        try await advance(0.5)
        XCTAssertEqual(vm.boardState.enPassant, "d6")

        vm.applyUserMove(from: square("e5"), to: square("d6"))

        XCTAssertEqual(vm.boardState.piece(at: square("d6")), .whitePawn)
        XCTAssertNil(vm.boardState.piece(at: square("d5")), "the model has removed the captured pawn")
        XCTAssertEqual(
            vm.displayBoardState.piece(at: square("d5")),
            .blackPawn,
            "the display still shows the pawn about to be captured"
        )
        XCTAssertEqual(vm.displayBoardState.piece(at: square("e5")), .whitePawn)

        try await advance(0.5)

        XCTAssertEqual(vm.displayBoardState, vm.boardState)
        XCTAssertNil(vm.boardState.piece(at: square("d5")))
    }

    // MARK: - D7: the tree root captures the applied board

    func testD7_analyzeMoveTreeDuringTheAnimationRootsOnTheAppliedBoard() async throws {
        let context = try makeViewModel()
        let vm = context.viewModel
        vm.treeBranchCount = 1

        vm.applyUserMove(from: square("e2"), to: square("e4"))
        vm.analyzeMoveTree()

        XCTAssertNil(vm.animatingPiece, "analyzing snaps the flight")
        XCTAssertEqual(vm.treeRootStateForTesting, vm.boardState)
        XCTAssertEqual(vm.treeRootStateForTesting?.piece(at: square("e4")), .whitePawn)

        try await waitUntil("the tree analysis to finish") { !vm.isTreeAnalyzing }

        XCTAssertTrue(
            context.treeLaunch.commandLog().contains { $0.hasPrefix("go") },
            "the tree engine must actually have been asked; log: \(context.treeLaunch.commandLog())"
        )
    }

    // MARK: - D8: the score label follows the display clock

    func testD8_gameOverScoreTextAppearsOnlyWhenTheMatingMoveLands() async throws {
        let vm = try makeViewModel().viewModel
        vm.boardState = try foolsMatePosition()

        vm.applyUserMove(from: square("d8"), to: square("h4"))

        XCTAssertNil(vm.gameOverScoreText, "the display is still the pre-mate frame")

        try await advance(0.8)

        XCTAssertEqual(vm.gameOverScoreText, String(localized: "White is check mate"))
        XCTAssertEqual(vm.statusMessage, String(localized: "White is check mate"))
    }

    // MARK: - D9: selecting a square snaps, deselecting does not

    func testD9_selectingASquareSnapsAndGeneratesDotsForTheDisplayedPosition() async throws {
        let vm = try makeViewModel().viewModel

        vm.applyUserMove(from: square("e2"), to: square("e4"))
        vm.updateLegalMoves(for: square("b8"))

        XCTAssertNil(vm.animatingPiece)
        XCTAssertEqual(vm.displayBoardState, vm.boardState)
        // The generator emits its knight offsets in a fixed order; compare as a set.
        XCTAssertEqual(Set(vm.legalDestinations), Set([square("a6"), square("c6")]))

        // The deselect that follows every move must NOT end the flight.
        vm.applyUserMove(from: square("b8"), to: square("c6"))
        vm.updateLegalMoves(for: nil)

        XCTAssertNotNil(vm.animatingPiece)
        XCTAssertEqual(vm.legalDestinations, [])
    }

    // MARK: - D10: the piece editor reads and writes the same position

    func testD10_beginEditingSnapsSoTheEditorSeesTheAppliedBoard() async throws {
        let vm = try makeViewModel().viewModel

        vm.applyUserMove(from: square("e2"), to: square("e4"))
        let code = vm.beginEditing(at: square("e4"))

        XCTAssertEqual(code, "wp")
        XCTAssertNil(vm.animatingPiece)

        let boardBefore = vm.boardState
        let error = vm.setPiece(at: square("e4"), code: "wp")

        XCTAssertNil(error)
        XCTAssertEqual(
            vm.statusMessage,
            String.localizedStringWithFormat(
                NSLocalizedString("No piece change on %@.", comment: "Status when edited square keeps same piece"),
                square("e4").label
            )
        )
        XCTAssertEqual(vm.boardState, boardBefore)
    }

    // MARK: - D11: the side-to-move picker

    func testD11_pickerNoOpsAgainstTheModelTheUserNowSees() async throws {
        let vm = try makeViewModel().viewModel

        vm.applyUserMove(from: square("e2"), to: square("e4"))
        vm.setSideToMove(.black)

        XCTAssertNil(vm.animatingPiece)
        XCTAssertEqual(vm.boardState.sideToMove, .black)
        XCTAssertTrue(vm.canUndo)
        XCTAssertFalse(vm.canRedo)

        // Exactly one snapshot exists — the move's. The picker pushed none.
        vm.undo()
        XCTAssertEqual(vm.boardState, BoardState())
        XCTAssertFalse(vm.canUndo)
    }

    // MARK: - D12: a snapped mating move still reports mate

    func testD12_snappingAMatingMoveStillReportsMate() async throws {
        let vm = try makeViewModel().viewModel
        vm.boardState = try foolsMatePosition()

        vm.applyUserMove(from: square("d8"), to: square("h4"))
        vm.selectTreeNode(nil)

        XCTAssertNil(vm.animatingPiece)
        XCTAssertEqual(vm.statusMessage, String(localized: "White is check mate"))
    }

    // MARK: - D13: an illegal PV move still retires the lines

    func testD13_playSelectedLineClearsTheLinesAndPlaysTheLegalMove() async throws {
        let context = try makeViewModel()
        let vm = context.viewModel
        // a1a8 is blocked by the a2 pawn; e2e4 is legal.
        let line = EngineLine(multipv: 1, score: .cp(10), depth: 3, moves: ["a1a8", "e2e4"])
        vm.engineLines = [line]
        vm.selectedEngineLineID = line.id

        vm.playSelectedLine()

        // Sampled DURING the legal move's flight: the refused first move must already have retired
        // the seeded line (the loop's own clear), before the terminal analyze() can refill anything.
        try await advance(0.1)
        XCTAssertEqual(vm.boardState.piece(at: square("e4")), .whitePawn, "the legal move was applied")
        XCTAssertNotNil(vm.animatingPiece, "the legal move is still in flight at 0.1 s")
        XCTAssertTrue(vm.engineLines.isEmpty, "the refused first move must have retired the seeded line")
        XCTAssertFalse(vm.isAnalyzing, "the terminal analyze() has not started yet")

        // `isAnalyzing` is true for only a few ms against the fake, so wait on what the terminal
        // analyze() observably does — ask the engine — and then on it being over.
        try await waitUntil("the terminal analysis to ask the engine") {
            context.engineLaunch.commandLog().contains { $0.hasPrefix("go") }
        }
        try await waitUntil("the terminal analysis to finish") { !vm.isAnalyzing }

        XCTAssertEqual(vm.boardState.piece(at: square("a1")), .whiteRook, "the illegal move was refused")
        XCTAssertFalse(vm.engineLines.isEmpty, "the terminal analyze() refilled the lines from the fake")
        XCTAssertFalse(vm.engineLines.contains { $0.id == line.id })
        XCTAssertTrue(vm.canUndo)
    }

    // MARK: - E1–E5: a flight cut short by a benign write is not a replaced board

    func testE1_squareClickDuringTheFlightStillChainsTheKeepPlayingReply() async throws {
        // The engine answers e7e5, which is black's legal reply after e2e4.
        let context = try makeViewModel(depth: 1, engineBestmove: "e7e5")
        let vm = context.viewModel
        vm.interactionMode = .playAgainstComputer
        vm.keepPlaying = true

        vm.applyUserMove(from: square("e2"), to: square("e4"))
        vm.updateLegalMoves(for: square("g8"))          // a benign snap: the move stays on the board
        XCTAssertNil(vm.animatingPiece)
        XCTAssertEqual(vm.boardState.piece(at: square("e4")), .whitePawn)

        try await waitUntil("the keep-playing reply to be requested") {
            context.engineLaunch.commandLog().contains { $0.hasPrefix("go") }
        }
        try await waitUntil("the reply to land") { vm.boardState.piece(at: square("e5")) == .blackPawn }
        try await waitUntil("the engine to finish") { !vm.isEngineThinking }
        XCTAssertEqual(vm.boardState.sideToMove, .white)
    }

    func testE2_analysisStartedInsideTheWindowSurvivesTheMoveTail() async throws {
        let vm = try makeViewModel().viewModel
        vm.interactionMode = .analyzeLines

        vm.applyUserMove(from: square("e2"), to: square("e4"))
        vm.analyze()                                    // snaps, and starts a search on the applied board
        XCTAssertNil(vm.animatingPiece)

        try await waitUntil("the analysis to finish") { !vm.isAnalyzing }
        XCTAssertFalse(vm.engineLines.isEmpty)
        XCTAssertEqual(vm.statusMessage, String(localized: "Analysis ready."))

        try await advance(0.9)                          // past the move tail at 0.35 s

        XCTAssertFalse(vm.engineLines.isEmpty, "the move's tail must not wipe an analysis started after it")
        XCTAssertEqual(vm.statusMessage, String(localized: "Analysis ready."))
    }

    func testE3_engineStatusIsReportedWhenItsFlightIsCutShort() async throws {
        let context = try makeViewModel(depth: 1)
        let vm = context.viewModel
        vm.interactionMode = .playAgainstComputer

        vm.engineMove()
        try await waitUntil("the engine's move to start flying") { vm.animatingPiece != nil }
        XCTAssertEqual(vm.boardState.piece(at: square("e4")), .whitePawn, "the engine's move is on the model")

        vm.updateLegalMoves(for: square("a7"))          // a benign snap during the reply's flight
        XCTAssertNil(vm.animatingPiece)

        try await waitUntil("the engine to finish") { !vm.isEngineThinking }
        XCTAssertEqual(
            vm.statusMessage,
            String.localizedStringWithFormat(NSLocalizedString("Engine played %@.", comment: "Status after engine move"), "e2e4"),
            "a flight cut short is still a move that landed"
        )
    }

    func testE4_playSelectedLineContinuesAfterABenignSnap() async throws {
        let context = try makeViewModel()
        let vm = context.viewModel
        vm.interactionMode = .analyzeLines
        let line = EngineLine(multipv: 1, score: .cp(10), depth: 3, moves: ["e2e4", "e7e5"])
        vm.engineLines = [line]
        vm.selectedEngineLineID = line.id

        vm.playSelectedLine()
        try await advance(0.1)                          // first move in flight
        XCTAssertEqual(vm.boardState.piece(at: square("e4")), .whitePawn)
        XCTAssertNotNil(vm.animatingPiece, "the first move is still in flight at 0.1 s — the snap below must be a real one")
        vm.updateLegalMoves(for: square("a7"))          // benign snap
        XCTAssertNil(vm.animatingPiece)

        try await waitUntil("the second PV move to land") { vm.boardState.piece(at: square("e5")) == .blackPawn }
        try await waitUntil("the terminal analysis to ask the engine") {
            context.engineLaunch.commandLog().contains { $0.hasPrefix("go") }
        }
        try await waitUntil("the terminal analysis to finish") { !vm.isAnalyzing }
        XCTAssertFalse(vm.engineLines.isEmpty, "the replay ran to its end and re-analysed")
    }

    func testE5_replacingTheBoardDuringTheEngineFlightKeepsTheReplacersStatus() async throws {
        let vm = try makeViewModel(depth: 1).viewModel
        vm.interactionMode = .playAgainstComputer

        vm.engineMove()
        try await waitUntil("the engine's move to start flying") { vm.animatingPiece != nil }
        vm.resetBoard()

        try await advance(0.8)
        XCTAssertEqual(vm.boardState, BoardState())
        XCTAssertEqual(vm.statusMessage, String(localized: "Board cleared."))
        XCTAssertFalse(vm.isEngineThinking)
    }

    // MARK: - D10b: setPiece snaps before its comparison

    func testD10b_setPieceSnapsBeforeComparingWithTheBoard() async throws {
        let vm = try makeViewModel().viewModel
        _ = vm.beginEditing(at: square("e4"))          // card seeded before the move

        vm.applyUserMove(from: square("e2"), to: square("e4"))
        XCTAssertNotNil(vm.animatingPiece)

        // Applying "wp" to e4 inside the window: after the snap the model already has that pawn.
        let error = vm.setPiece(at: square("e4"), code: "wp")
        XCTAssertNil(error)
        XCTAssertNil(vm.animatingPiece, "setPiece snaps before it compares")
        XCTAssertEqual(
            vm.statusMessage,
            String.localizedStringWithFormat(
                NSLocalizedString("No piece change on %@.", comment: "Status when edited square keeps same piece"),
                square("e4").label
            )
        )
        XCTAssertEqual(vm.boardState.piece(at: square("e4")), .whitePawn)
        XCTAssertNil(vm.boardState.piece(at: square("e2")))
    }

    // MARK: - E6/E7: what the epoch and the analysis token each protect

    func testE6_resetThenTheSameMoveChainsExactlyOneReply() async throws {
        // After Reset the same move produces the identical FEN, so only the epoch tells the first
        // tail that its board was replaced. Without it two replies would be chained.
        let context = try makeViewModel(depth: 1, engineBestmove: "e7e5")
        let vm = context.viewModel
        vm.interactionMode = .playAgainstComputer
        vm.keepPlaying = true

        vm.applyUserMove(from: square("e2"), to: square("e4"))
        vm.resetBoard()
        vm.applyUserMove(from: square("e2"), to: square("e4"))

        try await waitUntil("the reply to land") { vm.boardState.piece(at: square("e5")) == .blackPawn }
        try await waitUntil("the engine to finish") { !vm.isEngineThinking }
        try await advance(0.8)                          // past both tails and any second reply

        XCTAssertEqual(
            context.engineLaunch.commandLog().filter { $0.hasPrefix("go") }.count,
            1,
            "exactly one reply must be requested: \(context.engineLaunch.commandLog())"
        )
        XCTAssertEqual(vm.boardState.sideToMove, .white)
    }

    func testE7_analyzeStartedMidReplayStopsTheReplay() async throws {
        let vm = try makeViewModel().viewModel
        vm.interactionMode = .analyzeLines
        let line = EngineLine(multipv: 1, score: .cp(10), depth: 3, moves: ["e2e4", "e7e5", "g1f3"])
        vm.engineLines = [line]
        vm.selectedEngineLineID = line.id

        vm.playSelectedLine()
        try await advance(0.1)                          // first move in flight
        XCTAssertNotNil(vm.animatingPiece)
        vm.analyze()                                    // benign snap, but it owns the lines now
        XCTAssertNil(vm.animatingPiece)

        try await waitUntil("the analysis to finish") { !vm.isAnalyzing }
        try await advance(1.2)                          // where moves 2 and 3 would have landed

        XCTAssertEqual(vm.boardState.piece(at: square("e4")), .whitePawn)
        XCTAssertNil(vm.boardState.piece(at: square("e5")), "the replay must stop at the analysed position")
        XCTAssertEqual(vm.boardState.piece(at: square("g1")), .whiteKnight)
        XCTAssertFalse(vm.engineLines.isEmpty, "the analysis of the shown position stays")
        XCTAssertEqual(vm.statusMessage, String(localized: "Analysis ready."))
    }
}

/// A tree the view model can be seeded with, plus the expected positions along its paths.
/// Root children `[0]`=e2e4, `[1]`=d2d4; `[0,1]`=e7e5; `[1,0]`=d7d5; `[1,0,0]`=c2c4.
///
/// Main-actor isolated to match the app module's default isolation, so the tree nodes and the
/// expected positions are built in the same domain the view model reads them from.
@MainActor
private struct SeededTree {
    let rootState: BoardState
    let nodes: [TreeMoveNode]

    static func standard() -> SeededTree {
        let e2e4 = TreeMoveNode(
            parentID: nil,
            plyIndex: 0,
            choicePath: [0],
            uci: "e2e4",
            score: .cp(20),
            depth: 8,
            scorePerspective: .white,
            isUserMove: true
        )
        let d2d4 = TreeMoveNode(
            parentID: nil,
            plyIndex: 0,
            choicePath: [1],
            uci: "d2d4",
            score: .cp(15),
            depth: 8,
            scorePerspective: .white,
            isUserMove: true
        )
        let e7e5 = TreeMoveNode(
            parentID: e2e4.id,
            plyIndex: 1,
            choicePath: [0, 1],
            uci: "e7e5",
            score: .cp(10),
            depth: 8,
            scorePerspective: .black,
            isUserMove: false
        )
        let d7d5 = TreeMoveNode(
            parentID: d2d4.id,
            plyIndex: 1,
            choicePath: [1, 0],
            uci: "d7d5",
            score: .cp(12),
            depth: 8,
            scorePerspective: .black,
            isUserMove: false
        )
        let c2c4 = TreeMoveNode(
            parentID: d7d5.id,
            plyIndex: 2,
            choicePath: [1, 0, 0],
            uci: "c2c4",
            score: .cp(18),
            depth: 8,
            scorePerspective: .white,
            isUserMove: true
        )
        return SeededTree(rootState: BoardState(), nodes: [e2e4, d2d4, e7e5, d7d5, c2c4])
    }

    var nodeMap: [String: TreeMoveNode] { MoveTreeLogic.nodeMap(from: nodes) }

    func node(_ path: [Int]) throws -> TreeMoveNode {
        try XCTUnwrap(nodes.first { $0.choicePath == path }, "no seeded node at \(path)")
    }

    func state(_ path: [Int]) throws -> BoardState {
        try XCTUnwrap(
            MoveTreeLogic.state(forPath: path, rootState: rootState, nodeMap: nodeMap),
            "path \(path) does not replay"
        ).state
    }

    func lastMove(_ path: [Int]) throws -> ChessMove? {
        try XCTUnwrap(
            MoveTreeLogic.state(forPath: path, rootState: rootState, nodeMap: nodeMap),
            "path \(path) does not replay"
        ).lastMove
    }
}
