import Foundation

nonisolated enum WhisperTimestampError: Error, Sendable, Equatable {
    case negative
    case overflow
}

nonisolated enum WhisperTimestamp {
    static func milliseconds(fromTenMillisecondUnits value: Int64) throws -> Int64 {
        guard value >= 0 else { throw WhisperTimestampError.negative }
        let result = value.multipliedReportingOverflow(by: 10)
        guard !result.overflow else { throw WhisperTimestampError.overflow }
        return result.partialValue
    }
}
