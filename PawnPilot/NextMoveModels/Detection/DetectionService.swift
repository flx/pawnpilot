import Foundation
import CoreGraphics
import Combine
//import FENDetectorKit

public enum DetectionStatus {
    case idle
    case running
    case failed(String)
    case succeeded(DetectionOutput)
}

public final class DetectionService: ObservableObject {
    @Published public private(set) var status: DetectionStatus = .idle

    private let pipeline: DetectorPipeline

    public init(pipeline: DetectorPipeline = DetectorPipeline()) {
        self.pipeline = pipeline
    }

    public func detectBoard(in image: CGImage) {
        status = .running
        Task.detached { [weak self] in
            guard let self else { return }
            let output = await self.pipeline.process(cgImage: image)
            await MainActor.run {
                self.status = .succeeded(output)
            }
        }
    }
}
