import Darwin
import Foundation
import XCTest
@testable import PawnPilot

/// Regression net for `(engine-pipe-write-after-death-sigpipe)`: writing to a
/// dead child's stdin must never crash the process, and both engines must
/// surface a thrown `StockfishError` instead — see
/// `plans/shipped/engine-pipe-write-after-death-sigpipe.plan.md` A1–A6.
final class EngineProcessTests: XCTestCase {

    private static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    /// `go movetime 200` against the fake; the fake answers synchronously regardless.
    private static let fakeOptions = EngineOptions(multiPV: 1, movetimeMs: 200, depth: nil)

    // MARK: - A1: EngineStdinWriter never crashes on a write to a dead pipe

    func testA1_writerSendAfterChildDeath_returnsFalseAndNeverCrashes() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = Pipe()

        let writer = EngineStdinWriter(handle: stdinPipe.fileHandleForWriting)
        try process.run()
        stdinPipe.fileHandleForReading.closeFile()

        process.terminate()
        process.waitUntilExit()

        // The test process must still be alive to reach this line at all —
        // a SIGPIPE crash would have taken the whole XCTest runner down.
        let firstSend = writer.send("quit")
        XCTAssertFalse(firstSend)
        XCTAssertTrue(writer.isGone)

        let secondSend = writer.send("quit")
        XCTAssertFalse(secondSend, "a second send on a gone writer must stay a no-op")
    }

    // MARK: - A2: real engine, tiny timeout, no crash

    @MainActor
    func testA2_realEngine_timesOutInsteadOfCrashing() async throws {
        guard let engineURL = AppViewModel.findEngineURL(in: .main) else {
            XCTFail("Stockfish binary not found in the test bundle — bundle layout regression")
            return
        }

        let engine = StockfishEngine(engineURL: engineURL, timeoutSeconds: 0.1)
        let options = EngineOptions(multiPV: 1, movetimeMs: 10_000, depth: nil)

        do {
            _ = try await engine.analyze(fen: Self.startFEN, options: options)
            XCTFail("expected StockfishError.timeout")
        } catch let error as StockfishError {
            guard case .timeout = error else {
                XCTFail("expected .timeout, got \(error)")
                return
            }
        }
    }

    // MARK: - A3: one-shot engine, child exits on `go` -> engineGone

    func testA3_oneShotEngine_exitOnGo_throwsEngineGone() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(exitOnGo: true))
        addTeardownBlock { launch.cleanUp() }
        let engine = StockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        do {
            _ = try await engine.analyze(fen: Self.startFEN, options: Self.fakeOptions)
            XCTFail("expected StockfishError.engineGone")
        } catch let error as StockfishError {
            guard case .engineGone = error else {
                XCTFail("expected .engineGone, got \(error)")
                return
            }
        }
    }

    // MARK: - A3b: the fake is a real UCI conversation when healthy (guards A3/A4 against passing for the wrong reason)

    func testA3b_oneShotEngine_healthyFake_returnsParsedLines() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(depth: 4))
        addTeardownBlock { launch.cleanUp() }
        let engine = StockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        let lines = try await engine.analyze(fen: Self.startFEN, options: Self.fakeOptions)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.depth, 4)
        XCTAssertEqual(lines.first?.moves, ["e2e4", "e7e5"])
        XCTAssertEqual(lines.first?.score, .cp(10))
    }

    // MARK: - A4: one-shot engine, child exits before answering `uci` -> startFailed

    func testA4_oneShotEngine_exitBeforeUCI_throwsStartFailed() async throws {
        let launch = try FakeUCIEngine.makeLaunch(.init(exitBeforeUCI: true))
        addTeardownBlock { launch.cleanUp() }
        let engine = StockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        do {
            _ = try await engine.analyze(fen: Self.startFEN, options: Self.fakeOptions)
            XCTFail("expected StockfishError.startFailed")
        } catch let error as StockfishError {
            guard case .startFailed = error else {
                XCTFail("expected .startFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - A5: persistent engine, child killed between calls, restarts fresh

    func testA5_persistentEngine_childKilled_restartsOnNextAnalyze() async throws {
        let launch = try FakeUCIEngine.makeLaunch()
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        let firstLines = try await engine.analyze(fen: Self.startFEN, options: Self.fakeOptions)
        XCTAssertFalse(firstLines.isEmpty)

        guard let firstPID = await engine.childProcessIdentifierForTesting() else {
            XCTFail("expected a running child after a successful analyze")
            return
        }

        XCTAssertEqual(kill(firstPID, SIGKILL), 0, "failed to signal the fake child")

        let deadline = Date().addingTimeInterval(5.0)
        while await engine.isChildRunningForTesting(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
        let stillRunning = await engine.isChildRunningForTesting()
        XCTAssertFalse(stillRunning, "the actor never observed the killed child as dead within 5s")

        // No crash writing to the dead child, and a fresh one is spawned on the next call.
        let lines = try await engine.analyze(fen: Self.startFEN, options: Self.fakeOptions)
        XCTAssertFalse(lines.isEmpty)

        guard let secondPID = await engine.childProcessIdentifierForTesting() else {
            XCTFail("expected a running child after the second analyze")
            return
        }
        XCTAssertNotEqual(firstPID, secondPID, "expected a freshly spawned child with a different pid")
    }

    // MARK: - A6: persistent engine, child dies mid-search -> engineGone, SAME actor recovers

    func testA6_persistentEngine_exitOnGo_throwsEngineGoneThenSameActorRecovers() async throws {
        // Only the first child dies on `go`; the replacement child of the same script searches.
        let launch = try FakeUCIEngine.makeLaunch(.init(exitOnGo: true, exitOnGoOnlyOnce: true))
        addTeardownBlock { launch.cleanUp() }
        let engine = PersistentStockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        do {
            _ = try await engine.analyze(fen: Self.startFEN, options: Self.fakeOptions)
            XCTFail("expected StockfishError.engineGone")
        } catch let error as StockfishError {
            guard case .engineGone = error else {
                XCTFail("expected .engineGone, got \(error)")
                return
            }
        }

        // The failed actor dropped its dead process (so the next call must start fresh).
        let droppedPID = await engine.childProcessIdentifierForTesting()
        XCTAssertNil(droppedPID, "expected the dead child to be torn down after engineGone")

        // The very next analyze on the same actor starts a fresh child and completes.
        let lines = try await engine.analyze(fen: Self.startFEN, options: Self.fakeOptions)
        XCTAssertFalse(lines.isEmpty)
        let pid = await engine.childProcessIdentifierForTesting()
        XCTAssertNotNil(pid, "expected a running replacement child after recovery")
    }

    // MARK: - C6: cancelling a one-shot search terminates its child promptly
    //
    // `(view-model-task-ownership-and-cancel)` Tier 1: the one-shot engine honours
    // cancellation by terminating the child AND closing its read end, then reports
    // `CancellationError` from its precedence ladder.

    func testC6_oneShotEngine_cancelDuringSearch_throwsCancellationAndTerminatesTheChild() async throws {
        // depth 1 with a 1.5 s delay: a search that survives emits its single info line, sleeps
        // 1.5 s and logs `<bestmove` at ~1.6 s. Cancelling makes `StockfishEngine` call
        // `Process.terminate()`, which signals the child's whole process GROUP (Foundation
        // spawns it as a group leader — measured 2026-09-01), so the search subshell dies with
        // its parent right then and never reaches its post-loop liveness check; that check is
        // for `PersistentStockfishEngine.killChild`, which SIGKILLs the pid alone. The 2.5 s
        // wait below is ~0.9 s past the marker's time: a slow machine makes this test fail,
        // never falsely pass.
        let launch = try FakeUCIEngine.makeLaunch(.init(infoDelayMs: 1500))
        addTeardownBlock { launch.cleanUp() }
        let engine = StockfishEngine(engineURL: launch.executable, arguments: launch.arguments, timeoutSeconds: 5.0)

        let box = OneShotOutcomeBox()
        let fen = Self.startFEN
        // Nothing awaits `task.value`: cancellation does not interrupt that await, so a
        // regression would hang the suite instead of failing it (the `OutcomeBox` pattern
        // from `EngineSerializationTests`).
        let task = Task {
            do {
                let lines = try await engine.analyze(
                    fen: fen,
                    options: EngineOptions(multiPV: 1, movetimeMs: nil, depth: 1),
                    requireFullDepth: false
                )
                box.finish(.success(lines))
            } catch {
                box.finish(.failure(error))
            }
        }

        await waitForLog(launch, toContain: "go")
        try await Task.sleep(nanoseconds: 100_000_000)          // 100 ms into the search
        task.cancel()
        let cancelledAt = Date()

        var outcome: Result<[EngineLine], any Error>?
        while Date().timeIntervalSince(cancelledAt) < 0.5 {
            if let stored = box.outcome {
                outcome = stored
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        switch outcome {
        case .none:
            XCTFail("the cancelled search did not finish within 500 ms")
        case .some(.success(let lines)):
            XCTFail("expected CancellationError, got \(lines.count) lines")
        case .some(.failure(let error)):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }

        // The child was terminated, not merely abandoned: at 2.6 s past the `go` the fake
        // would have logged its marker at ~1.6 s had it still had a parent.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertFalse(
            launch.commandLog().contains("<bestmove"),
            "a cancelled one-shot search must not run to its `bestmove`: \(launch.commandLog())"
        )
    }

    // MARK: - Helpers

    /// Polls the fake's command log until it contains `token` (as a whole line or as the
    /// first word of one), or fails the test at `deadline`.
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
}

/// Carries a one-shot `analyze` outcome out of the task that ran it, so the test can wait
/// for it with a deadline instead of awaiting `Task.value` — which cancellation does not
/// interrupt, and which would therefore hang rather than fail.
private final class OneShotOutcomeBox: @unchecked Sendable {
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
