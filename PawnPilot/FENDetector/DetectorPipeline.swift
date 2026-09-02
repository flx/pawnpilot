import Foundation
import CoreGraphics

nonisolated public struct DetectionWarning: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let message: String
}

nonisolated public struct LowConfidenceSquare: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let file: Int
    public let rank: Int
    public let polygon: [CGPoint]
}

nonisolated public struct DetectionOutput: Sendable {
    public let quadrilateral: BoardQuadrilateral?
    public let normalizedBoard: NormalizedBoard?
    public let board: Board
    public let fen: String
    public let warnings: [DetectionWarning]
    public let lowConfidenceSquares: [LowConfidenceSquare]
    public let squareCrops: [SquareCrop]
    public let suggestedFlipForFEN: Bool
    public let suggestedCastling: CastlingSuggestion
}

nonisolated public struct CastlingSuggestion: Sendable {
    public let white: Bool
    public let black: Bool
}

nonisolated public final class DetectorPipeline: Sendable {
    private let boardDetector: BoardDetector
    private let normalizer: BoardNormalizer
    private let extractor: SquareExtractor
    private let classifier: any PieceClassifying
    private let fenBuilder: FENBuilder
    private let orientationEstimator: OrientationEstimator

    /// What `process` returns when the detection was cancelled: an empty board and its FEN,
    /// no quadrilateral and no crops, and the one warning that says so. A cancelled run never
    /// returns a half-classified board — a caller that publishes this shows an empty board,
    /// not a wrong one.
    public static let cancelledOutput: DetectionOutput = {
        let board = Board()
        return DetectionOutput(
            quadrilateral: nil,
            normalizedBoard: nil,
            board: board,
            fen: FENBuilder().makeFEN(board: board),
            warnings: [DetectionWarning(message: "Detection cancelled.")],
            lowConfidenceSquares: [],
            squareCrops: [],
            suggestedFlipForFEN: false,
            suggestedCastling: CastlingSuggestion(white: false, black: false)
        )
    }()

    public init(
        boardDetector: BoardDetector = BoardDetector(),
        normalizer: BoardNormalizer = BoardNormalizer(),
        extractor: SquareExtractor = SquareExtractor(padFraction: 0.0, refinedPadFraction: 0.0, useGridRefinement: false),
        classifier: any PieceClassifying = PieceClassifier.loadDefaultModel(),
        fenBuilder: FENBuilder = FENBuilder(),
        orientationEstimator: OrientationEstimator = OrientationEstimator()
    ) {
        self.boardDetector = boardDetector
        self.normalizer = normalizer
        self.extractor = extractor
        self.classifier = classifier
        self.fenBuilder = fenBuilder
        self.orientationEstimator = orientationEstimator
    }

    /// Every phase this method calls asserts, in Debug, that it is NOT on the main queue; the
    /// assertions are only sound because `@concurrent` guarantees this body runs on the
    /// cooperative pool no matter which actor called it.
    private static func assertOffMain() {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
    }

    @concurrent nonisolated public func process(cgImage: CGImage) async -> DetectionOutput {
        Self.assertOffMain()
        var warnings: [DetectionWarning] = []
        var quad: BoardQuadrilateral?
        var normalized: NormalizedBoard?
        var orientation: BoardOrientation = .standard

        do {
            let detection = try boardDetector.detectBoard(in: cgImage)
            quad = detection.quad
            if detection.confidence < 0.4 {
                warnings.append(DetectionWarning(message: "Board detection confidence is low (\(String(format: "%.2f", detection.confidence)))."))
            }
        } catch {
            warnings.append(DetectionWarning(message: "Board not detected: \(error)."))
        }
        // The scan stops itself when cancelled, but it then falls through to the centred-square
        // fallback, so the quad it produced has to be thrown away here.
        if Task.isCancelled { return Self.cancelledOutput }

        if let quad = quad {
            do {
                normalized = try normalizer.normalize(image: cgImage, quad: quad)
                if let normalizedImage = normalized?.image {
                    let (orient, orientWarning) = orientationEstimator.estimateOrientation(normalizedBoard: normalizedImage)
                    orientation = orient
                    if let w = orientWarning { warnings.append(w) }
                }
            } catch {
                warnings.append(DetectionWarning(message: "Failed to normalize board: \(error)."))
            }
        }
        if Task.isCancelled { return Self.cancelledOutput }

        var board = Board()
        var lowConfidenceSquares: [LowConfidenceSquare] = []
        var squareCrops: [SquareCrop] = []
        var flipSuggestion = false
        if let normalized = normalized {
            do {
                let rawCrops = try extractor.extractSquares(from: normalized)
                // The one and only sanitising pass: the classifier no longer repeats it.
                let crops = rawCrops.map { crop in
                    let cleaned = ImageSanitizer.sanitize(image: crop.image)
                    return SquareCrop(image: cleaned, position: crop.position)
                }
                squareCrops = crops
                if Task.isCancelled { return Self.cancelledOutput }
                let classified = await classifier.classify(crops: crops)
                // A short result means the fan-out was cancelled part-way: some crops were
                // never classified, so the board would be wrong, not merely incomplete.
                if classified.count != crops.count { return Self.cancelledOutput }

                flipSuggestion = flipSuggestionFrom(classified: classified)

                for result in classified {
                    let mapped = mapPosition(result.position, orientation: orientation)
                    // `Board`'s subscript traps on an off-board index, in -O too, and the
                    // classifier is an injectable public seam: a conformer that reports a
                    // position outside 0..<8 must lose its result, not kill the app. Skipping
                    // the whole result also keeps its note and its low-confidence entry out,
                    // so warning order and text are untouched for every valid result.
                    guard (0..<8).contains(mapped.file), (0..<8).contains(mapped.rank) else {
                        continue
                    }
                    board[mapped.file, mapped.rank] = result.piece
                    if let note = result.note {
                        warnings.append(DetectionWarning(message: "Square \(mapped.file),\(mapped.rank): \(note)"))
                    }
                    if let quad = quad, classifier.isModelAvailable, result.confidence < 0.2 {
                        let poly = BoardGeometry.squarePolygon(file: mapped.file, rank: mapped.rank, quad: quad)
                        lowConfidenceSquares.append(LowConfidenceSquare(file: mapped.file, rank: mapped.rank, polygon: poly))
                    }
                }
                if !classifier.isModelAvailable {
                    warnings.append(DetectionWarning(message: "Piece classifier model not available; board will be empty."))
                }
            } catch {
                warnings.append(DetectionWarning(message: "Failed to extract squares: \(error)."))
            }
        }

        let castling = castlingSuggestion(board: board)
        let fen = fenBuilder.makeFEN(board: board, castlingAvailability: castlingString(board: board, whiteAllowed: castling.white, blackAllowed: castling.black))
        return DetectionOutput(
            quadrilateral: quad,
            normalizedBoard: normalized,
            board: board,
            fen: fen,
            warnings: warnings,
            lowConfidenceSquares: lowConfidenceSquares,
            squareCrops: squareCrops,
            suggestedFlipForFEN: flipSuggestion,
            suggestedCastling: CastlingSuggestion(white: castling.white, black: castling.black)
        )
    }

    private func mapPosition(_ pos: (file: Int, rank: Int), orientation: BoardOrientation) -> (file: Int, rank: Int) {
        switch orientation {
        case .standard:
            return pos
        case .rotated180:
            return (file: 7 - pos.file, rank: 7 - pos.rank)
        }
    }

    private func flipSuggestionFrom(classified: [PieceClassificationResult]) -> Bool {
        var whiteTop = 0
        var whiteBottom = 0
        for res in classified {
            guard let piece = res.piece else { continue }
            if piece.isWhite {
                if res.position.rank >= 4 {
                    whiteTop += 1
                } else {
                    whiteBottom += 1
                }
            }
        }
        return whiteTop > whiteBottom + 1
    }

    private func castlingSuggestion(board: Board) -> (white: Bool, black: Bool) {
        let whiteKing = board[4, 0] == .whiteKing
        let whiteRookA = board[0, 0] == .whiteRook
        let whiteRookH = board[7, 0] == .whiteRook
        let blackKing = board[4, 7] == .blackKing
        let blackRookA = board[0, 7] == .blackRook
        let blackRookH = board[7, 7] == .blackRook
        return (
            white: whiteKing && (whiteRookA || whiteRookH),
            black: blackKing && (blackRookA || blackRookH)
        )
    }

    private func castlingString(board: Board, whiteAllowed: Bool, blackAllowed: Bool) -> String {
        var rights = ""
        if whiteAllowed && board[4,0] == .whiteKing {
            if board[7,0] == .whiteRook { rights.append("K") }
            if board[0,0] == .whiteRook { rights.append("Q") }
        }
        if blackAllowed && board[4,7] == .blackKing {
            if board[7,7] == .blackRook { rights.append("k") }
            if board[0,7] == .blackRook { rights.append("q") }
        }
        return rights.isEmpty ? "-" : rights
    }
}
