import AVFoundation
import Foundation

/// A newly imported lecture: an ordinary completed session, indistinguishable
/// downstream from one recorded live.
nonisolated struct LectureMediaImportResult: Sendable, Equatable {
    let manifest: SessionManifest
    let sessionPaths: SessionPaths

    var sessionID: UUID { manifest.sessionID }
}

/// Why an import produced no completed session. Every case except
/// `publicationNotDurable` means no session was published; app-owned
/// staging is removed and the source file is never modified.
nonisolated enum LectureMediaImportError: LocalizedError, Sendable, Equatable {
    case sourceNotAFileURL
    /// The source is missing or is not a regular file.
    case sourceUnavailable
    case decode(LectureMediaDecodeError)
    /// The audio track decoded to zero frames.
    case noAudio
    /// App storage for the import could not be prepared or is unsafe.
    case storageUnavailable(reason: String)
    case chunkWritingFailed(reason: String)
    /// The staged session failed the same validation transcription and
    /// playback apply, so it was never published.
    case validationFailed(reason: String)
    case sessionAlreadyExists(UUID)
    case publicationFailed(reason: String)
    /// The complete session was moved into place, but syncing the sessions
    /// directory failed, so its survival across a crash is unconfirmed. The
    /// session is complete and valid; it is not removed.
    case publicationNotDurable(sessionID: UUID, reason: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceNotAFileURL:
            return "Only local files can be imported."
        case .sourceUnavailable:
            return "The selected file is missing or is not a regular file."
        case .decode(let underlying):
            return underlying.errorDescription
        case .noAudio:
            return "The file's audio track contains no audio."
        case .storageUnavailable(let reason):
            return "Lecture storage is unavailable: \(reason)"
        case .chunkWritingFailed(let reason):
            return "The imported audio could not be saved: \(reason)"
        case .validationFailed(let reason):
            return "The imported lecture failed validation: \(reason)"
        case .sessionAlreadyExists(let sessionID):
            return "A session with ID \(sessionID.uuidString) already exists."
        case .publicationFailed(let reason):
            return "The imported lecture could not be added: \(reason)"
        case .publicationNotDurable(_, let reason):
            return "The imported lecture was added, but saving it could not be confirmed: \(reason)"
        case .cancelled:
            return "The import was cancelled."
        }
    }
}

/// Imports a local media file's audio as a new completed session.
nonisolated protocol LectureMediaImporting: Sendable {
    /// Always runs off the caller's actor: decoding and file I/O never run
    /// on the main actor, even when called from UI code.
    @concurrent
    func importLecture(from sourceURL: URL) async throws -> LectureMediaImportResult
}

/// Turns a local media file into the same chunked session representation
/// live recording produces, so transcription, Notes, Summary, playback, and
/// the completed-session catalog consume it without knowing its origin.
///
/// Flow:
/// 1. Decode the first audio track to non-interleaved Float32 PCM at its own
///    sample rate (`LectureMediaAudioDecoding`). No VAD; nothing is skipped.
/// 2. Feed every decoded buffer to a writer from the same
///    `AudioChunkWriterFactory` live capture uses, writing ~30-second chunks
///    (`SessionManager`'s target duration)
///    into a staging session directory outside the sessions root, with the
///    writer's own frame-exact boundaries and durable finalization.
/// 3. Write a `.completed` manifest built from the writer's finalized
///    chunks, read it back, and validate the staged session with the
///    existing playback-source check (which includes transcription
///    eligibility).
/// 4. Publish the whole session directory into the sessions root with a
///    single non-replacing rename and sync that directory — so the catalog
///    sees either nothing or a complete session.
///
/// On any failure before publication the staging directory (app-owned, and
/// recreatable from the untouched source) is removed. The source file is
/// only ever read. No schema change: the manifest is an ordinary completed
/// session with no import provenance.
nonisolated struct LectureMediaImportService: LectureMediaImporting {
    /// The live-recording chunk duration (`SessionManager.startSession`).
    static let targetChunkDurationSeconds: Double = 30.0
    static let stagingDirectoryName = "ImportStaging"

    private let sessionsRootResolver: @Sendable () throws -> URL
    private let stagingRootResolver: @Sendable () throws -> URL
    private let decoder: any LectureMediaAudioDecoding
    private let writerFactory: any AudioChunkWriterFactory
    private let makeSessionID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    init(
        sessionsRootResolver: @escaping @Sendable () throws -> URL = { try DefaultFileSystemLocator().sessionsRootDirectory() },
        stagingRootResolver: @escaping @Sendable () throws -> URL = { try LectureMediaImportService.defaultStagingRoot() },
        decoder: any LectureMediaAudioDecoding = AVAssetLectureMediaAudioDecoder(),
        writerFactory: any AudioChunkWriterFactory = DefaultAudioChunkWriterFactory(),
        makeSessionID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionsRootResolver = sessionsRootResolver
        self.stagingRootResolver = stagingRootResolver
        self.decoder = decoder
        self.writerFactory = writerFactory
        self.makeSessionID = makeSessionID
        self.now = now
    }

    /// `<Application Support>/<bundle-id>/ImportStaging`, a sibling of the
    /// sessions root so publication is a same-volume rename.
    static func defaultStagingRoot() throws -> URL {
        let root = try DefaultFileSystemLocator().applicationSupportDirectory()
            .appendingPathComponent(stagingDirectoryName, isDirectory: true)
        try DefaultFileSystemLocator.ensureDirectoryExists(root)
        return root
    }

    @concurrent
    func importLecture(from sourceURL: URL) async throws -> LectureMediaImportResult {
        guard sourceURL.isFileURL else { throw LectureMediaImportError.sourceNotAFileURL }
        let resolvedSource = sourceURL.resolvingSymlinksInPath()
        guard CompletedSessionPathSafety.checkExistingRegularFile(resolvedSource) == .safe else {
            throw LectureMediaImportError.sourceUnavailable
        }

        let sessionsRoot: URL
        let stagingRoot: URL
        do {
            sessionsRoot = try sessionsRootResolver()
            stagingRoot = try stagingRootResolver()
        } catch {
            throw LectureMediaImportError.storageUnavailable(reason: error.localizedDescription)
        }
        guard CompletedSessionPathSafety.checkExistingDirectory(sessionsRoot) == .safe,
              CompletedSessionPathSafety.checkExistingDirectory(stagingRoot) == .safe else {
            throw LectureMediaImportError.storageUnavailable(reason: "The sessions or staging directory is missing, a symlink, or not a directory.")
        }

        let sessionID = makeSessionID()
        let finalSessionDirectory = DefaultFileSystemLocator
            .pathsWithoutCreating(rootDirectory: sessionsRoot, sessionID: sessionID).sessionDirectory
        let stagingSessionDirectory = DefaultFileSystemLocator
            .pathsWithoutCreating(rootDirectory: stagingRoot, sessionID: sessionID).sessionDirectory
        guard CompletedSessionPathSafety.checkExistingDirectory(finalSessionDirectory) == .missing,
              CompletedSessionPathSafety.checkExistingDirectory(stagingSessionDirectory) == .missing else {
            throw LectureMediaImportError.sessionAlreadyExists(sessionID)
        }

        let stagingPaths: SessionPaths
        do {
            stagingPaths = try DefaultFileSystemLocator.buildPaths(rootDirectory: stagingRoot, sessionID: sessionID)
        } catch {
            throw LectureMediaImportError.storageUnavailable(reason: error.localizedDescription)
        }

        do {
            let manifest = try await stage(sourceURL: resolvedSource, sessionID: sessionID, paths: stagingPaths)
            return try publish(manifest: manifest, stagingPaths: stagingPaths, sessionsRoot: sessionsRoot)
        } catch {
            // Remove only this import's own staging; a session that was
            // already published (`publicationNotDurable`) is left in place.
            try? FileManager.default.removeItem(at: stagingPaths.sessionDirectory)
            throw error
        }
    }

    // MARK: - Staging

    /// Decodes and chunks the whole source into `paths`, writes its
    /// completed manifest, and validates the session as persisted. Returns
    /// the manifest as read back, which is what every later reader sees.
    /// Publishes nothing.
    private func stage(sourceURL: URL, sessionID: UUID, paths: SessionPaths) async throws -> SessionManifest {
        let reader: any LectureMediaAudioReading
        do {
            reader = try await decoder.openAudio(at: sourceURL)
        } catch let error as LectureMediaDecodeError {
            throw LectureMediaImportError.decode(error)
        } catch {
            throw LectureMediaImportError.decode(.unreadable(reason: error.localizedDescription))
        }
        let format = reader.format

        let writer: any AudioChunkWriting
        do {
            writer = try writerFactory.makeWriter(
                chunksDirectory: paths.chunksDirectory,
                format: format,
                targetChunkDurationSeconds: Self.targetChunkDurationSeconds
            )
        } catch {
            reader.cancel()
            throw LectureMediaImportError.chunkWritingFailed(reason: error.localizedDescription)
        }

        let chunks = try await writeChunks(from: reader, to: writer, format: format)
        guard !chunks.isEmpty else { throw LectureMediaImportError.noAudio }

        let completionDate = now()
        let manifest = SessionManifest(
            schemaVersion: SessionManifest.currentSchemaVersion,
            sessionID: sessionID,
            creationDate: completionDate,
            endDate: completionDate,
            status: .completed,
            audioFormat: makeAudioFormatDescriptor(from: format),
            targetChunkDurationSeconds: Self.targetChunkDurationSeconds,
            chunks: chunks,
            endReason: .userStopped,
            endedCleanly: true,
            failureDescription: nil,
            observedCaptureCopyFailureCount: nil
        )

        let persisted: SessionManifest
        do {
            try AtomicFileWriter.writeJSON(manifest, to: paths.manifestURL)
            persisted = try AtomicFileWriter.readJSON(SessionManifest.self, from: paths.manifestURL)
        } catch {
            throw LectureMediaImportError.chunkWritingFailed(reason: error.localizedDescription)
        }

        do {
            _ = try LecturePlaybackSourceLoader.load(expectedSessionID: sessionID, manifest: persisted, sessionPaths: paths)
        } catch {
            throw LectureMediaImportError.validationFailed(reason: error.localizedDescription)
        }
        return persisted
    }

    /// Feeds every decoded buffer to `writer` and returns its finalized
    /// chunks in sequence order. At most about one chunk of decoded audio is
    /// queued ahead of the writer at a time, so memory stays bounded for
    /// long lectures. Any decode or write failure, or cancellation, ends the
    /// import; nothing is skipped.
    private func writeChunks(
        from reader: any LectureMediaAudioReading,
        to writer: any AudioChunkWriting,
        format: AVAudioFormat
    ) async throws -> [ChunkMetadata] {
        let framesPerChunk = Int((format.sampleRate * Self.targetChunkDurationSeconds).rounded())
        var events = writer.events.makeAsyncIterator()
        var chunks: [ChunkMetadata] = []
        var submittedFrames = 0

        func receiveChunk() async throws -> Bool {
            let event: ChunkEvent?
            do {
                event = try await events.next()
            } catch {
                throw LectureMediaImportError.chunkWritingFailed(reason: error.localizedDescription)
            }
            guard let event else { return false }
            switch event {
            case .finalized(let metadata):
                chunks.append(metadata)
            }
            return true
        }

        do {
            while let buffer = try nextDecodedBuffer(from: reader) {
                if Task.isCancelled { throw LectureMediaImportError.cancelled }
                writer.acceptBuffer(buffer)
                submittedFrames += Int(buffer.frameLength)
                // Backpressure: wait until every chunk except the one being
                // filled has been durably finalized.
                while chunks.count < submittedFrames / framesPerChunk - 1 {
                    guard try await receiveChunk() else {
                        throw LectureMediaImportError.chunkWritingFailed(reason: "The chunk writer stopped early.")
                    }
                }
            }
        } catch {
            reader.cancel()
            writer.finishRecording()
            while (try? await receiveChunk()) == true {}
            throw error
        }

        writer.finishRecording()
        while try await receiveChunk() {}

        let writtenFrames = chunks.reduce(0) { $0 + $1.frameCount }
        guard chunks.map(\.sequenceNumber) == Array(0..<chunks.count), writtenFrames == submittedFrames else {
            throw LectureMediaImportError.chunkWritingFailed(
                reason: "Chunked \(writtenFrames) of \(submittedFrames) decoded frames."
            )
        }
        return chunks
    }

    private func nextDecodedBuffer(from reader: any LectureMediaAudioReading) throws -> AVAudioPCMBuffer? {
        do {
            return try reader.nextBuffer()
        } catch let error as LectureMediaDecodeError {
            throw LectureMediaImportError.decode(error)
        } catch {
            throw LectureMediaImportError.decode(.decodingFailed(reason: error.localizedDescription))
        }
    }

    // MARK: - Publication

    /// The existing `renamex_np(RENAME_EXCL)` and `F_FULLFSYNC` primitives,
    /// used here only for publishing the session directory — chunk
    /// durability stays entirely behind `AudioChunkWriterFactory`.
    private static let publicationFileSystem = DarwinChunkFinalizationFileSystem()

    /// Moves the fully staged session into the sessions root with one
    /// non-replacing rename, then syncs the sessions root.
    private func publish(
        manifest: SessionManifest,
        stagingPaths: SessionPaths,
        sessionsRoot: URL
    ) throws -> LectureMediaImportResult {
        let finalPaths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: sessionsRoot, sessionID: manifest.sessionID)
        do {
            try Self.publicationFileSystem.rename(from: stagingPaths.sessionDirectory, to: finalPaths.sessionDirectory)
        } catch is ChunkRenameCollision {
            throw LectureMediaImportError.sessionAlreadyExists(manifest.sessionID)
        } catch {
            throw LectureMediaImportError.publicationFailed(reason: Self.describe(error))
        }
        do {
            try Self.publicationFileSystem.synchronizeDirectory(at: sessionsRoot)
        } catch {
            throw LectureMediaImportError.publicationNotDurable(sessionID: manifest.sessionID, reason: Self.describe(error))
        }
        return LectureMediaImportResult(manifest: manifest, sessionPaths: finalPaths)
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? ChunkDurabilityFailure {
            return "\(failure.stage.rawValue): \(failure.primaryMessage)"
        }
        return error.localizedDescription
    }
}
