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
}
