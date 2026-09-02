import Foundation
import CoreGraphics
import CoreML
import Vision

nonisolated public struct PieceClassificationResult: Sendable {
    public let position: (file: Int, rank: Int)
    public let piece: Piece?
    public let confidence: Float
    public let note: String?
}

/// The pipeline's classifier seam. `async` on purpose: the real classifier fans its 64 crops
/// out over a task group, and `nonisolated` on purpose: the pipeline is `@concurrent`, and a
/// protocol declared in this module would otherwise be inferred main-actor-isolated and hop
/// every implementation back onto the main actor.
///
/// `classify` returns ONE result per crop, in any order. Returning FEWER results than it was
/// given is how an implementation reports that the run was cancelled part-way; the pipeline
/// treats a short result as a cancellation and publishes nothing.
nonisolated public protocol PieceClassifying: Sendable {
    var isModelAvailable: Bool { get }
    func classify(crops: [SquareCrop]) async -> [PieceClassificationResult]
}

/// Single-model classifier: 13 classes (empty + 12 pieces).
nonisolated public final class PieceClassifier: PieceClassifying, @unchecked Sendable {
    /// The `VNCoreMLModel` is shared by all 64 concurrent classifications. Vision and CoreML
    /// document prediction on one model as thread-safe, and the plan's `probe6/concprobe` ran
    /// 64 real classifications with a peak of 10 in flight and zero label differences against
    /// the serial run — that measurement is what `@unchecked` stands on here.
    private struct ClassifierModel: @unchecked Sendable {
        let vision: VNCoreMLModel
    }

    private let model: ClassifierModel?
    private let labels: [String] = ["empty", "P", "N", "B", "R", "Q", "K", "p", "n", "b", "r", "q", "k"]
    private let loggingEnabled: Bool

    public init(model: MLModel? = nil, loggingEnabled: Bool = false) {
        self.model = model.flatMap { try? VNCoreMLModel(for: $0) }.map(ClassifierModel.init(vision:))
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

    /// The pipeline is this method's only caller and it runs it off the main actor (E9 of
    /// `(detection-off-main-actor)`).
    private static func assertOffMain() {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
    }

    /// Classifies the crops the pipeline already sanitised — this method does NOT sanitise
    /// again. A cancelled fan-out yields fewer than `crops.count` results, which is the
    /// protocol's cancellation signal.
    public func classify(crops: [SquareCrop]) async -> [PieceClassificationResult] {
        Self.assertOffMain()
        guard let model else {
            return crops.map { crop in
                PieceClassificationResult(position: crop.position, piece: nil, confidence: 0, note: "No model available")
            }
        }
        if loggingEnabled {
            print("PieceClassifier: using 13-class CoreML model on \(crops.count) crops")
        }
        let results = await Self.classifyConcurrently(count: crops.count) { index in
            Self.classifySquare(crop: crops[index], model: model)
        }
        return results.compactMap { $0 }
    }

    /// Runs `work` for every index in `0..<count` on the cooperative pool and returns the
    /// results IN INDEX ORDER. A child that finds its task cancelled before it starts returns
    /// `nil` for its slot and does no work; children already running are not interrupted.
    ///
    /// Kept separate from `classify` so the fan-out's ordering, overlap and cancellation can
    /// be tested without a CoreML model (E4/E5b).
    static func classifyConcurrently<T: Sendable>(
        count: Int,
        work: @Sendable @escaping (Int) -> T
    ) async -> [T?] {
        guard count > 0 else { return [] }
        return await withTaskGroup(of: (Int, T?).self, returning: [T?].self) { group in
            for index in 0..<count {
                group.addTask {
                    if Task.isCancelled { return (index, nil) }
                    return (index, work(index))
                }
            }
            var results = [T?](repeating: nil, count: count)
            for await (index, value) in group {
                results[index] = value
            }
            return results
        }
    }

    private static func classifySquare(crop: SquareCrop, model: ClassifierModel) -> PieceClassificationResult {
        let handler = VNImageRequestHandler(cgImage: crop.image, options: [:])
        let request = VNCoreMLRequest(model: model.vision)
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
