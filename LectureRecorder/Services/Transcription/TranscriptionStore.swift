import Foundation

/// Production `TranscriptionStoring` implementation. An `actor` so
/// concurrent writes into the same session's transcription state
/// serialize automatically, mirroring `SessionStore`'s own actor-based
/// approach. Composes `ExclusiveArtifactFileSystem` for job-creation and
/// result-commit exclusivity, and `AtomicFileWriter` (already proven,
/// generic — not audio-owned) for mutable job-record replacement.
actor TranscriptionStore: TranscriptionStoring {
    /// Wraps a `TranscriptionInconsistency` finding as a thrown `Error` so
    /// internal decode helpers can use normal `do`/`catch` control flow;
    /// every public-facing call site converts this into either a
    /// `TranscriptionStoreError` (single-target loads) or leaves it as an
    /// inconsistency value (bulk enumeration, job/result creation).
    private struct InconsistencyError: Error {
        let inconsistency: TranscriptionInconsistency
    }

    private let exclusiveFileSystem: any ExclusiveArtifactFileSystem
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        exclusiveFileSystem: any ExclusiveArtifactFileSystem = DarwinExclusiveArtifactFileSystem(),
        encoder: JSONEncoder = AtomicFileWriter.defaultEncoder,
        decoder: JSONDecoder = AtomicFileWriter.defaultDecoder
    ) {
        self.exclusiveFileSystem = exclusiveFileSystem
        self.encoder = encoder
        self.decoder = decoder
    }

    func ensureDirectoriesExist(paths: TranscriptionArtifactPaths) throws {
        try DefaultFileSystemLocator.ensureDirectoryExists(paths.transcriptionDirectory)
        try DefaultFileSystemLocator.ensureDirectoryExists(paths.jobsDirectory)
        try DefaultFileSystemLocator.ensureDirectoryExists(paths.resultsDirectory)
    }

    // MARK: - Jobs

    func loadJob(sequenceNumber: Int, paths: TranscriptionArtifactPaths) throws -> TranscriptionJob? {
        let url = paths.jobURL(sequenceNumber: sequenceNumber)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try decodeJob(data, expectedSequenceNumber: sequenceNumber, expectedSessionID: paths.sessionID)
        } catch let inconsistencyError as InconsistencyError {
            throw Self.storeError(from: inconsistencyError.inconsistency)
        }
    }

    func createJobIfAbsent(_ job: TranscriptionJob, paths: TranscriptionArtifactPaths) throws -> JobCreationOutcome {
        try ensureDirectoriesExist(paths: paths)
        let url = paths.jobURL(sequenceNumber: job.source.chunkSequenceNumber)
        let data = try encoder.encode(job)
        let outcome = try exclusiveFileSystem.createExclusive(data: data, at: url)

        switch outcome {
        case .created, .createdDurabilityUncertain:
            // A job record is mutable and will be replaced again almost
            // immediately by the next lifecycle transition, so the
            // stricter "durability uncertain" distinction that matters for
            // an immutable result artifact is not meaningful here — both
            // outcomes represent a successful, exclusive creation.
            return .created(job)
        case .alreadyExists(let existingData):
            do {
                let existingJob = try decodeJob(
                    existingData,
                    expectedSequenceNumber: job.source.chunkSequenceNumber,
                    expectedSessionID: paths.sessionID
                )
                return .alreadyExistsValid(existingJob)
            } catch let inconsistencyError as InconsistencyError {
                return .alreadyExistsInconsistent(inconsistencyError.inconsistency)
            }
        }
    }

    func replaceJob(_ job: TranscriptionJob, paths: TranscriptionArtifactPaths) throws {
        try ensureDirectoriesExist(paths: paths)
        let url = paths.jobURL(sequenceNumber: job.source.chunkSequenceNumber)
        try AtomicFileWriter.writeJSON(job, to: url, encoder: encoder)
    }

    // MARK: - Results

    func loadResult(sequenceNumber: Int, paths: TranscriptionArtifactPaths) throws -> TranscriptResult? {
        let url = paths.resultURL(sequenceNumber: sequenceNumber)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try decodeResult(data, expectedSequenceNumber: sequenceNumber, expectedSessionID: paths.sessionID)
        } catch let inconsistencyError as InconsistencyError {
            throw Self.storeError(from: inconsistencyError.inconsistency)
        }
    }

    func commitResult(_ result: TranscriptResult, paths: TranscriptionArtifactPaths) throws -> ResultCommitOutcome {
        try ensureDirectoriesExist(paths: paths)
        let url = paths.resultURL(sequenceNumber: result.source.chunkSequenceNumber)
        let data = try encoder.encode(result)
        let outcome = try exclusiveFileSystem.createExclusive(data: data, at: url)

        switch outcome {
        case .created:
            return .committed
        case .createdDurabilityUncertain:
            return .committedDurabilityUncertain
        case .alreadyExists(let existingData):
            do {
                let existing = try decodeResult(
                    existingData,
                    expectedSequenceNumber: result.source.chunkSequenceNumber,
                    expectedSessionID: paths.sessionID
                )
                // `existing` was decoded off disk, so its Date fields only
                // carry the millisecond precision the wire format
                // preserves. Comparing it directly against the raw
                // in-memory `result` (full Double precision) would
                // spuriously report `.conflict` for a truly identical
                // resubmission — normalize the candidate through the same
                // encode/decode round trip before comparing.
                let normalizedCandidate = try decodeResult(
                    data,
                    expectedSequenceNumber: result.source.chunkSequenceNumber,
                    expectedSessionID: paths.sessionID
                )
                return existing == normalizedCandidate ? .alreadyCommittedIdentical : .conflict(existing: existing)
            } catch {
                return .integrityError(
                    "Existing result at \(url.lastPathComponent) could not be validated: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Bulk, partial-tolerant enumeration

    func loadAllJobArtifacts(paths: TranscriptionArtifactPaths) throws -> [ArtifactLoadResult<TranscriptionJob>] {
        try enumerateArtifacts(directory: paths.jobsDirectory, suffix: ".job.json") { sequenceNumber, data in
            do {
                let job = try self.decodeJob(
                    data,
                    expectedSequenceNumber: sequenceNumber,
                    expectedSessionID: paths.sessionID
                )
                return .success(sequenceNumber: sequenceNumber, value: job)
            } catch let inconsistencyError as InconsistencyError {
                return .failure(sequenceNumber: sequenceNumber, inconsistency: inconsistencyError.inconsistency)
            } catch {
                return .failure(
                    sequenceNumber: sequenceNumber,
                    inconsistency: .corruptJob(sequenceNumber: sequenceNumber, message: error.localizedDescription)
                )
            }
        }
    }

    func loadAllResultArtifacts(paths: TranscriptionArtifactPaths) throws -> [ArtifactLoadResult<TranscriptResult>] {
        try enumerateArtifacts(directory: paths.resultsDirectory, suffix: ".transcript.json") { sequenceNumber, data in
            do {
                let result = try self.decodeResult(
                    data,
                    expectedSequenceNumber: sequenceNumber,
                    expectedSessionID: paths.sessionID
                )
                return .success(sequenceNumber: sequenceNumber, value: result)
            } catch let inconsistencyError as InconsistencyError {
                return .failure(sequenceNumber: sequenceNumber, inconsistency: inconsistencyError.inconsistency)
            } catch {
                return .failure(
                    sequenceNumber: sequenceNumber,
                    inconsistency: .corruptResult(sequenceNumber: sequenceNumber, message: error.localizedDescription)
                )
            }
        }
    }

    // MARK: - Private helpers

    private func enumerateArtifacts<Value: Sendable>(
        directory: URL,
        suffix: String,
        decode: (Int, Data) -> ArtifactLoadResult<Value>
    ) throws -> [ArtifactLoadResult<Value>] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)

        var results: [ArtifactLoadResult<Value>] = []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard name.hasSuffix(suffix) else { continue }

            guard let sequenceNumber = Self.sequenceNumber(fromArtifactFileName: name, suffix: suffix) else {
                results.append(.failure(
                    sequenceNumber: -1,
                    inconsistency: .corruptJob(sequenceNumber: -1, message: "Unrecognized artifact file name: \(name)")
                ))
                continue
            }

            do {
                let data = try Data(contentsOf: url)
                results.append(decode(sequenceNumber, data))
            } catch {
                results.append(.failure(
                    sequenceNumber: sequenceNumber,
                    inconsistency: .corruptJob(sequenceNumber: sequenceNumber, message: error.localizedDescription)
                ))
            }
        }
        return results
    }

    private static func sequenceNumber(fromArtifactFileName name: String, suffix: String) -> Int? {
        guard name.hasPrefix("chunk_"), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: "chunk_".count)
        guard let end = name.index(name.endIndex, offsetBy: -suffix.count, limitedBy: start) else { return nil }
        guard start < end else { return nil }
        let digits = name[start..<end]
        guard digits.count == 6, digits.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(digits)
    }

    private func decodeJob(
        _ data: Data,
        expectedSequenceNumber: Int,
        expectedSessionID: UUID
    ) throws -> TranscriptionJob {
        let schemaVersion: Int
        do {
            schemaVersion = try Self.peekSchemaVersion(data: data, decoder: decoder)
        } catch {
            throw InconsistencyError(inconsistency: .corruptJob(
                sequenceNumber: expectedSequenceNumber,
                message: error.localizedDescription
            ))
        }
        guard schemaVersion == TranscriptionJob.currentSchemaVersion else {
            throw InconsistencyError(inconsistency: .unsupportedJobSchema(
                sequenceNumber: expectedSequenceNumber,
                version: schemaVersion
            ))
        }

        let job: TranscriptionJob
        do {
            job = try decoder.decode(TranscriptionJob.self, from: data)
        } catch {
            throw InconsistencyError(inconsistency: .corruptJob(
                sequenceNumber: expectedSequenceNumber,
                message: error.localizedDescription
            ))
        }

        guard
            job.source.sessionID == expectedSessionID,
            job.source.chunkSequenceNumber == expectedSequenceNumber
        else {
            throw InconsistencyError(inconsistency: .jobResultIdentityMismatch(sequenceNumber: expectedSequenceNumber))
        }
        return job
    }

    private func decodeResult(
        _ data: Data,
        expectedSequenceNumber: Int,
        expectedSessionID: UUID
    ) throws -> TranscriptResult {
        let schemaVersion: Int
        do {
            schemaVersion = try Self.peekSchemaVersion(data: data, decoder: decoder)
        } catch {
            throw InconsistencyError(inconsistency: .corruptResult(
                sequenceNumber: expectedSequenceNumber,
                message: error.localizedDescription
            ))
        }
        guard schemaVersion == TranscriptResult.currentSchemaVersion else {
            throw InconsistencyError(inconsistency: .unsupportedResultSchema(
                sequenceNumber: expectedSequenceNumber,
                version: schemaVersion
            ))
        }

        let result: TranscriptResult
        do {
            result = try decoder.decode(TranscriptResult.self, from: data)
        } catch {
            throw InconsistencyError(inconsistency: .corruptResult(
                sequenceNumber: expectedSequenceNumber,
                message: error.localizedDescription
            ))
        }

        guard
            result.source.sessionID == expectedSessionID,
            result.source.chunkSequenceNumber == expectedSequenceNumber
        else {
            throw InconsistencyError(inconsistency: .jobResultIdentityMismatch(sequenceNumber: expectedSequenceNumber))
        }
        return result
    }

    private static func peekSchemaVersion(data: Data, decoder: JSONDecoder) throws -> Int {
        struct SchemaVersionOnly: Decodable {
            let schemaVersion: Int
        }
        return try decoder.decode(SchemaVersionOnly.self, from: data).schemaVersion
    }

    private static func storeError(from inconsistency: TranscriptionInconsistency) -> TranscriptionStoreError {
        switch inconsistency {
        case .corruptJob(let seq, let message), .corruptResult(let seq, let message):
            return .corrupt(sequenceNumber: seq, underlying: message)
        case .unsupportedJobSchema(let seq, let version), .unsupportedResultSchema(let seq, let version):
            return .unsupportedSchemaVersion(sequenceNumber: seq, version: version)
        case .jobResultIdentityMismatch(let seq):
            return .identityMismatch(sequenceNumber: seq)
        case .orphanedResult(let seq),
             .completedJobMissingResult(let seq),
             .resultAttemptMismatch(let seq),
             .resultWithNonTerminalJob(let seq, _),
             .abandonedRunningAttemptWithoutResult(let seq):
            return .corrupt(sequenceNumber: seq, underlying: "Unexpected inconsistency in single-target load.")
        }
    }
}
