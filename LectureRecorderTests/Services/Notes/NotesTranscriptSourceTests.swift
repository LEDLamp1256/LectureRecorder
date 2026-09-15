import XCTest
@testable import LectureRecorder

private enum NotesTestFixtures {
    static func audioFormat() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, formatIdentifier: "lpcm-float32")
    }

    static func manifest(sessionID: UUID, chunkCount: Int) -> SessionManifest {
        var manifest = SessionManifest.newSession(id: sessionID, audioFormat: audioFormat(), targetChunkDurationSeconds: 30)
        manifest.status = .completed
        manifest.chunks = (0..<chunkCount).map { seq in
            ChunkMetadata(
                sequenceNumber: seq,
                fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: seq),
                startOffsetSeconds: Double(seq) * 30,
                durationSeconds: 30,
                frameCount: 1_000,
                state: .completed
            )
        }
        return manifest
    }

    static func source(_ manifest: SessionManifest, _ seq: Int) -> TranscriptionSourceSnapshot {
        let chunk = manifest.chunks[seq]
        return TranscriptionSourceSnapshot(
            sessionID: manifest.sessionID,
            chunkSequenceNumber: seq,
            chunkFileName: chunk.fileName,
            frameCount: chunk.frameCount,
            startOffsetSeconds: chunk.startOffsetSeconds,
            durationSeconds: chunk.durationSeconds,
            audioFormat: manifest.audioFormat
        )
    }

    static func job(_ manifest: SessionManifest, _ seq: Int) -> TranscriptionJob {
        TranscriptionJob(
            schemaVersion: TranscriptionJob.currentSchemaVersion,
            source: source(manifest, seq),
            state: .completed,
            currentAttemptID: nil,
            attemptCount: 1,
            lastFailure: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
    }

    static func result(_ manifest: SessionManifest, _ seq: Int, text: String) -> TranscriptResult {
        TranscriptResult(
            schemaVersion: TranscriptResult.legacySchemaVersion,
            source: source(manifest, seq),
            output: TranscriptionEngineOutput(
                text: text, engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil
            ),
            attemptID: UUID(),
            completedDate: Date()
        )
    }

    static func completedTranscript(sessionID: UUID = UUID(), chunkTexts: [String]) -> (
        manifest: SessionManifest, jobs: [TranscriptionJob], results: [TranscriptResult]
    ) {
        let manifest = manifest(sessionID: sessionID, chunkCount: chunkTexts.count)
        let jobs = chunkTexts.indices.map { job(manifest, $0) }
        let results = chunkTexts.indices.map { result(manifest, $0, text: chunkTexts[$0]) }
        return (manifest, jobs, results)
    }

    /// Hand-crafts a manifest/jobs/results triple with caller-chosen chunk
    /// `sequenceNumber`s (rather than the automatic contiguous `0..<count`
    /// `completedTranscript` always produces) — every chunk still has a
    /// perfectly matching job/result, so `isCompletionValid` passes, letting
    /// tests exercise `NotesTranscriptSourceBuilder`'s own independent
    /// topology check in isolation.
    static func completedTranscriptWithCustomSequenceNumbers(
        sessionID: UUID = UUID(),
        sequenceNumbers: [Int],
        chunkTexts: [String]
    ) -> (manifest: SessionManifest, jobs: [TranscriptionJob], results: [TranscriptResult]) {
        var manifest = manifest(sessionID: sessionID, chunkCount: sequenceNumbers.count)
        // Derive every per-chunk field from `sequenceNumber` itself (not
        // from the chunk's original array index) so that two entries
        // sharing the same duplicated sequence number are byte-for-byte
        // identical — otherwise `isCompletionValid`'s per-sequence
        // dictionary lookup would see a spurious source mismatch and
        // reject the fixture before it ever reaches the topology check
        // this fixture exists to isolate.
        manifest.chunks = zip(sequenceNumbers, manifest.chunks).map { sequenceNumber, chunk in
            var chunk = chunk
            chunk.sequenceNumber = sequenceNumber
            chunk.fileName = TranscriptionArtifactPaths.canonicalChunkFileName(for: sequenceNumber)
            chunk.startOffsetSeconds = Double(sequenceNumber) * 30
            return chunk
        }
        let jobs = manifest.chunks.indices.map { index -> TranscriptionJob in
            let chunk = manifest.chunks[index]
            let chunkSource = TranscriptionSourceSnapshot(
                sessionID: manifest.sessionID,
                chunkSequenceNumber: chunk.sequenceNumber,
                chunkFileName: chunk.fileName,
                frameCount: chunk.frameCount,
                startOffsetSeconds: chunk.startOffsetSeconds,
                durationSeconds: chunk.durationSeconds,
                audioFormat: manifest.audioFormat
            )
            return TranscriptionJob(
                schemaVersion: TranscriptionJob.currentSchemaVersion,
                source: chunkSource,
                state: .completed,
                currentAttemptID: nil,
                attemptCount: 1,
                lastFailure: nil,
                createdDate: Date(),
                updatedDate: Date()
            )
        }
        let results = manifest.chunks.indices.map { index -> TranscriptResult in
            let chunk = manifest.chunks[index]
            let chunkSource = TranscriptionSourceSnapshot(
                sessionID: manifest.sessionID,
                chunkSequenceNumber: chunk.sequenceNumber,
                chunkFileName: chunk.fileName,
                frameCount: chunk.frameCount,
                startOffsetSeconds: chunk.startOffsetSeconds,
                durationSeconds: chunk.durationSeconds,
                audioFormat: manifest.audioFormat
            )
            return TranscriptResult(
                schemaVersion: TranscriptResult.legacySchemaVersion,
                source: chunkSource,
                output: TranscriptionEngineOutput(
                    text: chunkTexts[index], engineIdentifier: "fake", modelIdentifier: nil, language: nil, segments: nil, engineVersion: nil
                ),
                attemptID: UUID(),
                completedDate: Date()
            )
        }
        return (manifest, jobs, results)
    }
}

final class NotesTranscriptSourceTests: XCTestCase {
    func testValidCompletedMultiChunkTranscriptProducesDeterministicOrderedUnits() throws {
        let fixture = NotesTestFixtures.completedTranscript(chunkTexts: ["hello", "world", "third"])
        let snapshot = try NotesTranscriptSourceBuilder.build(
            manifest: fixture.manifest, jobs: fixture.jobs, results: fixture.results
        )

        XCTAssertEqual(snapshot.sessionID, fixture.manifest.sessionID)
        XCTAssertEqual(snapshot.units.map(\.sequenceNumber), [0, 1, 2])
        XCTAssertEqual(snapshot.units.map(\.text), ["hello", "world", "third"])
    }

    func testIncompleteTranscriptIsRejectedAsNotesInput() {
        let fixture = NotesTestFixtures.completedTranscript(chunkTexts: ["hello", "world"])
        let incompleteResults = Array(fixture.results.prefix(1))

        XCTAssertThrowsError(
            try NotesTranscriptSourceBuilder.build(manifest: fixture.manifest, jobs: fixture.jobs, results: incompleteResults)
        ) { error in
            XCTAssertEqual(error as? NotesTranscriptSourceError, .transcriptNotEligible)
        }
    }

    func testSourceUnitsFollowNumericAuthoritativeOrderRegardlessOfCallerInputOrder() throws {
        let fixture = NotesTestFixtures.completedTranscript(chunkTexts: ["a", "b", "c"])
        let shuffledJobs = Array(fixture.jobs.reversed())
        let shuffledResults = [fixture.results[1], fixture.results[2], fixture.results[0]]

        let snapshot = try NotesTranscriptSourceBuilder.build(
            manifest: fixture.manifest, jobs: shuffledJobs, results: shuffledResults
        )

        XCTAssertEqual(snapshot.units.map(\.sequenceNumber), [0, 1, 2])
        XCTAssertEqual(snapshot.units.map(\.text), ["a", "b", "c"])
    }

    func testRelaunchReloadProducesIdenticalSourceIdentity() throws {
        let fixture = NotesTestFixtures.completedTranscript(chunkTexts: ["one", "two"])
        let first = try NotesTranscriptSourceBuilder.build(manifest: fixture.manifest, jobs: fixture.jobs, results: fixture.results)
        let second = try NotesTranscriptSourceBuilder.build(manifest: fixture.manifest, jobs: fixture.jobs, results: fixture.results)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testLogicalTranscriptChangeChangesFingerprint() throws {
        let fixture = NotesTestFixtures.completedTranscript(chunkTexts: ["one", "two"])
        let original = try NotesTranscriptSourceBuilder.build(manifest: fixture.manifest, jobs: fixture.jobs, results: fixture.results)

        var changedResults = fixture.results
        changedResults[1].output.text = "two-changed"
        let changed = try NotesTranscriptSourceBuilder.build(manifest: fixture.manifest, jobs: fixture.jobs, results: changedResults)

        XCTAssertNotEqual(original.fingerprint, changed.fingerprint)
    }

    func testEnumerationOrderDoesNotAffectFingerprint() throws {
        let fixture = NotesTestFixtures.completedTranscript(chunkTexts: ["x", "y", "z"])
        let inOrder = try NotesTranscriptSourceBuilder.build(manifest: fixture.manifest, jobs: fixture.jobs, results: fixture.results)
        let reordered = try NotesTranscriptSourceBuilder.build(
            manifest: fixture.manifest,
            jobs: fixture.jobs.shuffled(),
            results: fixture.results.shuffled()
        )

        XCTAssertEqual(inOrder.fingerprint, reordered.fingerprint)
    }

    func testDuplicateSequenceNumberTopologyRejected() {
        let fixture = NotesTestFixtures.completedTranscriptWithCustomSequenceNumbers(
            sequenceNumbers: [0, 0],
            chunkTexts: ["one", "one"]
        )
        XCTAssertThrowsError(
            try NotesTranscriptSourceBuilder.build(manifest: fixture.manifest, jobs: fixture.jobs, results: fixture.results)
        ) { error in
            guard case NotesTranscriptSourceError.invalidSourceTopology = error else {
                return XCTFail("expected invalidSourceTopology, got \(error)")
            }
        }
    }

    func testGappedSequenceNumberTopologyRejected() {
        let fixture = NotesTestFixtures.completedTranscriptWithCustomSequenceNumbers(
            sequenceNumbers: [0, 2],
            chunkTexts: ["one", "three"]
        )
        XCTAssertThrowsError(
            try NotesTranscriptSourceBuilder.build(manifest: fixture.manifest, jobs: fixture.jobs, results: fixture.results)
        ) { error in
            guard case NotesTranscriptSourceError.invalidSourceTopology = error else {
                return XCTFail("expected invalidSourceTopology, got \(error)")
            }
        }
    }

    func testFingerprintHandlesTextContainingNULByteDeterministically() {
        let sessionID = UUID()
        let units = [
            NotesTranscriptSourceUnit(
                sequenceNumber: 0,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: 0),
                text: "before\u{0}after",
                startOffsetSeconds: 0,
                durationSeconds: 30
            )
        ]
        let first = TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        let second = TranscriptSourceFingerprint.compute(sessionID: sessionID, units: units)
        XCTAssertEqual(first, second)

        // A different logical split around the same NUL byte must not
        // collide with the embedded-NUL text above — length-prefixing
        // guarantees the field boundary is never inferred from byte content.
        let splitUnits = [
            NotesTranscriptSourceUnit(
                sequenceNumber: 0,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: 0),
                text: "before",
                startOffsetSeconds: 0,
                durationSeconds: 30
            ),
            NotesTranscriptSourceUnit(
                sequenceNumber: 1,
                chunkFileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: 1),
                text: "after",
                startOffsetSeconds: 30,
                durationSeconds: 30
            )
        ]
        let splitFingerprint = TranscriptSourceFingerprint.compute(sessionID: sessionID, units: splitUnits)
        XCTAssertNotEqual(first, splitFingerprint)
    }

    func testFingerprintComputeIsDeterministicAcrossRepeatedCalls() {
        let fixture = NotesTestFixtures.completedTranscript(chunkTexts: ["repeat", "this", "please"])
        let snapshot = try? NotesTranscriptSourceBuilder.build(manifest: fixture.manifest, jobs: fixture.jobs, results: fixture.results)
        guard let units = snapshot?.units else {
            return XCTFail("expected a valid snapshot")
        }
        let fingerprints = (0..<5).map { _ in TranscriptSourceFingerprint.compute(sessionID: fixture.manifest.sessionID, units: units) }
        XCTAssertEqual(Set(fingerprints).count, 1)
    }
}
