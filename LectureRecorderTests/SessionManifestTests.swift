import XCTest
@testable import LectureRecorder

final class SessionManifestTests: XCTestCase {
    func testNewSessionHasExpectedDefaults() {
        let id = UUID()
        let manifest = SessionManifest.newSession(
            id: id,
            audioFormat: .defaultTarget,
            targetChunkDurationSeconds: 30
        )

        XCTAssertEqual(manifest.schemaVersion, SessionManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.sessionID, id)
        XCTAssertEqual(manifest.status, .recording)
        XCTAssertNil(manifest.endDate)
        XCTAssertTrue(manifest.chunks.isEmpty)
        XCTAssertFalse(manifest.endedCleanly)
        XCTAssertNil(manifest.endReason)
        XCTAssertNil(manifest.failureDescription)
    }

    func testManifestRoundTripsThroughJSON() throws {
        var manifest = SessionManifest.newSession(
            id: UUID(),
            audioFormat: .defaultTarget,
            targetChunkDurationSeconds: 30
        )
        manifest.chunks.append(
            ChunkMetadata(
                sequenceNumber: 1,
                fileName: "chunk_000001.caf",
                startOffsetSeconds: 0,
                durationSeconds: 30,
                state: .completed
            )
        )
        manifest.endDate = Date()
        manifest.status = .completed
        manifest.endReason = .userStopped
        manifest.endedCleanly = true

        let data = try AtomicFileWriter.defaultEncoder.encode(manifest)
        let decoded = try AtomicFileWriter.defaultDecoder.decode(SessionManifest.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, manifest.schemaVersion)
        XCTAssertEqual(decoded.sessionID, manifest.sessionID)
        XCTAssertEqual(decoded.status, manifest.status)
        XCTAssertEqual(decoded.audioFormat, manifest.audioFormat)
        XCTAssertEqual(decoded.targetChunkDurationSeconds, manifest.targetChunkDurationSeconds)
        XCTAssertEqual(decoded.chunks, manifest.chunks)
        XCTAssertEqual(decoded.endReason, manifest.endReason)
        XCTAssertEqual(decoded.endedCleanly, manifest.endedCleanly)
        XCTAssertEqual(decoded.failureDescription, manifest.failureDescription)

        XCTAssertEqual(
            decoded.creationDate.timeIntervalSince1970,
            manifest.creationDate.timeIntervalSince1970,
            accuracy: 0.001
        )
        let decodedEnd = try XCTUnwrap(decoded.endDate)
        let originalEnd = try XCTUnwrap(manifest.endDate)
        XCTAssertEqual(decodedEnd.timeIntervalSince1970, originalEnd.timeIntervalSince1970, accuracy: 0.001)
    }

    func testManifestPersistsFailureDescription() throws {
        var manifest = SessionManifest.newSession(
            id: UUID(),
            audioFormat: .defaultTarget,
            targetChunkDurationSeconds: 30
        )
        manifest.status = .failed
        manifest.endReason = .error
        manifest.endedCleanly = false
        manifest.failureDescription = "Disk full while creating logger"

        let data = try AtomicFileWriter.defaultEncoder.encode(manifest)
        let decoded = try AtomicFileWriter.defaultDecoder.decode(SessionManifest.self, from: data)

        XCTAssertEqual(decoded.status, .failed)
        XCTAssertEqual(decoded.failureDescription, "Disk full while creating logger")
    }

    func testAudioFormatDefaultTargetValues() {
        let format = AudioFormatDescriptor.defaultTarget
        XCTAssertEqual(format.sampleRate, 44_100)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.bitsPerChannel, 32)
        XCTAssertEqual(format.formatIdentifier, "lpcm-float32")
    }
}
