import Foundation
import CoreGraphics
import CoreML
import Vision

public struct PieceClassificationResult {
    public let position: (file: Int, rank: Int)
    public let piece: Piece?
    public let confidence: Float
    public let note: String?
}

/// Single-model classifier: 13 classes (empty + 12 pieces).
public final class PieceClassifier {
    private let model: VNCoreMLModel?
    private let queue = DispatchQueue(label: "PieceClassifierQueue")
    private let labels: [String] = ["empty", "P", "N", "B", "R", "Q", "K", "p", "n", "b", "r", "q", "k"]
    private let loggingEnabled: Bool

    public init(model: MLModel? = nil, loggingEnabled: Bool = false) {
        self.model = model.flatMap { try? VNCoreMLModel(for: $0) }
        self.loggingEnabled = loggingEnabled
    }

    public static func loadDefaultModel() -> PieceClassifier {
        let bundle = Bundle.main
        let compiledURL = bundle.url(forResource: "Piece13", withExtension: "mlmodelc")
        let packageURL = bundle.url(forResource: "Piece13", withExtension: "mlpackage")
        let rawModelURL = bundle.url(forResource: "model", withExtension: "mlmodel")

        let ml: MLModel?
        if let compiled = compiledURL {
            ml = try? MLModel(contentsOf: compiled)
        } else if let pkg = packageURL {
            // Attempt to load or compile the packaged model at runtime.
            ml = (try? MLModel(contentsOf: pkg)) ?? {
                guard let compiled = try? MLModel.compileModel(at: pkg) else { return nil }
                return try? MLModel(contentsOf: compiled)
            }()
        } else if let raw = rawModelURL {
            ml = (try? MLModel(contentsOf: raw)) ?? {
                guard let compiled = try? MLModel.compileModel(at: raw) else { return nil }
                return try? MLModel(contentsOf: compiled)
            }()
        } else {
            ml = nil
        }
        return PieceClassifier(model: ml, loggingEnabled: false)
    }

    public var isModelAvailable: Bool {
        model != nil
    }

    public func classify(crops: [SquareCrop]) -> [PieceClassificationResult] {
        guard let model else {
            return crops.map { crop in
                PieceClassificationResult(position: crop.position, piece: nil, confidence: 0, note: "No model available")
            }
        }
        if loggingEnabled {
            print("PieceClassifier: using 13-class CoreML model on \(crops.count) crops")
        }
        return queue.sync {
            crops.map { crop in
                classifySquare(crop: crop, model: model)
            }
        }
    }

    private func classifySquare(crop: SquareCrop, model: VNCoreMLModel) -> PieceClassificationResult {
        let image = ImageSanitizer.sanitize(image: crop.image)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNCoreMLRequest(model: model)
        do {
            try handler.perform([request])
            if let obs = (request.results as? [VNClassificationObservation])?.first {
                let label = obs.identifier
                let conf = obs.confidence
                let piece = Piece(rawValue: label)
                let note = conf < 0.2 ? "Low confidence" : nil
                return PieceClassificationResult(position: crop.position, piece: piece, confidence: conf, note: note)
            }
        } catch {
            return PieceClassificationResult(position: crop.position, piece: nil, confidence: 0, note: "Classification failed: \(error)")
        }
        return PieceClassificationResult(position: crop.position, piece: nil, confidence: 0, note: "No classification result")
    }

}
