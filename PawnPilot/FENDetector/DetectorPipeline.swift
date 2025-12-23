import Foundation
import CoreGraphics

public struct DetectionWarning: Identifiable, Hashable {
    public let id = UUID()
    public let message: String
}

public struct LowConfidenceSquare: Identifiable, Hashable {
    public let id = UUID()
    public let file: Int
    public let rank: Int
    public let polygon: [CGPoint]
}

public struct DetectionOutput {
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

public struct CastlingSuggestion {
    public let white: Bool
    public let black: Bool
}

public final class DetectorPipeline {
    private let boardDetector: BoardDetector
    private let normalizer: BoardNormalizer
    private let extractor: SquareExtractor
    private let classifier: PieceClassifier
    private let fenBuilder: FENBuilder
    private let orientationEstimator: OrientationEstimator

    public init(
        boardDetector: BoardDetector = BoardDetector(),
        normalizer: BoardNormalizer = BoardNormalizer(),
        extractor: SquareExtractor = SquareExtractor(padFraction: 0.0, refinedPadFraction: 0.0, useGridRefinement: false),
        classifier: PieceClassifier = PieceClassifier.loadDefaultModel(),
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

    public func process(cgImage: CGImage) async -> DetectionOutput {
        var warnings: [DetectionWarning] = []
        var quad: BoardQuadrilateral?
        var normalized: NormalizedBoard?
        var orientation: BoardOrientation = .standard

        do {
            let detection = try await boardDetector.detectBoard(in: cgImage)
            quad = detection.quad
            if detection.confidence < 0.4 {
                warnings.append(DetectionWarning(message: "Board detection confidence is low (\(String(format: "%.2f", detection.confidence)))."))
            }
        } catch {
            warnings.append(DetectionWarning(message: "Board not detected: \(error)."))
        }

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

        var board = Board()
        var lowConfidenceSquares: [LowConfidenceSquare] = []
        var squareCrops: [SquareCrop] = []
        var flipSuggestion = false
        if let normalized = normalized {
            do {
                let rawCrops = try extractor.extractSquares(from: normalized)
                let crops = rawCrops.map { crop in
                    let cleaned = ImageSanitizer.sanitize(image: crop.image)
                    return SquareCrop(image: cleaned, position: crop.position)
                }
                squareCrops = crops
                let classified = classifier.classify(crops: crops)

                flipSuggestion = flipSuggestionFrom(classified: classified)

                for result in classified {
                    let mapped = mapPosition(result.position, orientation: orientation)
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
