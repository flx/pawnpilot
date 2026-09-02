import Darwin
import Foundation
import XCTest
@testable import PawnPilot

/// Acceptance net for `(persistent-engine-serialize-searches)`: two searches must
/// never interleave on the one persistent pipe, an aborted search must leave the
/// child alive and aligned, and every call must finish inside `timeoutSeconds` —
/// see `plans/…/persistent-engine-serialize-searches.plan.md` B1–B8.
///
/// Every wait here is bounded. Nothing awaits `Task.value` of a cancelled call:
/// cancellation does not interrupt that await, so a regression would hang the
/// suite instead of failing it. Calls run in their own task and report into an
/// `OutcomeBox` the test polls with a deadline.
final class EngineSerializationTests: XCTestCase {

    private static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    private static func options(depth: Int) -> EngineOptions {
        EngineOptions(multiPV: 1, movetimeMs: nil, depth: depth)
    }

    // MARK: - B1: concurrent callers serialize on one child

    func testB1_threeConcurrentSearches_neverInterleaveOnOneChild() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(depth: 3, infoDelayMs: 20))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        async let first = engine.analyze(fen: Self.startFEN, options: EngineOptions(multiPV: 1, movetimeMs: nil, depth: 3))
        async let second = engine.analyze(fen: Self.startFEN, options: EngineOptions(multiPV: 1, movetimeMs: nil, depth: 5))
        async let third = engine.analyze(fen: Self.startFEN, options: EngineOptions(multiPV: 1, movetimeMs: nil, depth: 7))

        // The child exists once the first `go` is out; its pid must not change.
        await waitForLog(launch, toContain: "go")
        let pidDuringSearches = await engine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pidDuringSearches, "expected a running child once the first `go` was sent")

        let firstLines = try await first
        let secondLines = try await second
        let thirdLines = try await third

        for (result, expectedDepth) in zip([firstLines, secondLines, thirdLines], [3, 5, 7]) {
            XCTAssertEqual(result.count, 1, "expected exactly one line at depth \(expectedDepth), got \(result.count)")
            XCTAssertEqual(result.first?.depth, expectedDepth)
            XCTAssertEqual(result.first?.score, .cp(10))
        }

        let pidAfter = await engine.childProcessIdentifierForTesting()
        XCTAssertEqual(pidAfter, pidDuringSearches, "three serialized searches must share one child")

        let log = launch.commandLog()
        XCTAssertEqual(
            Set(log.filter { $0.hasPrefix("go ") }),
            Set(["go depth 3", "go depth 5", "go depth 7"]),
            "log: \(log)"
        )
        // Order-agnostic interleaving check: the go/bestmove markers must alternate,
        // i.e. no second `go` reaches the child before the previous `bestmove`.
        let markers = log.filter { $0.hasPrefix("go ") || $0 == "<bestmove" }
        XCTAssertEqual(markers.count, 6, "expected three go/bestmove pairs, got \(markers)")
        for (index, marker) in markers.enumerated() {
            if index.isMultiple(of: 2) {
                XCTAssertTrue(marker.hasPrefix("go "), "expected a `go` at position \(index) of \(markers)")
            } else {
                XCTAssertEqual(marker, "<bestmove", "expected a `<bestmove` at position \(index) of \(markers)")
            }
        }
    }

    // MARK: - B2: a stale line printed after `bestmove` never reaches the next search

    func testB2_staleLineAfterBestmove_neverLeaksIntoTheNextSearch() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(depth: 3, extraLineAfterBestmove: true))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        for depth in [2, 3, 4] {
            let lines = try await engine.analyze(fen: Self.startFEN, options: Self.options(depth: depth))
            // The stale line is `info depth 99 multipv 2 score cp 999 …`: had it
            // survived into this search, there would be a second line, or a wrong
            // depth/score on the first.
            XCTAssertEqual(lines.count, 1, "a stale line leaked into the search at depth \(depth)")
            XCTAssertEqual(lines.first?.depth, depth)
            XCTAssertEqual(lines.first?.score, .cp(10))
        }
    }

    // MARK: - B3: cancel during a search stops it and keeps the child

    func testB3_cancelDuringSearch_stopsTheSearchAndKeepsTheChild() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(depth: 3, infoDelayMs: 50))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        let box = OutcomeBox()
        let task = startAnalyze(engine, depth: 200, into: box)
        await waitForLog(launch, toContain: "go")
        let pidDuringSearch = await engine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pidDuringSearch, "expected a running child once `go` was sent")

        task.cancel()
        expectCancellation(await waitForOutcome(box, deadline: 3.0))

        let log = launch.commandLog()
        XCTAssertTrue(log.contains("stop"), "a cancel after `go` must send `stop`: \(log)")
        XCTAssertEqual(
            log.filter { $0 == "<bestmove" }.count,
            1,
            "the cancelled search must drain to exactly one bestmove: \(log)"
        )
        let pidAfterCancel = await engine.childProcessIdentifierForTesting()
        XCTAssertEqual(pidAfterCancel, pidDuringSearch, "a cancel must not kill the child")

        // The next search runs on the same child and gets its own depth.
        let lines = try await engine.analyze(fen: Self.startFEN, options: Self.options(depth: 2))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.depth, 2)
        let pidAfterRecovery = await engine.childProcessIdentifierForTesting()
        XCTAssertEqual(pidAfterRecovery, pidDuringSearch)
    }

    // MARK: - B3b: cancel during the handshake leaves the child alive

    func testB3b_cancelDuringHandshake_leavesTheChildAliveAndHandshaken() async throws {
        // The child sleeps 1.5 s before answering `uci`: a deterministic preparing window.
        let launch = try FakeUCIEngine.makeLaunch(.init(depth: 2, uciDelayMs: 1500))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        let box = OutcomeBox()
        let task = startAnalyze(engine, depth: 2, into: box)
        await waitForLog(launch, toContain: "uci")
        let pidDuringHandshake = await engine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pidDuringHandshake, "expected a running child once `uci` was sent")

        task.cancel()
        expectCancellation(await waitForOutcome(box, deadline: 3.0))

        let log = launch.commandLog()
        XCTAssertFalse(log.contains(where: { $0.hasPrefix("go") }), "a cancel before `go` must not start a search: \(log)")
        let pidAfterCancel = await engine.childProcessIdentifierForTesting()
        XCTAssertEqual(pidAfterCancel, pidDuringHandshake, "a cancel in preparation must not kill the child")
        let stillRunning = await engine.isChildRunningForTesting()
        XCTAssertTrue(stillRunning, "the child must survive a cancelled handshake")

        // The handshake finished on its own; the next call finds a handshaken child.
        let lines = try await engine.analyze(fen: Self.startFEN, options: Self.options(depth: 2))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.depth, 2)
        let pidAfterRecovery = await engine.childProcessIdentifierForTesting()
        XCTAssertEqual(pidAfterRecovery, pidDuringHandshake)
        // "Handshaken" means exactly that: the second call did not send `uci` again.
        XCTAssertEqual(launch.commandLog().filter { $0 == "uci" }.count, 1, "the handshake must not be redone: \(launch.commandLog())")
    }

    // MARK: - B4: cancel while queued never starts the queued search

    func testB4_cancelWhileQueued_neverStartsTheQueuedSearch() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(depth: 3, infoDelayMs: 50))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        let runningBox = OutcomeBox()
        let queuedBox = OutcomeBox()

        startAnalyze(engine, depth: 20, into: runningBox)       // ≈ 1 s of searching
        await waitForLog(launch, toContain: "go")
        let queued = startAnalyze(engine, depth: 7, into: queuedBox)
        try await Task.sleep(nanoseconds: 100_000_000)          // let it reach the queue
        queued.cancel()

        expectCancellation(await waitForOutcome(queuedBox, deadline: 3.0))

        switch await waitForOutcome(runningBox, deadline: 8.0) {
        case .some(.success(let lines)):
            XCTAssertEqual(lines.count, 1)
            XCTAssertEqual(lines.first?.depth, 20, "cancelling a queued caller must not disturb the running search")
        case .some(.failure(let error)):
            XCTFail("the running search must be unaffected, got \(error)")
        case .none:
            break                                               // waitForOutcome already failed
        }

        let log = launch.commandLog()
        XCTAssertEqual(log.filter { $0.hasPrefix("go ") }, ["go depth 20"], "the queued search must never reach `go`: \(log)")
    }

    // MARK: - B4b: a caller cancelled before it calls analyze touches nothing

    func testB4b_cancelBeforeAnalyze_startsNothing() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(depth: 2))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        let box = OutcomeBox()
        let task = startAnalyze(engine, depth: 2, into: box, afterCancellation: true)
        task.cancel()

        expectCancellation(await waitForOutcome(box, deadline: 3.0))
        XCTAssertEqual(launch.commandLog(), [], "an already-cancelled caller must not send `uci` or `go`")
        let pid = await engine.childProcessIdentifierForTesting()
        XCTAssertNil(pid, "an already-cancelled caller must not start a child")
    }

    // MARK: - B5: timeout during a search kills that child; the next call restarts

    func testB5_timeoutDuringSearch_killsTheChildAndTheNextCallRestarts() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(depth: 3, infoDelayMs: 100))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 1.0)

        let box = OutcomeBox()
        startAnalyze(engine, depth: 100, into: box)
        await waitForLog(launch, toContain: "go")
        let pidBefore = await engine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pidBefore, "expected a running child once `go` was sent")

        guard let error = stockfishError(from: await waitForOutcome(box, deadline: 3.0)) else { return }
        guard case .timeout = error else {
            XCTFail("expected .timeout, got \(error)")
            return
        }

        let lines = try await engine.analyze(fen: Self.startFEN, options: Self.options(depth: 1))
        XCTAssertEqual(lines.first?.depth, 1)
        let pidAfter = await engine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pidAfter)
        XCTAssertNotEqual(pidAfter, pidBefore, "a timed-out search must leave no child to reuse")
    }

    // MARK: - B5b: a timeout during the handshake is .timeout, not .startFailed

    func testB5b_timeoutDuringHandshake_reportsTimeoutNotStartFailed() async throws {
        // Only the FIRST child stalls on `uci`; the replacement answers at once.
        let launch = try FakeUCIEngine.makeLaunch(.init(depth: 2, uciDelayMs: 2000, uciDelayOnlyOnce: true))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 1.0)

        let box = OutcomeBox()
        startAnalyze(engine, depth: 2, into: box)
        await waitForLog(launch, toContain: "uci")
        let pidBefore = await engine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pidBefore, "expected a running child once `uci` was sent")

        guard let error = stockfishError(from: await waitForOutcome(box, deadline: 3.0)) else { return }
        guard case .timeout = error else {
            XCTFail("a handshake that times out must report .timeout, got \(error)")
            return
        }

        let lines = try await engine.analyze(fen: Self.startFEN, options: Self.options(depth: 2))
        XCTAssertEqual(lines.first?.depth, 2)
        let pidAfter = await engine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pidAfter)
        XCTAssertNotEqual(pidAfter, pidBefore, "the stalled child must have been killed")
    }

    // MARK: - B6: a queued caller times out without ever starting

    func testB6_timeoutWhileQueued_neverStartsTheQueuedSearch() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(depth: 3, infoDelayMs: 50))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 1.0)

        let firstBox = OutcomeBox()
        let secondBox = OutcomeBox()
        // Both ask for the same long search, so the assertions do not depend on
        // which of the two back-to-back callers wins the slot.
        startAnalyze(engine, depth: 200, into: firstBox)
        startAnalyze(engine, depth: 200, into: secondBox)

        await waitForLog(launch, toContain: "go")
        let pidBefore = await engine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pidBefore, "expected a running child once `go` was sent")

        guard let firstError = stockfishError(from: await waitForOutcome(firstBox, deadline: 3.0)) else { return }
        guard case .timeout = firstError else {
            XCTFail("expected .timeout for the running caller, got \(firstError)")
            return
        }
        guard let secondError = stockfishError(from: await waitForOutcome(secondBox, deadline: 3.0)) else { return }
        guard case .timeout = secondError else {
            XCTFail("expected .timeout for the queued caller, got \(secondError)")
            return
        }

        let log = launch.commandLog()
        XCTAssertEqual(log.filter { $0.hasPrefix("go ") }.count, 1, "the queued caller must never reach `go`: \(log)")

        let lines = try await engine.analyze(fen: Self.startFEN, options: Self.options(depth: 1))
        XCTAssertEqual(lines.first?.depth, 1)
        let pidAfter = await engine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pidAfter)
        XCTAssertNotEqual(pidAfter, pidBefore, "the timed-out child must have been replaced")
    }

    // MARK: - B7: child killed mid-search, with a caller already queued behind it

    func testB7_childKilledMidSearchWithAQueuedCaller_recovers() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(depth: 2, infoDelayMs: 50))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        let runningBox = OutcomeBox()
        let queuedBox = OutcomeBox()

        startAnalyze(engine, depth: 200, into: runningBox)
        await waitForLog(launch, toContain: "go")
        guard let firstPID = await engine.childProcessIdentifierForTesting() else {
            XCTFail("expected a running child once `go` was sent")
            return
        }
        startAnalyze(engine, depth: 2, into: queuedBox)
        try await Task.sleep(nanoseconds: 100_000_000)          // let it reach the queue

        XCTAssertEqual(kill(firstPID, SIGKILL), 0, "failed to signal the fake child")

        guard let error = stockfishError(from: await waitForOutcome(runningBox, deadline: 5.0)) else { return }
        guard case .engineGone = error else {
            XCTFail("expected .engineGone for the search whose child died, got \(error)")
            return
        }

        switch await waitForOutcome(queuedBox, deadline: 5.0) {
        case .some(.success(let lines)):
            XCTAssertEqual(lines.count, 1)
            XCTAssertEqual(lines.first?.depth, 2, "the queued search must run on a fresh child")
        case .some(.failure(let queuedError)):
            XCTFail("the queued search must recover on a fresh child, got \(queuedError)")
        case .none:
            return
        }

        let secondPID = await engine.childProcessIdentifierForTesting()
        XCTAssertNotNil(secondPID)
        XCTAssertNotEqual(secondPID, firstPID, "expected a freshly spawned child with a different pid")
    }

    // MARK: - B8: a handshake failure releases the slot; the queued caller fails too

    func testB8_handshakeFailureWithAQueuedCaller_bothFailAndNothingHangs() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(exitBeforeUCI: true))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        let firstBox = OutcomeBox()
        let secondBox = OutcomeBox()
        startAnalyze(engine, depth: 2, into: firstBox)
        startAnalyze(engine, depth: 2, into: secondBox)

        guard let firstError = stockfishError(from: await waitForOutcome(firstBox, deadline: 5.0)) else { return }
        guard case .startFailed = firstError else {
            XCTFail("expected .startFailed, got \(firstError)")
            return
        }
        guard let secondError = stockfishError(from: await waitForOutcome(secondBox, deadline: 5.0)) else { return }
        guard case .startFailed = secondError else {
            XCTFail("expected .startFailed for the queued caller, got \(secondError)")
            return
        }
    }

    // MARK: - Helpers

    /// Runs one `analyze` in its own task and records its outcome. The returned
    /// task is what a test cancels.
    ///
    /// - Parameter afterCancellation: wait until the task itself is cancelled
    ///   before calling `analyze` (B4b: an already-cancelled caller on an idle actor).
    @discardableResult
    private func startAnalyze(
        _ engine: PersistentStockfishEngine,
        depth: Int,
        into box: OutcomeBox,
        afterCancellation: Bool = false
    ) -> Task<Void, Never> {
        let fen = Self.startFEN
        return Task {
            if afterCancellation {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            do {
                let lines = try await engine.analyze(
                    fen: fen,
                    options: EngineOptions(multiPV: 1, movetimeMs: nil, depth: depth)
                )
                box.finish(.success(lines))
            } catch {
                box.finish(.failure(error))
            }
        }
    }

    /// Polls until the call finishes, or fails the test at `deadline`.
    private func waitForOutcome(
        _ box: OutcomeBox,
        deadline seconds: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Result<[EngineLine], any Error>? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let outcome = box.outcome { return outcome }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("analyze did not finish within \(seconds)s", file: file, line: line)
        return nil
    }

    /// Polls the fake's command log until it contains `token` (as a whole line or
    /// as the first word of one), or fails the test at `deadline`.
    @discardableResult
    private func waitForLog(
        _ launch: FakeUCIEngine.Launch,
        toContain token: String,
        deadline seconds: TimeInterval = 3.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        var log: [String] = []
        while Date() < deadline {
            log = launch.commandLog()
            if log.contains(where: { $0 == token || $0.hasPrefix(token + " ") }) { return log }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the fake never received `\(token)` within \(seconds)s (log: \(log))", file: file, line: line)
        return log
    }

    private func stockfishError(
        from outcome: Result<[EngineLine], any Error>?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> StockfishError? {
        switch outcome {
        case nil:
            return nil                  // waitForOutcome already failed the test
        case .some(.success(let lines)):
            XCTFail("expected a StockfishError, got \(lines.count) lines", file: file, line: line)
            return nil
        case .some(.failure(let error)):
            guard let stockfish = error as? StockfishError else {
                XCTFail("expected a StockfishError, got \(error)", file: file, line: line)
                return nil
            }
            return stockfish
        }
    }

    private func expectCancellation(
        _ outcome: Result<[EngineLine], any Error>?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch outcome {
        case nil:
            break                       // waitForOutcome already failed the test
        case .some(.success(let lines)):
            XCTFail("expected CancellationError, got \(lines.count) lines", file: file, line: line)
        case .some(.failure(let error)):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)", file: file, line: line)
        }
    }
}

/// Carries an `analyze` outcome out of the task that ran it, so the test can wait
/// for it with a deadline instead of awaiting `Task.value` — which cancellation
/// does not interrupt, and which would therefore hang rather than fail.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<[EngineLine], any Error>?

    var outcome: Result<[EngineLine], any Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func finish(_ result: Result<[EngineLine], any Error>) {
        lock.lock()
        defer { lock.unlock() }
        stored = result
    }
}
