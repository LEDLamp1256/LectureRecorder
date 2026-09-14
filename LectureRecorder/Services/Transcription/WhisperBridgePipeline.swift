import Foundation

nonisolated protocol WhisperEngineBoundary {
    associatedtype Context
    func initialize() -> Context?
    func destroy(_ context: Context)
    func run(_ context: Context, samples: [Float]) -> Int32
    func segmentCount(_ context: Context) -> Int
    func segmentStart(_ context: Context, index: Int) -> Int64
    func segmentEnd(_ context: Context, index: Int) -> Int64
    func segmentText(_ context: Context, index: Int) -> String?
}

nonisolated struct WhisperBridgeSegment: Sendable, Equatable {
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let text: String
}

nonisolated enum WhisperBridgePipelineError: Error, Sendable, Equatable {
    case initialization
    case inference
    case malformedOutput
}

nonisolated enum WhisperBridgePipeline {
    static func infer<Boundary: WhisperEngineBoundary>(
        samples: [Float],
        boundary: Boundary,
        maximumSegments: Int = 10_000,
        maximumSegmentTextBytes: Int = 64 * 1024,
        initialized: () -> Void = {}
    ) throws -> [WhisperBridgeSegment] {
        guard !samples.isEmpty, samples.count <= Int(Int32.max),
              let context = boundary.initialize() else {
            throw WhisperBridgePipelineError.initialization
        }
        defer { boundary.destroy(context) }
        initialized()
        guard boundary.run(context, samples: samples) == 0 else {
            throw WhisperBridgePipelineError.inference
        }
        let count = boundary.segmentCount(context)
        guard count >= 0, count <= maximumSegments else { throw WhisperBridgePipelineError.malformedOutput }
        var segments: [WhisperBridgeSegment] = []
        segments.reserveCapacity(count)
        var priorEnd: Int64 = 0
        for index in 0..<count {
            guard let start = try? WhisperTimestamp.milliseconds(fromTenMillisecondUnits: boundary.segmentStart(context, index: index)),
                  let end = try? WhisperTimestamp.milliseconds(fromTenMillisecondUnits: boundary.segmentEnd(context, index: index)),
                  start >= priorEnd, end >= start,
                  let text = boundary.segmentText(context, index: index),
                  text.utf8.count <= maximumSegmentTextBytes else {
                throw WhisperBridgePipelineError.malformedOutput
            }
            segments.append(WhisperBridgeSegment(startMilliseconds: start, endMilliseconds: end, text: text))
            priorEnd = end
        }
        return segments
    }
}
