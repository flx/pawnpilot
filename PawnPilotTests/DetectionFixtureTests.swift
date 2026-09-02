import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PawnPilot

/// E1 of `(detection-off-main-actor)`: the detection pipeline's output, pinned on three
/// fixtures BEFORE the pipeline moves off the main actor, so the move can be proved to change
/// nothing an observer can see. E2 is this same file re-run after the change.
///
/// Every test drives the real `DetectorPipeline`, which loads the real `Piece13` model out of
/// the test host's bundle exactly as `AppViewModel.init` does — an unavailable model is a
/// FAILURE here, not a skip: the model is in the bundle (the other unit tests prove it), so
/// its absence would mean the bundle layout broke.
///
/// The class is `@MainActor` because every type under `PawnPilot/FENDetector` is main-actor
/// isolated today (the app target's default isolation); after Tier 1 they are `nonisolated`
/// and this annotation becomes redundant but stays correct.
///
/// Each test prints `[detection] <fixture>: <N> ms` around the `process` call. The F-big
/// number is the "before" wall clock for a Retina-sized input; nothing asserts on it.
@MainActor
final class DetectionFixtureTests: XCTestCase {

    // MARK: - Fixtures

    /// The file fixture: a tight 620×620 crop of a real board screenshot, which takes the
    /// detector's centred-square FALLBACK path (the edge scan finds no band).
    private static let realFixtureName = "detection-bestlines-board-620"

    /// `PawnPilotTests` is a synchronized root group, so anything under the folder ships in
    /// the test bundle — but a resource in a subfolder may be copied flat, hence the fallback.
    private func realFixtureImage(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGImage {
        let bundle = Bundle(for: DetectionFixtureTests.self)
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

    // MARK: - Running the pipeline

    /// Runs the real pipeline over `image` and prints the wall clock of the `process` call.
    private func runPipeline(
        on image: CGImage,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> DetectionOutput {
        XCTAssertTrue(
            PieceClassifier.loadDefaultModel().isModelAvailable,
            "the real Piece13 model must load from the test host's bundle; these pins are "
                + "meaningless without it",
            file: file,
            line: line
        )
        let pipeline = DetectorPipeline()
        let startedAt = Date()
        let output = await pipeline.process(cgImage: image)
        let milliseconds = Date().timeIntervalSince(startedAt) * 1000
        print("[detection] \(fixture): \(String(format: "%.0f", milliseconds)) ms")
        return output
    }

    // MARK: - Assertions

    /// The pipeline's OWN report that it had no model: with it, every board is empty and every
    /// pin below would pass vacuously on the two synthetic fixtures.
    private func assertRealModelClassified(
        _ output: DetectionOutput,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let unavailable = output.warnings.filter { $0.message.contains("model not available") }
        XCTAssertTrue(
            unavailable.isEmpty,
            "\(fixture): the pipeline ran without its classifier — \(unavailable.map(\.message))",
            file: file,
            line: line
        )
        XCTAssertEqual(
            output.squareCrops.count,
            64,
            "\(fixture): the pipeline classified \(output.squareCrops.count) squares, not 64",
            file: file,
            line: line
        )
    }

    private func assertBoundingBox(
        _ actual: CGRect?,
        equals expected: CGRect,
        accuracy: CGFloat,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let box = try XCTUnwrap(
            actual,
            "\(fixture): no board quadrilateral was detected",
            file: file,
            line: line
        )
        XCTAssertEqual(box.origin.x, expected.origin.x, accuracy: accuracy,
                       "\(fixture): quad x (whole box \(box))", file: file, line: line)
        XCTAssertEqual(box.origin.y, expected.origin.y, accuracy: accuracy,
                       "\(fixture): quad y (whole box \(box))", file: file, line: line)
        XCTAssertEqual(box.width, expected.width, accuracy: accuracy,
                       "\(fixture): quad width (whole box \(box))", file: file, line: line)
        XCTAssertEqual(box.height, expected.height, accuracy: accuracy,
                       "\(fixture): quad height (whole box \(box))", file: file, line: line)
    }

    /// Names every occupied square, so a regression says WHICH square gained a piece.
    private func assertBoardIsEmpty(
        _ board: Board,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var occupied: [String] = []
        for rank in 0..<8 {
            for fileIndex in 0..<8 {
                if let piece = board[fileIndex, rank] {
                    let name = String(UnicodeScalar(UInt8(97 + fileIndex))) + "\(rank + 1)"
                    occupied.append("\(name)=\(piece.rawValue)")
                }
            }
        }
        XCTAssertEqual(
            occupied,
            [],
            "\(fixture): the board should be empty",
            file: file,
            line: line
        )
    }

    /// `DetectionOutput` carries no orientation, so the claim is pinned twice from what it
    /// DOES carry: the estimator's warning (emitted exactly when the estimate is not
    /// `.standard`, or when sampling failed) is absent, and re-running the estimator on the
    /// pipeline's own normalized board yields `.standard`.
    private func assertOrientationIsStandard(
        _ output: DetectionOutput,
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let orientationWarnings = output.warnings.filter {
            $0.message.contains("rotated 180") || $0.message.contains("Orientation check skipped")
        }
        XCTAssertTrue(
            orientationWarnings.isEmpty,
            "\(fixture): orientation was not standard — \(orientationWarnings.map(\.message))",
            file: file,
            line: line
        )
        let normalized = try XCTUnwrap(
            output.normalizedBoard,
            "\(fixture): the board was never normalized",
            file: file,
            line: line
        )
        let (orientation, _) = OrientationEstimator().estimateOrientation(
            normalizedBoard: normalized.image
        )
        guard case .standard = orientation else {
            XCTFail("\(fixture): orientation is \(orientation), expected .standard",
                    file: file, line: line)
            return
        }
    }

    /// The placement field of the pipeline's own FEN.
    private func placement(of output: DetectionOutput) -> String {
        String(output.fen.split(separator: " ").first ?? "")
    }

    // MARK: - F-edge (synthetic, 768×768, the edge-detector path)

    func testFEdge_quadIsExactAndBoardIsEmpty() async throws {
        let output = await runPipeline(on: SyntheticBoard.edge768(), fixture: "F-edge")

        assertRealModelClassified(output, fixture: "F-edge")
        // The detector's box spans pixel INDICES, hence 511 for a 512-px board.
        try assertBoundingBox(
            output.quadrilateral?.boundingBox,
            equals: CGRect(x: 128, y: 128, width: 511, height: 511),
            accuracy: 2,
            fixture: "F-edge"
        )
        assertBoardIsEmpty(output.board, fixture: "F-edge")
        XCTAssertEqual(placement(of: output), "8/8/8/8/8/8/8/8", "F-edge: placement")
        try assertOrientationIsStandard(output, fixture: "F-edge")
        XCTAssertFalse(output.suggestedFlipForFEN, "F-edge: nothing on the board suggests a flip")
        XCTAssertTrue(
            output.lowConfidenceSquares.isEmpty,
            "F-edge: \(output.lowConfidenceSquares.count) squares classified below 0.2"
        )
        XCTAssertEqual(
            output.warnings.count,
            1,
            "F-edge: only the low-detection-confidence warning is expected, got "
                + "\(output.warnings.map(\.message))"
        )
    }

    // MARK: - F-big (synthetic, 2880×1800, Retina-sized — the "before" wall clock)

    func testFBig_quadIsExactAndBoardIsEmpty() async throws {
        let output = await runPipeline(on: SyntheticBoard.big2880(), fixture: "F-big")

        assertRealModelClassified(output, fixture: "F-big")
        try assertBoundingBox(
            output.quadrilateral?.boundingBox,
            equals: CGRect(x: 864, y: 324, width: 1151, height: 1151),
            accuracy: 2,
            fixture: "F-big"
        )
        assertBoardIsEmpty(output.board, fixture: "F-big")
        XCTAssertEqual(placement(of: output), "8/8/8/8/8/8/8/8", "F-big: placement")
        try assertOrientationIsStandard(output, fixture: "F-big")
        XCTAssertFalse(output.suggestedFlipForFEN, "F-big: nothing on the board suggests a flip")
        XCTAssertTrue(
            output.lowConfidenceSquares.isEmpty,
            "F-big: \(output.lowConfidenceSquares.count) squares classified below 0.2"
        )
        XCTAssertEqual(
            output.warnings.count,
            1,
            "F-big: only the low-detection-confidence warning is expected, got "
                + "\(output.warnings.map(\.message))"
        )
    }

    // MARK: - F-real (file, 620×620, the fallback path)

    func testFReal_pinsAreUnchanged() async throws {
        let output = await runPipeline(on: try realFixtureImage(), fixture: "F-real")

        assertRealModelClassified(output, fixture: "F-real")
        // The fallback quad: a centred square inset by 2% of the 620-px side.
        try assertBoundingBox(
            output.quadrilateral?.boundingBox,
            equals: CGRect(x: 12.4, y: 12.4, width: 595.2, height: 595.2),
            accuracy: 1.0,
            fixture: "F-real"
        )
        XCTAssertEqual(
            placement(of: output),
            "rnbNkb1r/pppp1ppp/3ppn2/4pp2/4PP2/2N2N2/PPPP2PP/R1BQKB1R",
            "F-real: placement"
        )
        // The published board and the published FEN must be the same position.
        XCTAssertEqual(
            String(FENBuilder().makeFEN(board: output.board).split(separator: " ")[0]),
            placement(of: output),
            "F-real: output.board and output.fen disagree"
        )
        XCTAssertFalse(output.suggestedFlipForFEN, "F-real: white is at the bottom")
        XCTAssertTrue(output.suggestedCastling.white, "F-real: white castling suggestion")
        XCTAssertTrue(output.suggestedCastling.black, "F-real: black castling suggestion")
    }

    /// The two F-real pins that are threshold crossings on raw classifier logits, kept apart
    /// from the rest so a flip in them is attributable on sight (plan, Rev 4 tension T1).
    func testFReal_thresholdPins() async throws {
        let output = await runPipeline(on: try realFixtureImage(), fixture: "F-real-thresholds")

        assertRealModelClassified(output, fixture: "F-real")
        XCTAssertEqual(output.warnings.count, 44, "F-real: warning count (threshold-brittle)")
        XCTAssertEqual(
            output.lowConfidenceSquares.count,
            43,
            "F-real: low-confidence square count (threshold-brittle)"
        )
    }
}
