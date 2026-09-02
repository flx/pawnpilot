import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PawnPilot

/// E6–E8 of `(detection-off-main-actor)`, Tier 3: what the VIEW MODEL does now that the
/// detection pipeline runs off the main actor.
///
/// - E6: the main actor stays live while a detection runs, and the detection still lands.
/// - E7: a board edit made during a detection wins, and the work actually stops.
/// - E8: a landing detection beats the engine work started during it — an analysis (a) and the
///   bot (b) — and the engine child is terminated, not merely ignored.
///
/// The class is `@MainActor` on purpose: every claim here is about work started FROM the main
/// actor by a `@MainActor` view model. The helpers are deliberate copies of
/// `AppViewModelTaskTests`' (`makeViewModel`/`advance`/`waitUntil`/`waitForLog`), extended with
/// a pipeline seam — those are private to that class, and a shared base would couple two
/// acceptance nets that are allowed to drift apart.
///
/// Every wait is a poll to a deadline, so a regression fails the suite instead of hanging it.
@MainActor
final class AppViewModelDetectionTests: XCTestCase {

    // MARK: - Probes

    /// One `classify` call that blocks a cooperative-pool thread for a second and then hands
    /// the crops to the REAL `Piece13` classifier, so the board that lands is the fixture's
    /// board and not a stub's.
    ///
    /// The second is the window E6/E8 need: long enough that the main actor's liveness and the
    /// "engine work started during the detection" race are observable, short enough that E8's
    /// landing budget (2.5 s, half the fake engine's delay) is a real bound.
    ///
    /// `@unchecked Sendable` with an `NSLock` around the counter: `classify` runs on the pool
    /// while the test reads `callCount` on the main actor.
    private final class SlowThenRealClassifier: PieceClassifying, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        /// Loaded ONCE, at construction, on the caller's thread: a `loadDefaultModel()` inside
        /// `classify` would put the model load inside the window E8 times.
        private let real: PieceClassifier
        private let sleepSeconds: TimeInterval

        init(sleepSeconds: TimeInterval = 1.0) {
            self.real = PieceClassifier.loadDefaultModel()
            self.sleepSeconds = sleepSeconds
        }

        var isModelAvailable: Bool { real.isModelAvailable }

        func classify(crops: [SquareCrop]) async -> [PieceClassificationResult] {
            countCallAndBlock()
            return await real.classify(crops: crops)
        }

        /// Synchronous on purpose, twice over: `NSLock.lock()` and `Thread.sleep` are both
        /// unavailable from an async context. The sleep BLOCKS its cooperative-pool thread on
        /// purpose — that is what a real classification does, and a `Task.sleep` here would
        /// leave the pool free and weaken E6's claim.
        private func countCallAndBlock() {
            lock.lock()
            calls += 1
            lock.unlock()
            Thread.sleep(forTimeInterval: sleepSeconds)
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    // MARK: - Fixtures

    /// F-real, loaded exactly as `DetectionFixtureTests` loads it: `PawnPilotTests` is a
    /// synchronized root group, so the file ships in the test bundle — but a resource in a
    /// subfolder may be copied flat, hence the fallback.
    private static let realFixtureName = "detection-bestlines-board-620"

    /// The placement F-real is pinned to in `DetectionFixtureTests` (Tier 0).
    private static let realFixturePlacement = "rnbNkb1r/pppp1ppp/3ppn2/4pp2/4PP2/2N2N2/PPPP2PP/R1BQKB1R"

    private func realFixtureImage(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGImage {
        let bundle = Bundle(for: AppViewModelDetectionTests.self)
        let name = Self.realFixtureName
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "png", subdirectory: "Fixtures")
                ?? bundle.url(forResource: name, withExtension: "png"),
            "\(name).png is missing from \(bundle.bundleURL.lastPathComponent)",
            file: file,
            line: line
        )
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(url as CFURL, nil),
            "\(name).png is not readable as an image source",
            file: file,
            line: line
        )
        return try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(source, 0, nil),
            "\(name).png holds no decodable image",
            file: file,
            line: line
        )
    }

    private func square(_ label: String) -> BoardSquare {
        let chars = Array(label)
        let file = Int(chars[0].asciiValue! - Character("a").asciiValue!)
        let rank = Int(String(chars[1]))! - 1
        return BoardSquare(file: file, rank: rank)
    }

    /// The placement field of the view model's FEN.
    private func placement(of state: BoardState) -> String {
        String(state.fen.split(separator: " ").first ?? "")
    }

    /// What the completion writes for a board that fails `analysisValidationMessage` with no
    /// kings at all — the string F-big's empty board produces.
    private var kinglessValidationMessage: String {
        String.localizedStringWithFormat(
            NSLocalizedString(
                "Invalid board for analysis: expected 1 white king and 1 black king, found %d and %d. Please correct the detected pieces and try again.",
                comment: "Validation message when detected board has wrong king counts"
            ),
            0,
            0
        )
    }

    // MARK: - Helpers

    /// A view model over two scripted fakes and an INJECTED pipeline: `engine` (the one-shot
    /// `StockfishEngine`) drives `analyze`/`engineMove`, `treeEngine` (the persistent actor)
    /// drives the move tree, and `pipeline` carries the probe classifier. Both launches are
    /// cleaned up in teardown.
    private func makeViewModel(
        pipeline: DetectorPipeline,
        engineInfoDelayMs: Int = 0,
        engineBestmove: String = "e2e4",
        treeInfoDelayMs: Int = 0
    ) throws -> (
        vm: AppViewModel,
        engineLaunch: FakeUCIEngine.Launch,
        treeLaunch: FakeUCIEngine.Launch
    ) {
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
        let viewModel = AppViewModel(engine: engine, treeEngine: treeEngine, pipeline: pipeline)
        return (viewModel, engineLaunch, treeLaunch)
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

    private func isRunning(_ status: DetectionStatus) -> Bool {
        if case .running = status { return true }
        return false
    }

    private func succeededOutput(_ status: DetectionStatus) -> DetectionOutput? {
        if case .succeeded(let output) = status { return output }
        return nil
    }

    // MARK: - E6: the main actor stays live during a detection

    func testE6_theMainActorStaysLiveDuringADetection() async throws {
        let probe = SlowThenRealClassifier()
        XCTAssertTrue(
            probe.isModelAvailable,
            "the real Piece13 model must load from the test host's bundle; the board this test "
                + "asserts on is meaningless without it"
        )
        let context = try makeViewModel(pipeline: DetectorPipeline(classifier: probe))
        let vm = context.vm

        vm.detect(cgImage: SyntheticBoard.big2880())

        // Synchronously, before the detection task has had a chance to run.
        XCTAssertEqual(vm.statusMessage, String(localized: "Detecting board..."))
        XCTAssertTrue(isRunning(vm.detectionStatus), "the detection should be running")

        // THE liveness claim. F-big's edge scan alone runs ~2 s at -Onone; before Tiers 1–2 it
        // ran ON the main actor, so this 100 ms sleep could not resume until it was over.
        let sleepStartedAt = Date()
        try await Task.sleep(nanoseconds: 100_000_000)
        let mainActorSleep = Date().timeIntervalSince(sleepStartedAt)
        XCTAssertLessThan(
            mainActorSleep,
            0.4,
            "the main actor was blocked while the detection ran: a 100 ms sleep on it took "
                + "\(String(format: "%.0f", mainActorSleep * 1000)) ms"
        )
        XCTAssertTrue(
            isRunning(vm.detectionStatus),
            "the detection should still be running 100 ms in (it takes seconds)"
        )

        try await waitUntil("the detection to land", timeout: 15) {
            self.succeededOutput(vm.detectionStatus) != nil
        }
        let output = try XCTUnwrap(succeededOutput(vm.detectionStatus))

        XCTAssertEqual(probe.callCount, 1, "the pipeline classifies its 64 crops in ONE call")
        // Not the cancelled output, which is ALSO an empty board: a real run keeps its quad and
        // its 64 crops, and carries no cancellation warning.
        XCTAssertNotNil(output.quadrilateral, "F-big: the edge detector should have found the board")
        XCTAssertEqual(output.squareCrops.count, 64, "F-big: 64 crops were classified")
        XCTAssertFalse(
            output.warnings.contains { $0.message == "Detection cancelled." },
            "F-big: this run was not cancelled"
        )
        XCTAssertFalse(output.suggestedFlipForFEN, "F-big: nothing on the board suggests a flip")

        // F-big's board: 64 empty squares, published as the model's board.
        XCTAssertEqual(placement(of: vm.boardState), "8/8/8/8/8/8/8/8", "F-big: placement")
        XCTAssertEqual(
            vm.boardState,
            BoardState(fromDetection: output),
            "the published board must be the detection's own board"
        )
        // A kingless board fails `analysisValidationMessage`, and the completion writes THAT
        // instead of "Detected position.".
        XCTAssertEqual(vm.statusMessage, kinglessValidationMessage)
    }

    // MARK: - E7: a board edit during a detection wins and stops the work

    func testE7_aBoardEditDuringADetectionWinsAndStopsTheWork() async throws {
        let probe = SlowThenRealClassifier()
        let context = try makeViewModel(pipeline: DetectorPipeline(classifier: probe))
        let vm = context.vm

        vm.detect(cgImage: SyntheticBoard.big2880())
        XCTAssertTrue(isRunning(vm.detectionStatus), "the detection should be running")

        // During the scan: a move on the board the user is looking at supersedes the detection.
        vm.applyUserMove(from: square("e2"), to: square("e4"))

        XCTAssertFalse(
            isRunning(vm.detectionStatus),
            "the superseded detection must not still read as running"
        )
        guard case .idle = vm.detectionStatus else {
            return XCTFail("expected .idle after the move, got \(vm.detectionStatus)")
        }
        // Deliberately unchanged (plan, round-4 finding 9): nil-ing it here would paint
        // "Ready.", a second visible change. The stale string is pre-existing and filed.
        XCTAssertEqual(vm.statusMessage, String(localized: "Detecting board..."))
        XCTAssertEqual(
            vm.boardState.piece(at: square("e4")),
            .whitePawn,
            "the move is on the model from `applyMoveNow` on"
        )

        // Past F-big's 2.3–2.8 s scan at -Onone: had the cancel not reached the pipeline, the
        // scan would have finished and the classifier would have run by now.
        try await advance(4.0)

        XCTAssertEqual(
            probe.callCount,
            0,
            "a cancelled detection must never reach the classifier"
        )
        XCTAssertEqual(
            vm.boardState.piece(at: square("e4")),
            .whitePawn,
            "the abandoned detection must not land on the board the move produced"
        )
        XCTAssertNil(vm.boardState.piece(at: square("e2")))
        guard case .idle = vm.detectionStatus else {
            return XCTFail("expected .idle 4 s later, got \(vm.detectionStatus)")
        }
    }

    // MARK: - E8a: a landing detection cancels an analysis started during it

    func testE8a_aLandingDetectionCancelsAnAnalysisStartedDuringIt() async throws {
        let probe = SlowThenRealClassifier()
        XCTAssertTrue(probe.isModelAvailable, "the real Piece13 model must load from the test host's bundle")
        let context = try makeViewModel(
            pipeline: DetectorPipeline(classifier: probe),
            engineInfoDelayMs: 5000
        )
        let vm = context.vm
        vm.searchDepth = 1
        vm.interactionMode = .analyzeLines

        vm.detect(cgImage: try realFixtureImage())
        XCTAssertTrue(isRunning(vm.detectionStatus), "the detection should be running")

        // Started DURING the detection, on the board the detection is about to replace.
        vm.analyze()
        XCTAssertTrue(vm.isAnalyzing)
        try await waitForLog(context.engineLaunch, toContain: "go")
        let goAt = Date()
        XCTAssertTrue(
            isRunning(vm.detectionStatus),
            "an analysis must not supersede a running detection"
        )

        try await waitUntil("the detection to land", timeout: 15) {
            self.succeededOutput(vm.detectionStatus) != nil
        }
        let landing = Date().timeIntervalSince(goAt)
        print("[detection] E8a landing (go -> .succeeded): \(String(format: "%.0f", landing * 1000)) ms")
        // Half the fake's 5 s delay: the oracle below only means anything while the detection
        // lands well before the search would have answered on its own.
        if landing > 2.5 {
            XCTFail("the detection landed \(String(format: "%.2f", landing)) s after `go`, past the 2.5 s budget")
        }

        XCTAssertEqual(placement(of: vm.boardState), Self.realFixturePlacement, "F-real: placement")
        XCTAssertTrue(vm.engineLines.isEmpty, "lines for the replaced board must not survive the detection")
        XCTAssertFalse(vm.isAnalyzing, "the superseded analysis released its flag")

        // Past where the fake would have answered (5.0 s after its `go`) had its parent
        // survived: the completion terminated the search, it did not merely ignore its result.
        try await advance(5.3, since: goAt)
        XCTAssertFalse(
            context.engineLaunch.commandLog().contains("<bestmove"),
            "the superseded search must have been terminated: \(context.engineLaunch.commandLog())"
        )
        XCTAssertEqual(placement(of: vm.boardState), Self.realFixturePlacement, "F-real: placement, 5 s on")
        XCTAssertTrue(vm.engineLines.isEmpty)
    }

    // MARK: - E8b: a landing detection beats a bot move started during it

    func testE8b_aLandingDetectionBeatsABotMoveStartedDuringIt() async throws {
        let probe = SlowThenRealClassifier()
        XCTAssertTrue(probe.isModelAvailable, "the real Piece13 model must load from the test host's bundle")
        let context = try makeViewModel(
            pipeline: DetectorPipeline(classifier: probe),
            engineInfoDelayMs: 5000
        )
        let vm = context.vm
        vm.searchDepth = 1
        vm.interactionMode = .playAgainstComputer

        vm.detect(cgImage: try realFixtureImage())
        XCTAssertTrue(isRunning(vm.detectionStatus), "the detection should be running")

        // The bot is asked for a move DURING the detection. Before this item `engineMove`
        // invalidated the detection outright and the bot went on to play on the old board.
        vm.engineMove()
        XCTAssertTrue(
            isRunning(vm.detectionStatus),
            "a bot move must not drop a running detection — the detection beats it, not the reverse"
        )
        XCTAssertTrue(vm.isEngineThinking)

        try await waitForLog(context.engineLaunch, toContain: "go")
        let goAt = Date()

        try await waitUntil("the detection to land", timeout: 15) {
            self.succeededOutput(vm.detectionStatus) != nil
        }
        let landing = Date().timeIntervalSince(goAt)
        print("[detection] E8b landing (go -> .succeeded): \(String(format: "%.0f", landing * 1000)) ms")
        if landing > 2.5 {
            XCTFail("the detection landed \(String(format: "%.2f", landing)) s after `go`, past the 2.5 s budget")
        }

        XCTAssertEqual(placement(of: vm.boardState), Self.realFixturePlacement, "F-real: placement")
        XCTAssertFalse(vm.isEngineThinking, "the landing detection cancelled the bot's search")

        // Past where the fake would have answered had its parent survived.
        try await advance(5.3, since: goAt)
        XCTAssertFalse(
            context.engineLaunch.commandLog().contains("<bestmove"),
            "the bot's search must have been terminated: \(context.engineLaunch.commandLog())"
        )
        XCTAssertEqual(placement(of: vm.boardState), Self.realFixturePlacement, "F-real: placement, 5 s on")
        XCTAssertFalse(vm.isEngineThinking)
    }
}
