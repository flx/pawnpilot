import Foundation
import XCTest
@testable import PawnPilot

/// Acceptance net for `(view-model-task-ownership-and-cancel)`: stale asynchronous WORK is
/// cancelled, not just its result ignored — see
/// `plans/…/view-model-task-ownership-and-cancel.plan.md` C1–C11 (C6 is unit level, in
/// `EngineProcessTests`).
///
/// Every test drives the real `AppViewModel` over the real engine classes wrapped around
/// `FakeUCIEngine`, so nothing here depends on Stockfish. Every wait is a `waitUntil` polling
/// every 20 ms to a deadline, so a regression fails the suite instead of hanging it. A search
/// against the fake lasts `searchDepth × infoDelayMs`, which is why every test sets
/// `vm.searchDepth` (the view model sends `go depth searchDepth` to BOTH engines) and every
/// tree test sets `vm.treeBranchCount = 1` (one `go` per expansion: with only `multipv 1` in
/// the fake's output a larger branch count makes the retry loop issue three).
@MainActor
final class AppViewModelTaskTests: XCTestCase {

    // MARK: - Fixtures

    private func square(_ label: String) -> BoardSquare {
        let chars = Array(label)
        let file = Int(chars[0].asciiValue! - Character("a").asciiValue!)
        let rank = Int(String(chars[1]))! - 1
        return BoardSquare(file: file, rank: rank)
    }

    /// The position the given moves reach from the start position.
    private func position(after ucis: [String]) throws -> BoardState {
        var state = BoardState()
        for uci in ucis {
            let move = try XCTUnwrap(state.move(fromUCI: uci), "could not parse \(uci)")
            state.apply(move: move)
        }
        return state
    }

    /// A view model over two scripted fakes: `engine` (per-search, the one-shot
    /// `StockfishEngine`) drives `analyze`/`engineMove`, `treeEngine` (the persistent actor)
    /// drives the move tree. Both launches are cleaned up in teardown; the tree engine is
    /// returned so a test can assert its child survived a cancel.
    private func makeViewModel(
        engineInfoDelayMs: Int = 0,
        engineBestmove: String = "e2e4",
        treeInfoDelayMs: Int = 0
    ) throws -> (
        vm: AppViewModel,
        engineLaunch: FakeUCIEngine.Launch,
        treeLaunch: FakeUCIEngine.Launch,
        treeEngine: PersistentStockfishEngine
    ) {
        XCTAssertEqual(
            MoveAnimation.duration,
            0.35,
            "the fixed waits in this file are calibrated for a 0.35 s animation"
        )
        let engineLaunch = try FakeUCIEngine.makeLaunch(
            .init(infoDelayMs: engineInfoDelayMs, bestmove: engineBestmove)
        )
        addTeardownBlock { engineLaunch.cleanUp() }
        let treeLaunch = try FakeUCIEngine.makeLaunch(.init(infoDelayMs: treeInfoDelayMs))
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
        return (viewModel, engineLaunch, treeLaunch, treeEngine)
    }

    /// Yields the main actor for `seconds`, so the view model's own tasks can run.
    private func advance(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Yields until `seconds` have passed since `start` (a no-op if they already have).
    private func advance(_ seconds: Double, since start: Date) async throws {
        let remaining = seconds - Date().timeIntervalSince(start)
        guard remaining > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    /// Polls a main-actor condition every 20 ms to a deadline; fails rather than hanging the
    /// suite.
    private func waitUntil(
        _ description: String,
        timeout: Double = 5.0,
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

    /// Polls until the fake's log holds at least `count` lines that are `token` or start with
    /// `token + " "`; fails with the log it actually saw rather than hanging.
    private func waitForLog(
        _ launch: FakeUCIEngine.Launch,
        toContain token: String,
        atLeast count: Int = 1,
        timeout: Double = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var log: [String] = []
        while true {
            log = launch.commandLog()
            if log.filter({ $0 == token || $0.hasPrefix(token + " ") }).count >= count { return }
            if Date() >= deadline {
                XCTFail(
                    "the fake never received \(count)x `\(token)` within \(timeout)s (log: \(log))",
                    file: file,
                    line: line
                )
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - C1: Reset during the bot's search

    func testC1_resetDuringTheBotSearchClearsTheBoardAndTerminatesTheSearch() async throws {
        let context = try makeViewModel(engineInfoDelayMs: 1500)
        let vm = context.vm
        vm.searchDepth = 1
        vm.interactionMode = .playAgainstComputer

        vm.engineMove()
        try await waitForLog(context.engineLaunch, toContain: "go")

        vm.resetBoard()

        // The Reset owns the board and the status the instant it returns.
        XCTAssertFalse(vm.isEngineThinking)
        XCTAssertEqual(vm.boardState, BoardState())
        XCTAssertEqual(vm.statusMessage, String(localized: "Board cleared."))

        // Past where the fake would have answered (~1.55 s after its `go`) had its parent
        // survived: the search was terminated, and its result reached nothing.
        try await advance(2.5)

        XCTAssertEqual(vm.boardState, BoardState())
        XCTAssertEqual(vm.statusMessage, String(localized: "Board cleared."))
        XCTAssertFalse(
            context.engineLaunch.commandLog().contains("<bestmove"),
            "the superseded search must have been terminated: \(context.engineLaunch.commandLog())"
        )
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    // MARK: - C2: Reset during a SELECTION expansion

    func testC2_resetDuringASelectionExpansionStopsItAndKeepsTheChild() async throws {
        let context = try makeViewModel(treeInfoDelayMs: 200)
        let vm = context.vm
        vm.searchDepth = 10
        vm.treeBranchCount = 1
        let tree = TaskTestTree.standard()
        // Unexpanded on purpose: selecting a node must actually reach `treeEngine.analyze`.
        vm.seedTreeForTesting(rootState: tree.rootState, nodes: tree.nodes, markExpanded: false)

        let nodeA = try tree.node([0])
        vm.selectTreeNode(nodeA.id)
        try await waitForLog(context.treeLaunch, toContain: "go")
        let pidDuringExpansion = await context.treeEngine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pidDuringExpansion, "expected a running tree child once `go` was sent")

        vm.resetBoard()

        // Nothing held that task before this item, so nothing could stop its search.
        try await waitUntil("the tree engine to be told to stop", timeout: 1.0) {
            context.treeLaunch.commandLog().contains("stop")
        }
        XCTAssertFalse(vm.isTreeAnalyzing)
        XCTAssertTrue(vm.treeNodes.isEmpty)
        let pidAfter = await context.treeEngine.childProcessIdentifierForTesting()
        XCTAssertEqual(pidAfter, pidDuringExpansion, "a cancelled expansion must not kill the persistent child")
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    // MARK: - C3: a result computed for another position is dropped, and the flag released

    func testC3_aStaleFENResultIsDroppedAndTheAnalysisFlagIsStillReleased() async throws {
        let context = try makeViewModel(engineInfoDelayMs: 200)
        let vm = context.vm
        vm.searchDepth = 2
        vm.interactionMode = .analyzeLines

        vm.analyze()
        XCTAssertTrue(vm.isAnalyzing)
        // The board is replaced WITHOUT an invalidation: only the FEN the search carried can
        // tell its result that it no longer describes the position on screen.
        vm.boardState = try position(after: ["e2e4"])

        try await waitUntil("the analysis flag to be released") { !vm.isAnalyzing }

        XCTAssertTrue(vm.engineLines.isEmpty, "lines computed for another position must be dropped")
        XCTAssertNotEqual(vm.statusMessage, String(localized: "Analysis ready."))
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    // MARK: - C3b: a bot result computed for another position is dropped

    func testC3b_aBotResultComputedForAnotherPositionIsDroppedAndTheFlagReleased() async throws {
        let context = try makeViewModel(engineInfoDelayMs: 200, engineBestmove: "e2e4")
        let vm = context.vm
        vm.searchDepth = 2
        vm.interactionMode = .playAgainstComputer

        vm.engineMove()
        XCTAssertTrue(vm.isEngineThinking)

        // A DIRECT write with no invalidation, so the generation is untouched and only the FEN
        // the search carried can tell its move that it was computed elsewhere. C1/C5 reset to
        // the SAME position, where the generation alone would do; here e2e4 is still legal, so
        // without the FEN gate the pawn WOULD move.
        let switched = try position(after: ["g1f3", "g8f6"])
        vm.boardState = switched

        try await waitUntil("the engine flag to be released") { !vm.isEngineThinking }

        XCTAssertEqual(vm.boardState, switched, "a move computed for another position must not land")
        XCTAssertNotEqual(
            vm.statusMessage,
            String.localizedStringWithFormat(NSLocalizedString("Engine played %@.", comment: "Status after engine move"), "e2e4"),
            "a dropped result must not report a move it never made"
        )
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    // MARK: - C4: a user move during the bot's search vs during its landing

    func testC4_aUserMoveIsRefusedDuringTheBotSearchAndAcceptedDuringItsLanding() async throws {
        let context = try makeViewModel(engineInfoDelayMs: 200, engineBestmove: "e2e4")
        let vm = context.vm
        vm.searchDepth = 3
        vm.interactionMode = .playAgainstComputer

        vm.engineMove()
        let boardDuringSearch = vm.boardState
        vm.applyUserMove(from: square("e7"), to: square("e5"))

        // Silently refused: the bot owns the board while it searches, and the refusal must not
        // even claim the status bar ("Illegal move." would).
        XCTAssertEqual(vm.boardState, boardDuringSearch)
        XCTAssertFalse(vm.canUndo)
        XCTAssertEqual(vm.statusMessage, String(localized: "Engine thinking..."))

        try await waitUntil("the bot's reply to start flying") {
            vm.boardState.piece(at: self.square("e4")) == .whitePawn && vm.animatingPiece != nil
        }

        vm.applyUserMove(from: square("e7"), to: square("e5"))
        XCTAssertEqual(
            vm.boardState.piece(at: square("e5")),
            .blackPawn,
            "a move during the bot's LANDING is accepted, as it was before this item"
        )

        try await waitUntil("the engine to finish") { !vm.isEngineThinking }
        XCTAssertEqual(
            vm.statusMessage,
            String.localizedStringWithFormat(NSLocalizedString("Engine played %@.", comment: "Status after engine move"), "e2e4"),
            "the bot's landing tail still reports the move a square click cut short"
        )
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    // MARK: - C5: a superseded bot search never clears the newer one's flag

    func testC5_aSupersededBotSearchIsTerminatedAndTheNewOneKeepsItsFlag() async throws {
        let context = try makeViewModel(engineInfoDelayMs: 1500)
        let vm = context.vm
        vm.searchDepth = 1
        vm.interactionMode = .playAgainstComputer

        vm.engineMove()
        try await waitForLog(context.engineLaunch, toContain: "go")
        let firstGoAt = Date()

        vm.resetBoard()
        // Before this item `isEngineThinking` was still true here and this call returned at
        // its own guard, so no second search was ever started.
        vm.engineMove()

        try await waitForLog(context.engineLaunch, toContain: "go", atLeast: 2, timeout: 1.0)
        let secondSearchStartedAt = Date()
        try await advance(0.7, since: secondSearchStartedAt)
        XCTAssertTrue(vm.isEngineThinking, "the second search must still own the flag at 700 ms")

        try await waitUntil("the second move to land and the flag to clear") { !vm.isEngineThinking }

        try await advance(2.5, since: firstGoAt)
        XCTAssertEqual(
            context.engineLaunch.commandLog().filter { $0 == "<bestmove" }.count,
            1,
            "only the second search may reach its `bestmove`: \(context.engineLaunch.commandLog())"
        )
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    // MARK: - C7: selecting another node cancels the running selection expansion

    func testC7_selectingBWhileAsExpansionRunsCancelsAAndExpandsB() async throws {
        let context = try makeViewModel(treeInfoDelayMs: 100)
        let vm = context.vm
        vm.searchDepth = 10
        vm.treeBranchCount = 1
        let tree = TaskTestTree.standard()
        vm.seedTreeForTesting(rootState: tree.rootState, nodes: tree.nodes, markExpanded: false)

        let nodeA = try tree.node([0])
        let nodeB = try tree.node([0, 1])

        vm.selectTreeNode(nodeA.id)
        try await waitForLog(context.treeLaunch, toContain: "go")

        // B is seeded WITHOUT a child, so `[0, 1, 0]` can only come from its own expansion.
        vm.selectTreeNode(nodeB.id)

        // A held the flag (this test waited for A's `go`), so B INHERITS it: clearing it here
        // would blank the spinner and re-enable the button for the frame between this call and
        // B's task body — a visible change HEAD does not have.
        XCTAssertTrue(vm.isTreeAnalyzing, "the tree flag must pass straight from A's expansion to B's")

        try await waitUntil("A's expansion to be stopped") {
            context.treeLaunch.commandLog().contains("stop")
        }
        try await waitForLog(context.treeLaunch, toContain: "go", atLeast: 2)
        try await waitUntil("B's expansion to add its child") {
            vm.treeNodes.contains { $0.choicePath == [0, 1, 0] }
        }
        try await waitUntil("the tree flag to be released") { !vm.isTreeAnalyzing }
        // The bar belongs to B: the predecessor A was cancelled and must never write its error
        // (or any other status) over the expansion that superseded it.
        XCTAssertEqual(vm.statusMessage, String(localized: "Tree analysis ready."))
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    // MARK: - C8: starting a tree analysis cancels the bot's search

    func testC8_analyzeMoveTreeCancelsTheBotSearch() async throws {
        let context = try makeViewModel(engineInfoDelayMs: 1500)
        let vm = context.vm
        vm.searchDepth = 1
        vm.treeBranchCount = 1
        vm.interactionMode = .playAgainstComputer

        vm.engineMove()
        try await waitForLog(context.engineLaunch, toContain: "go")

        vm.analyzeMoveTree()
        XCTAssertFalse(vm.isEngineThinking, "the Play Bot spinner stops with the search it belonged to")

        try await advance(2.5)
        XCTAssertFalse(
            context.engineLaunch.commandLog().contains("<bestmove"),
            "the bot's search must have been terminated: \(context.engineLaunch.commandLog())"
        )
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    // MARK: - C9: a cancelled bot tail writes nothing

    func testC9_aCancelledBotTailNeverWritesItsStatus() async throws {
        let context = try makeViewModel(engineInfoDelayMs: 0, treeInfoDelayMs: 800)
        let vm = context.vm
        vm.searchDepth = 2
        vm.treeBranchCount = 1
        vm.interactionMode = .playAgainstComputer

        vm.engineMove()
        try await waitUntil("the bot's reply to start flying") { vm.animatingPiece != nil }

        // Snaps the flight and cancels the bot's task; its own search takes ~1.6 s (2 × 800 ms).
        vm.analyzeMoveTree()
        let cancelledAt = Date()

        // The cancelled tail would fire at apply + 0.35 s — within ~0.35 s of the cancel — and
        // its "Engine played …" would then sit in the bar until the tree finishes. Polling every
        // 50 ms from 0.4 s to 1.0 s therefore catches a tail write that slips by up to 0.65 s,
        // and the tree search cannot finish (and write its own status) before 1.6 s. A single
        // sample at 0.5 s would have been only 0.15 s past the un-fixed write.
        for step in 0...12 {
            let offset = 0.4 + Double(step) * 0.05
            try await advance(offset, since: cancelledAt)
            XCTAssertEqual(
                vm.statusMessage,
                String(localized: "Analyzing move tree..."),
                "sampled \(offset)s after the cancel"
            )
        }

        try await waitUntil("the tree analysis to finish") { !vm.isTreeAnalyzing }
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    // MARK: - C10: a mode change during a search never leaves a busy flag stuck

    func testC10a_aModeChangeDuringAnAnalysisReleasesTheAnalysisFlag() async throws {
        let context = try makeViewModel(engineInfoDelayMs: 300)
        let vm = context.vm
        vm.searchDepth = 2
        vm.interactionMode = .analyzeLines

        vm.analyze()
        XCTAssertTrue(vm.isAnalyzing)
        // Exactly what the tab binding writes.
        vm.interactionMode = .analyzeMoveTree

        try await waitUntil("the analysis flag to be released", timeout: 3.0) { !vm.isAnalyzing }
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    func testC10b_aModeChangeDuringATreeAnalysisReleasesTheTreeFlag() async throws {
        let context = try makeViewModel(treeInfoDelayMs: 300)
        let vm = context.vm
        vm.searchDepth = 2
        vm.treeBranchCount = 1

        vm.analyzeMoveTree()
        XCTAssertTrue(vm.isTreeAnalyzing)
        // The mode must flip while a search is genuinely in flight: flipping it in the same turn
        // would leave the expansion at its first guard, and the post-await guards this test is
        // about would never be reached.
        try await waitForLog(context.treeLaunch, toContain: "go")
        vm.interactionMode = .analyzeLines

        try await waitUntil("the tree flag to be released", timeout: 3.0) { !vm.isTreeAnalyzing }
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    // MARK: - C11: the F2/F5 repro, end to end

    func testC11_aMoveDuringAnExpansionThenAReanalysisReRootsTheTree() async throws {
        let context = try makeViewModel(treeInfoDelayMs: 100)
        let vm = context.vm
        vm.searchDepth = 5
        vm.treeBranchCount = 1

        vm.analyzeMoveTree()
        try await waitUntil("the root analysis to finish") { !vm.isTreeAnalyzing }
        let rootNode = try XCTUnwrap(vm.treeNodes.first, "the root expansion must have produced a node")
        XCTAssertEqual(rootNode.uci, "e2e4", "the fake's only line")
        let pidBefore = await context.treeEngine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pidBefore, "expected a running tree child after the root expansion")

        // The selection expansion is the 2nd `go`.
        vm.selectTreeNode(rootNode.id)
        try await waitForLog(context.treeLaunch, toContain: "go", atLeast: 2)

        // Black to move after 1.e4: a legal move made while that expansion is still running.
        vm.applyUserMove(from: square("e7"), to: square("e5"))
        vm.analyzeMoveTree()

        try await waitUntil("the re-rooted tree analysis to finish") { !vm.isTreeAnalyzing }

        XCTAssertEqual(vm.treeRootStateForTesting, vm.boardState)
        XCTAssertEqual(vm.boardState, try position(after: ["e2e4", "e7e5"]))
        XCTAssertFalse(vm.treeNodes.isEmpty)

        let log = context.treeLaunch.commandLog()
        let goIndexes = log.indices.filter { log[$0].hasPrefix("go ") }
        guard goIndexes.count >= 3 else {
            XCTFail("expected three searches (root, selection, re-rooted): \(log)")
            return
        }
        let stopIndex = try XCTUnwrap(log.firstIndex(of: "stop"), "the cancelled expansion must send `stop`: \(log)")
        XCTAssertGreaterThan(stopIndex, goIndexes[1], "`stop` must follow the expansion it cancels: \(log)")
        XCTAssertLessThan(stopIndex, goIndexes[2], "`stop` must precede the re-rooted analysis: \(log)")

        let pidAfter = await context.treeEngine.childProcessIdentifierForTesting()
        XCTAssertEqual(pidAfter, pidBefore, "a cancelled expansion must not kill the persistent child")
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }

    // MARK: - C13: cancelling the bot leaves no "Engine thinking…" behind a stopped spinner

    func testC13_flippingTheSideToMoveDuringTheBotSearchClearsTheThinkingStatus() async throws {
        let context = try makeViewModel(engineInfoDelayMs: 1500)
        let vm = context.vm
        vm.searchDepth = 1
        vm.interactionMode = .playAgainstComputer

        vm.engineMove()
        try await waitForLog(context.engineLaunch, toContain: "go")

        // The side-to-move picker cancels the bot and writes NO status of its own, so nothing
        // would overwrite "Engine thinking...": the bar would keep claiming a search that no
        // longer runs, with the spinner already gone.
        vm.setSideToMove(.black)

        XCTAssertFalse(vm.isEngineThinking)
        XCTAssertNotEqual(vm.statusMessage, String(localized: "Engine thinking..."))
        XCTAssertEqual(vm.boardState.sideToMove, .black)
        XCTAssertEqual(vm.boardState.board, BoardState().board, "the picker moves no pieces")

        // Past where the fake would have answered (~1.55 s after its `go`) had its parent
        // survived.
        try await advance(2.5)

        XCTAssertFalse(
            context.engineLaunch.commandLog().contains("<bestmove"),
            "the cancelled search must have been terminated: \(context.engineLaunch.commandLog())"
        )
        XCTAssertNotEqual(vm.statusMessage, String(localized: "Engine thinking..."))
        XCTAssertNotEqual(
            vm.statusMessage,
            String.localizedStringWithFormat(NSLocalizedString("Engine played %@.", comment: "Status after engine move"), "e2e4")
        )
        XCTAssertFalse(vm.statusMessage?.contains("CancellationError") ?? false)
    }
}

/// A tree the view model can be seeded with: root children `[0]` = e2e4 and `[1]` = d2d4, plus
/// `[0, 1]` = e7e5, which is deliberately CHILDLESS — the only node its expansion can add is
/// `[0, 1, 0]`, which the seed does not contain. (`MoveApplicationTests` has its own,
/// file-private, copy of this idea.)
///
/// Main-actor isolated to match the app module's default isolation, so the nodes and the
/// expected positions are built in the same domain the view model reads them from.
@MainActor
private struct TaskTestTree {
    let rootState: BoardState
    let nodes: [TreeMoveNode]

    static func standard() -> TaskTestTree {
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
        return TaskTestTree(rootState: BoardState(), nodes: [e2e4, d2d4, e7e5])
    }

    func node(_ path: [Int]) throws -> TreeMoveNode {
        try XCTUnwrap(nodes.first { $0.choicePath == path }, "no seeded node at \(path)")
    }
}
