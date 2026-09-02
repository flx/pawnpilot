import Darwin
import Foundation
import XCTest
@testable import PawnPilot

/// E3–E5 of `(detection-off-main-actor)`: the pipeline runs its work OFF the main thread, the
/// 64 classifications overlap and stay index-ordered, and a cancelled detection stops — inside
/// the edge scan, and inside the classifier fan-out — instead of running to its end.
///
/// The class is deliberately NOT `@MainActor`: only E3 needs the main actor, and it says so on
/// the one method, because its whole claim is that work started FROM the main actor does not
/// run ON it. E9 rides along invisibly: every test here drives `DetectorPipeline.process`, so
/// a phase that lost its `nonisolated` would trap in Debug rather than silently hop back.
///
/// Every wait is a poll to a deadline (the house style in `AppViewModelTaskTests`): a
/// regression fails the suite instead of hanging it.
final class DetectionConcurrencyTests: XCTestCase {

    // MARK: - Probes

    /// Records the thread its single `classify` call ran on, and how often it was called.
    /// `pthread_main_np()` is 1 on the main thread and 0 anywhere else.
    private final class ThreadRecordingClassifier: PieceClassifying, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var mainThreadFlag: Int32?

        let isModelAvailable = true

        func classify(crops: [SquareCrop]) async -> [PieceClassificationResult] {
            record(onMainThread: pthread_main_np())
            return crops.map {
                PieceClassificationResult(position: $0.position, piece: nil, confidence: 0, note: nil)
            }
        }

        /// Synchronous on purpose: `NSLock.lock()` is unavailable from an async context.
        private func record(onMainThread: Int32) {
            lock.lock()
            calls += 1
            mainThreadFlag = onMainThread
            lock.unlock()
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        /// `nil` until `classify` has run once.
        var ranOnMainThread: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return mainThreadFlag
        }
    }

    /// Fans its crops out through the real `classifyConcurrently`, blocking 50 ms per crop, and
    /// reports when the first crop started and how many crops actually ran. Compacting the
    /// fan-out's `nil` slots away is what tells the pipeline the run was cancelled.
    ///
    /// `onFirstCrop` fires from inside the first crop, before it blocks, and E5b cancels from
    /// there rather than from a poll in the test's own task. It has to: 64 children blocking
    /// in `Thread.sleep` saturate the cooperative pool, and a `Task.sleep` poll — even on the
    /// main actor — cannot be resumed until they are done. Measured on this tree: the poll
    /// observed the first crop 340 ms late, by which time all 64 crops had run and the test
    /// was vacuous.
    private final class SlowFanOutClassifier: PieceClassifying, @unchecked Sendable {
        private let lock = NSLock()
        private var completedCrops = 0
        private var firstCropAt: Date?
        private let onFirstCrop: @Sendable () -> Void

        let isModelAvailable = true

        init(onFirstCrop: @escaping @Sendable () -> Void = {}) {
            self.onFirstCrop = onFirstCrop
        }

        func classify(crops: [SquareCrop]) async -> [PieceClassificationResult] {
            let results = await PieceClassifier.classifyConcurrently(count: crops.count) { index in
                self.noteFirstCrop()
                Thread.sleep(forTimeInterval: 0.050)
                self.lock.lock()
                self.completedCrops += 1
                self.lock.unlock()
                return PieceClassificationResult(
                    position: crops[index].position,
                    piece: nil,
                    confidence: 0,
                    note: nil
                )
            }
            return results.compactMap { $0 }
        }

        private func noteFirstCrop() {
            lock.lock()
            let isFirst = firstCropAt == nil
            if isFirst { firstCropAt = Date() }
            lock.unlock()
            if isFirst { onFirstCrop() }
        }

        var cropsRun: Int {
            lock.lock()
            defer { lock.unlock() }
            return completedCrops
        }

        var firstCropStartedAt: Date? {
            lock.lock()
            defer { lock.unlock() }
            return firstCropAt
        }
    }

    /// Carries `process`'s return value out of the task that ran it, so the test can wait for
    /// it with a deadline instead of awaiting `Task.value` — which cancellation does not
    /// interrupt, and which would therefore hang rather than fail.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: DetectionOutput?

        var output: DetectionOutput? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func finish(_ output: DetectionOutput) {
            lock.lock()
            defer { lock.unlock() }
            stored = output
        }
    }

    /// Holds the task under test so a probe can cancel it from inside the work, and records the
    /// instant the cancel was asked for. `hold` after `cancel` still cancels — the probe cannot
    /// fire before the task exists in practice, but the order is not the test's to guarantee.
    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var held: Task<Void, Never>?
        private var requestedAt: Date?

        func hold(_ task: Task<Void, Never>) {
            lock.lock()
            held = task
            let alreadyRequested = requestedAt != nil
            lock.unlock()
            if alreadyRequested { task.cancel() }
        }

        func cancel() {
            lock.lock()
            if requestedAt == nil { requestedAt = Date() }
            let task = held
            lock.unlock()
            task?.cancel()
        }

        var cancelledAt: Date? {
            lock.lock()
            defer { lock.unlock() }
            return requestedAt
        }
    }

    /// Peak concurrency of a block of work, counted under a lock.
    private final class OverlapCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = 0
        private var highWaterMark = 0

        func enter() {
            lock.lock()
            inFlight += 1
            highWaterMark = max(highWaterMark, inFlight)
            lock.unlock()
        }

        func leave() {
            lock.lock()
            inFlight -= 1
            lock.unlock()
        }

        var peak: Int {
            lock.lock()
            defer { lock.unlock() }
            return highWaterMark
        }
    }

    // MARK: - Helpers

    /// Polls `value` every 5 ms until it is non-`nil` or `timeout` elapses; returns what it
    /// saw, without failing (the caller reports, with its own numbers).
    private func poll<Value>(
        for timeout: Double,
        _ value: @Sendable () -> Value?
    ) async throws -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let found = value() { return found }
            if Date() >= deadline { return value() }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Everything an observer can see of `DetectorPipeline.cancelledOutput`.
    private func assertIsCancelledOutput(
        _ output: DetectionOutput,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(output.quadrilateral, "\(context): a cancelled run kept its quadrilateral",
                     file: file, line: line)
        XCTAssertNil(output.normalizedBoard, "\(context): a cancelled run kept its normalized board",
                     file: file, line: line)
        XCTAssertEqual(output.warnings.map(\.message), ["Detection cancelled."],
                       "\(context): warnings", file: file, line: line)
        XCTAssertTrue(output.squareCrops.isEmpty, "\(context): a cancelled run kept \(output.squareCrops.count) crops",
                      file: file, line: line)
        XCTAssertEqual(output.board.squares.compactMap { $0 }.count, 0,
                       "\(context): a cancelled run published pieces", file: file, line: line)
        // The literal, not `DetectorPipeline.cancelledOutput.fen`: `process` returns that very
        // instance on a cancel, so comparing against it compared the value to itself.
        XCTAssertEqual(output.fen, "8/8/8/8/8/8/8/8 w - - 0 1", "\(context): fen",
                       file: file, line: line)
        XCTAssertFalse(output.suggestedFlipForFEN, "\(context): flip", file: file, line: line)
        XCTAssertFalse(output.suggestedCastling.white, "\(context): white castling",
                       file: file, line: line)
        XCTAssertFalse(output.suggestedCastling.black, "\(context): black castling",
                       file: file, line: line)
    }

    // MARK: - E3: the classifier does not run on the main thread

    /// Driven FROM the main actor on purpose: `process` is `@concurrent`, so the phase it
    /// awaits must still land off the main thread. Without `@concurrent` the whole pipeline
    /// would run on the caller's actor and `pthread_main_np()` would be 1.
    @MainActor
    func testE3_processRunsTheClassifierOffTheMainThread() async throws {
        let probe = ThreadRecordingClassifier()
        let pipeline = DetectorPipeline(classifier: probe)

        _ = await pipeline.process(cgImage: SyntheticBoard.edge768())

        XCTAssertEqual(probe.callCount, 1, "the pipeline classifies its 64 crops in one call")
        let onMainThread = try XCTUnwrap(
            probe.ranOnMainThread,
            "the classifier never ran, so nothing was measured — the pipeline did not reach it"
        )
        XCTAssertEqual(onMainThread, 0, "the classifier ran ON the main thread")
    }

    // MARK: - E4: the fan-out overlaps and stays index-ordered

    func testE4_classifyConcurrentlyIsIndexOrderedAndOverlaps() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        try XCTSkipUnless(cores >= 2, "overlap needs at least two cores; this host reports \(cores)")

        let overlap = OverlapCounter()
        let results = await PieceClassifier.classifyConcurrently(count: 64) { index -> Int in
            overlap.enter()
            Thread.sleep(forTimeInterval: 0.005)
            overlap.leave()
            return index
        }

        XCTAssertEqual(results, (0..<64).map(Optional.init),
                       "the fan-out must return every index, in index order")
        XCTAssertGreaterThanOrEqual(
            overlap.peak,
            2,
            "the 64 classifications never overlapped (peak \(overlap.peak) on \(cores) cores) — "
                + "they are running one after another"
        )
    }

    // MARK: - E5: cancellation stops the run

    /// (a) During the SCAN. F-big's edge scan alone takes ~2.5 s in Debug, so "back within one
    /// second of the cancel" is only reachable if the scan itself gives up.
    func testE5a_cancelDuringTheScanReturnsPromptlyWithoutClassifying() async throws {
        let probe = ThreadRecordingClassifier()
        let pipeline = DetectorPipeline(classifier: probe)
        let image = SyntheticBoard.big2880()
        let box = OutputBox()

        let task = Task {
            box.finish(await pipeline.process(cgImage: image))
        }
        // 20 ms, not 100: the cancel has to land INSIDE the run in both configurations. Measured
        // on this tree, `detectBoard` on F-big takes ~2.0 s at -Onone but only ~28 ms at -O, and
        // the whole -O pipeline finishes in ~57 ms — so a 100 ms window lands after an optimised
        // build has already published a real output, and `assertIsCancelledOutput` would fail.
        // 20 ms is inside the scan in both. Landing a little late is still safe: `process`
        // re-checks `Task.isCancelled` after each phase, and the classifier is only reached
        // after the last of those checks.
        try await Task.sleep(nanoseconds: 20_000_000)
        let cancelledAt = Date()
        task.cancel()

        let output = try await poll(for: 1.0) { box.output }
        let elapsed = Date().timeIntervalSince(cancelledAt)
        let cancelled = try XCTUnwrap(
            output,
            "process did not return within 1 s of the cancel (waited \(String(format: "%.2f", elapsed)) s)"
        )
        XCTAssertLessThan(elapsed, 1.0, "process took \(String(format: "%.2f", elapsed)) s to notice the cancel")
        assertIsCancelledOutput(cancelled, "E5a")
        XCTAssertEqual(probe.callCount, 0, "a cancelled scan must not go on to classify")
    }

    /// (b) During the FAN-OUT. The claim that bites is the crop count: without cancellation all
    /// 64 crops run (the pipeline then publishes the board they made, which this asserts it
    /// does NOT), so this fails on any build that lets the fan-out finish.
    func testE5b_cancelDuringTheFanOutSkipsTheRemainingCrops() async throws {
        // The `cropsRun < 64` claim needs the cooperative pool to be narrower than the 64 crops:
        // on a host with 64+ cores every child can start before the first one's cancel is seen,
        // and all 64 legitimately run. Skip rather than pin a false claim to the core count.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        try XCTSkipUnless(
            cores < 64,
            "the fan-out must be wider than the pool for a cancel to skip crops; this host "
                + "reports \(cores) cores"
        )

        let canceller = CancelBox()
        let probe = SlowFanOutClassifier(onFirstCrop: { canceller.cancel() })
        let pipeline = DetectorPipeline(classifier: probe)
        let image = SyntheticBoard.edge768()
        let box = OutputBox()

        canceller.hold(Task {
            box.finish(await pipeline.process(cgImage: image))
        })

        // The deadline here is the safety net for the whole run (scan included); the 1.5 s
        // claim is measured below, from the instant the first crop asked for the cancel.
        let output = try await poll(for: 10.0) { box.output }
        let returnedAt = Date()
        _ = try XCTUnwrap(probe.firstCropStartedAt, "the fan-out never started a crop")
        let cancelledAt = try XCTUnwrap(canceller.cancelledAt, "nothing ever cancelled the task")
        let cancelled = try XCTUnwrap(output, "process did not return within 10 s of the cancel")
        let elapsed = returnedAt.timeIntervalSince(cancelledAt)
        XCTAssertLessThan(
            elapsed,
            1.5,
            "process took \(String(format: "%.2f", elapsed)) s to come back from a cancelled fan-out"
        )
        XCTAssertLessThan(
            probe.cropsRun,
            64,
            "every one of the 64 crops ran after the cancel — only the ones already in flight should"
        )
        assertIsCancelledOutput(cancelled, "E5b")
    }
}
