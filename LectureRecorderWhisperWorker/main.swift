import Darwin
import Foundation
import WhisperC

enum WhisperWorkerMainError: Error {
    case requestTooLarge
    case invalidRequest
    case unsupportedEnvelopeSchema
    case unavailableUpstreamVersion
    case responseEncodingFailed
}

func readBoundedRequest(maximumBytes: Int) throws -> Data {
    let input = FileHandle.standardInput
    var data = Data()

    while true {
        let remainingThroughOverflowSentinel = maximumBytes + 1 - data.count
        guard remainingThroughOverflowSentinel > 0 else {
            throw WhisperWorkerMainError.requestTooLarge
        }
        let chunk = try input.read(upToCount: min(64 * 1024, remainingThroughOverflowSentinel)) ?? Data()
        guard !chunk.isEmpty else {
            return data
        }
        data.append(chunk)
        guard data.count <= maximumBytes else {
            throw WhisperWorkerMainError.requestTooLarge
        }
    }
}

func diagnostic(for error: Error) -> String {
    switch error {
    case WhisperWorkerMainError.requestTooLarge:
        return "Capability-probe request exceeded the permitted byte limit."
    case WhisperWorkerMainError.invalidRequest:
        return "Capability-probe request was malformed."
    case WhisperWorkerMainError.unsupportedEnvelopeSchema:
        return "Capability-probe request used an unsupported envelope schema."
    case WhisperWorkerMainError.unavailableUpstreamVersion:
        return "whisper_version() returned no version."
    case WhisperWorkerMainError.responseEncodingFailed:
        return "Capability-probe response could not be encoded."
    default:
        return "Capability-probe helper failed."
    }
}

do {
    let requestData = try readBoundedRequest(maximumBytes: WhisperWorkerConstants.maximumRequestBytes)
    guard let request = try? JSONDecoder().decode(WhisperWorkerRequestEnvelope.self, from: requestData) else {
        throw WhisperWorkerMainError.invalidRequest
    }
    guard request.schemaVersion == WhisperWorkerConstants.envelopeSchemaVersion else {
        throw WhisperWorkerMainError.unsupportedEnvelopeSchema
    }
    guard let versionPointer = whisper_version() else {
        throw WhisperWorkerMainError.unavailableUpstreamVersion
    }

    let response = WhisperWorkerResponseEnvelope(
        schemaVersion: WhisperWorkerConstants.envelopeSchemaVersion,
        requestID: request.requestID,
        attemptID: request.attemptID,
        sessionID: request.sessionID,
        chunkSequenceNumber: request.chunkSequenceNumber,
        sourceIdentity: request.sourceIdentity,
        workerIdentifier: WhisperWorkerConstants.workerIdentifier,
        workerVersion: WhisperWorkerConstants.implementationVersion,
        outcome: .success,
        output: WhisperProbeOutput(
            schemaVersion: WhisperWorkerConstants.capabilitySchemaVersion,
            upstreamVersion: String(cString: versionPointer)
        ),
        failure: nil
    )

    guard let responseData = try? JSONEncoder().encode(response) else {
        throw WhisperWorkerMainError.responseEncodingFailed
    }
    FileHandle.standardOutput.write(responseData)
    exit(EXIT_SUCCESS)
} catch {
    let boundedDiagnostic = String(diagnostic(for: error).prefix(4096))
    FileHandle.standardError.write(Data(boundedDiagnostic.utf8))
    exit(EXIT_FAILURE)
}
