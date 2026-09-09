import AVFoundation
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
        XCTAssertNil(manifest.observedCaptureCopyFailureCount)
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
                frameCount: 1_323_000, // 30s @ 44,100 Hz
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
        XCTAssertEqual(decoded.chunks.first?.frameCount, 1_323_000)
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

    /// A manifest written before `observedCaptureCopyFailureCount` existed
    /// has no such key in its JSON at all. Codable synthesis must decode
    /// that absence as `nil`, not fail or default to `0`.
    func testHistoricalManifestWithoutCopyFailureCountKeyDecodesAsNil() throws {
        let json = """
        {
            "schemaVersion": 1,
            "sessionID": "3B1A2C4E-5678-4ABC-9012-3456789ABCDE",
            "creationDate": "2026-01-01T00:00:00.000Z",
            "endDate": "2026-01-01T00:30:00.000Z",
            "status": "completed",
            "audioFormat": {
                "sampleRate": 44100,
                "channelCount": 1,
                "bitsPerChannel": 32,
                "formatIdentifier": "lpcm-float32"
            },
            "targetChunkDurationSeconds": 30,
            "chunks": [],
            "endReason": "userStopped",
            "endedCleanly": true,
            "failureDescription": null
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        let decoded = try AtomicFileWriter.defaultDecoder.decode(SessionManifest.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertNil(decoded.observedCaptureCopyFailureCount)
    }

    func testManifestWithNilCopyFailureCountRoundTrips() throws {
        var manifest = SessionManifest.newSession(
            id: UUID(),
            audioFormat: .defaultTarget,
            targetChunkDurationSeconds: 30
        )
        manifest.observedCaptureCopyFailureCount = nil

        let data = try AtomicFileWriter.defaultEncoder.encode(manifest)
        let decoded = try AtomicFileWriter.defaultDecoder.decode(SessionManifest.self, from: data)

        XCTAssertNil(decoded.observedCaptureCopyFailureCount)
    }

    func testManifestWithZeroCopyFailureCountRoundTrips() throws {
        var manifest = SessionManifest.newSession(
            id: UUID(),
            audioFormat: .defaultTarget,
            targetChunkDurationSeconds: 30
        )
        manifest.observedCaptureCopyFailureCount = 0

        let data = try AtomicFileWriter.defaultEncoder.encode(manifest)
        let decoded = try AtomicFileWriter.defaultDecoder.decode(SessionManifest.self, from: data)

        XCTAssertEqual(decoded.observedCaptureCopyFailureCount, 0)
    }

    func testManifestWithPositiveCopyFailureCountRoundTrips() throws {
        var manifest = SessionManifest.newSession(
            id: UUID(),
            audioFormat: .defaultTarget,
            targetChunkDurationSeconds: 30
        )
        manifest.observedCaptureCopyFailureCount = 7

        let data = try AtomicFileWriter.defaultEncoder.encode(manifest)
        let decoded = try AtomicFileWriter.defaultDecoder.decode(SessionManifest.self, from: data)

        XCTAssertEqual(decoded.observedCaptureCopyFailureCount, 7)
    }

    /// This proves only that the bridge maps a validated `AVAudioFormat`'s
    /// fields correctly — it does not exercise real capture hardware and
    /// does not prove what format a real `.caf` chunk file stores on disk.
    func testAudioFormatBridgeMapsRepresentativeFloat32Format() throws {
        let avFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )

        let descriptor = makeAudioFormatDescriptor(from: avFormat)

        XCTAssertEqual(descriptor.sampleRate, 48_000)
        XCTAssertEqual(descriptor.channelCount, 2)
        XCTAssertEqual(descriptor.bitsPerChannel, 32)
        XCTAssertEqual(descriptor.formatIdentifier, "lpcm-float32")
    }
}
