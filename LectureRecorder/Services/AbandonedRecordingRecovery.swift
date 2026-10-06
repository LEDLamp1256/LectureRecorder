import AVFoundation
import Darwin
import Foundation
import OSLog

/// What one abandoned-recording recovery pass did.
nonisolated struct AbandonedRecordingRecoveryReport: Sendable, Equatable {
    nonisolated enum TailOutcome: Sendable, Equatable {
        /// No `.partial.caf` tail candidate was present.
        case none
        /// A crash-left partial tail was copied into a new canonical chunk.
        /// The original partial is left byte-for-byte untouched.
        case promoted(sequenceNumber: Int, frameCount: Int)
        /// A partial tail exists but did not satisfy the promotion contract;
        /// it is left untouched.
        case preserved(sequenceNumber: Int?, reason: String)
    }

    nonisolated struct RecoveredSession: Sendable, Equatable {
        let sessionID: UUID
        let referencedChunkCount: Int
        /// False when an already-referenced chunk was missing or invalid:
        /// the chunk list is then left exactly as it was.
        let referencedChunksIntact: Bool
        let adoptedCanonicalChunkCount: Int
        let tail: TailOutcome
    }

    nonisolated enum SkipReason: Sendable, Equatable {
        case invalidDirectoryName
        case unsafeSessionDirectory
        case manifestUnavailable
        case corruptManifest
        case unsupportedSchema(Int)
        case identityMismatch
        /// Another live process owns this session (its directory lock is held).
        case liveOwner
        /// The ownership lock could not be checked; fail closed.
        case lockUnavailable(errno: Int32)
        /// The recovered manifest could not be durably published.
        case persistenceFailed(String)
        /// Audio that otherwise validated could not be confirmed durable
        /// (a file or directory sync failed). The session is left
        /// `.recording`, untouched, so the next launch retries instead of
        /// publishing a manifest that would exclude that audio forever.
        case durabilityUnconfirmed(String)
    }

    nonisolated struct SkippedEntry: Sendable, Equatable {
        let directoryName: String
        let reason: SkipReason
    }

    var recovered: [RecoveredSession] = []
    var skipped: [SkippedEntry] = []
}

/// Launch-time recovery of recordings abandoned by a crash, kill, power
/// loss, or an unconfirmed final write: every `.recording` session manifest
/// with no live owner becomes `.interrupted` / `.unknown`, keeping the audio
/// it can prove durable and making it reachable from the session library.
///
/// The single, explicit owner of this mutation — never a side effect of a
/// catalog read. Runs once, synchronously, before `SessionManager` exists.
/// Ownership by another live process is detected with the same
/// `SessionDirectoryLock` a recording holds for its whole lifecycle.
///
/// Per session it validates and plans first, and mutates second:
/// 1. Validate every chunk the manifest already references. If any is
///    missing or invalid, the chunk list is left exactly as is (nothing is
///    adopted or promoted) and the damage stays visible downstream.
/// 2. Adopt any contiguous run of canonical `chunk_NNNNNN.caf` files beyond
///    the manifest that satisfy the writer's own invariants (exact name,
///    regular file, matching Float32 format, full `framesPerChunk` for all
///    but a final short chunk), stopping at the first gap or invalid file.
/// 3. Promote a crash-left `.partial.caf` tail by *copying* its decoded
///    audio into a new canonical chunk — only under the strict same-boot
///    contract in `promoteTail`.
/// 4. Atomically publish the recovered manifest.
///
/// Never mutates `.completed`, `.failed`, `.interrupted` or imported
/// sessions, never edits, renames or deletes an existing audio file, and is
/// idempotent: once published, the session is no longer `.recording`.
nonisolated struct AbandonedRecordingRecovery: Sendable {
    private let sessionsRootResolver: @Sendable () throws -> URL
    private let bootTimeProvider: @Sendable () -> Date?
    private let fileSystem: any ChunkFinalizationFileSystem
    private let now: @Sendable () -> Date

    init(
        sessionsRootResolver: @escaping @Sendable () throws -> URL = {
            try DefaultFileSystemLocator.resolveSessionsRootPathWithoutCreating()
        },
        bootTimeProvider: @escaping @Sendable () -> Date? = { AbandonedRecordingRecovery.currentKernelBootTime() },
        fileSystem: any ChunkFinalizationFileSystem = DarwinChunkFinalizationFileSystem(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionsRootResolver = sessionsRootResolver
        self.bootTimeProvider = bootTimeProvider
        self.fileSystem = fileSystem
        self.now = now
    }

    /// `kern.boottime`, or `nil` if it cannot be read (in which case no
    /// partial tail is ever promoted).
    static func currentKernelBootTime() -> Date? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0, bootTime.tv_sec > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec) + TimeInterval(bootTime.tv_usec) / 1_000_000)
    }

    @discardableResult
    func recoverAbandonedRecordings() -> AbandonedRecordingRecoveryReport {
        var report = AbandonedRecordingRecoveryReport()

        guard let root = try? sessionsRootResolver(),
              CompletedSessionPathSafety.checkExistingDirectory(root) == .safe else {
            return report
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            recoverEntry(entry, root: root, into: &report)
        }
        if !report.recovered.isEmpty || !report.skipped.isEmpty {
            Log.session.info(
                "Abandoned-recording recovery: recovered=\(report.recovered.count, privacy: .public) skipped=\(report.skipped.count, privacy: .public)"
            )
        }
        return report
    }

    // MARK: - Per session

    private func recoverEntry(_ entry: URL, root: URL, into report: inout AbandonedRecordingRecoveryReport) {
        let name = entry.lastPathComponent
        func skip(_ reason: AbandonedRecordingRecoveryReport.SkipReason) {
            report.skipped.append(.init(directoryName: name, reason: reason))
        }

        guard let sessionID = UUID(uuidString: name) else {
            // Never ours to touch; reported only if it is a directory.
            if CompletedSessionPathSafety.checkExistingDirectory(entry) == .safe {
                skip(.invalidDirectoryName)
            }
            return
        }
        guard CompletedSessionPathSafety.checkExistingDirectory(entry) == .safe else {
            skip(.unsafeSessionDirectory)
            return
        }
        let paths = DefaultFileSystemLocator.pathsWithoutCreating(rootDirectory: root, sessionID: sessionID)

        // Cheap pre-filter without the lock: only `.recording` manifests
        // are candidates; everything else is left completely untouched.
        guard case .loaded(let preliminary) = readManifest(paths), preliminary.status == .recording else {
            return
        }

        // Ownership: a live recording (in this or another process) holds
        // the directory lock for its whole lifecycle.
        let lock: SessionDirectoryLock
        switch SessionDirectoryLock.tryAcquire(directory: paths.sessionDirectory) {
        case .acquired(let acquired):
            lock = acquired
        case .busy:
            skip(.liveOwner)
            return
        case .failed(let code):
            skip(.lockUnavailable(errno: code))
            return
        }
        defer { lock.release() }

        // Re-read under the lock: the previous owner may have finalized it
        // between the pre-filter and lock acquisition.
        let manifest: SessionManifest
        switch readManifest(paths) {
        case .loaded(let loaded):
            manifest = loaded
        case .unavailable:
            skip(.manifestUnavailable)
            return
        case .corrupt:
            skip(.corruptManifest)
            return
        }
        guard manifest.status == .recording else { return }
        guard manifest.schemaVersion == SessionManifest.currentSchemaVersion else {
            skip(.unsupportedSchema(manifest.schemaVersion))
            return
        }
        guard manifest.sessionID == sessionID else {
            skip(.identityMismatch)
            return
        }

        // Plan: read-only apart from fsync of already-canonical files.
        let plan = planChunks(manifest: manifest, paths: paths)
        if let deferReason = plan.deferReason {
            skip(.durabilityUnconfirmed(deferReason))
            return
        }

        // Mutate.
        var chunks = manifest.chunks + plan.adopted
        let tailOutcome: AbandonedRecordingRecoveryReport.TailOutcome
        switch plan.tail {
        case .resolved(let outcome):
            tailOutcome = outcome
        case .candidate(let candidate):
            switch promoteTail(candidate, chunksDirectory: paths.chunksDirectory) {
            case .success(let metadata):
                chunks.append(metadata)
                tailOutcome = .promoted(sequenceNumber: metadata.sequenceNumber, frameCount: metadata.frameCount)
            case .failure(let reason):
                tailOutcome = .preserved(sequenceNumber: candidate.sequenceNumber, reason: reason)
            case .deferred(let reason):
                // A canonical copy now exists but is not confirmed durable;
                // the next launch adopts it as an ordinary canonical chunk.
                skip(.durabilityUnconfirmed(reason))
                return
            }
        }

        var recovered = manifest
        recovered.chunks = chunks
        recovered.status = .interrupted
        recovered.endReason = .unknown
        recovered.endedCleanly = false
        recovered.endDate = nil
        recovered.failureDescription = nil

        do {
            try AtomicFileWriter.writeJSON(recovered, to: paths.manifestURL)
            let readBack = try AtomicFileWriter.readJSON(SessionManifest.self, from: paths.manifestURL)
            guard readBack == recovered else {
                skip(.persistenceFailed("Recovered manifest did not read back identically."))
                return
            }
        } catch {
            skip(.persistenceFailed(error.localizedDescription))
            return
        }

        let result = AbandonedRecordingRecoveryReport.RecoveredSession(
            sessionID: sessionID,
            referencedChunkCount: manifest.chunks.count,
            referencedChunksIntact: plan.referencedChunksIntact,
            adoptedCanonicalChunkCount: plan.adopted.count,
            tail: tailOutcome
        )
        report.recovered.append(result)
        appendRecoveryLog(result, paths: paths)
    }

    // MARK: - Manifest

    private enum ManifestRead {
        case loaded(SessionManifest)
        case unavailable
        case corrupt
    }

    private func readManifest(_ paths: SessionPaths) -> ManifestRead {
        guard CompletedSessionPathSafety.checkExistingRegularFile(paths.manifestURL) == .safe else {
            return .unavailable
        }
        guard let manifest = try? AtomicFileWriter.readJSON(SessionManifest.self, from: paths.manifestURL) else {
            return .corrupt
        }
        return .loaded(manifest)
    }

    // MARK: - Chunk planning

    private enum TailPlan {
        case candidate(TailCandidate)
        case resolved(AbandonedRecordingRecoveryReport.TailOutcome)
    }

    private struct TailCandidate {
        let sequenceNumber: Int
        let partialURL: URL
        let startFrame: Int
        let format: AudioFormatDescriptor
        let framesPerChunk: Int
    }

    private struct ChunkPlan {
        var referencedChunksIntact: Bool
        var adopted: [ChunkMetadata]
        var tail: TailPlan
        /// Set when an otherwise-valid canonical chunk could not be
        /// confirmed durable: recovery of this session is deferred.
        var deferReason: String? = nil
    }

    private func planChunks(manifest: SessionManifest, paths: SessionPaths) -> ChunkPlan {
        let format = manifest.audioFormat
        let damaged = ChunkPlan(referencedChunksIntact: false, adopted: [], tail: .resolved(.none))

        guard Self.isSupportedCaptureFormat(format),
              manifest.targetChunkDurationSeconds.isFinite,
              manifest.targetChunkDurationSeconds > 0 else {
            return damaged
        }
        let framesPerChunk = Int((format.sampleRate * manifest.targetChunkDurationSeconds).rounded())
        guard framesPerChunk > 0 else { return damaged }

        let chunksDirectory = paths.chunksDirectory
        switch CompletedSessionPathSafety.checkExistingDirectory(chunksDirectory) {
        case .safe:
            break
        case .missing:
            return ChunkPlan(referencedChunksIntact: manifest.chunks.isEmpty, adopted: [], tail: .resolved(.none))
        case .unsafe:
            return damaged
        }

        // 1. Every referenced chunk must be exactly what the manifest says.
        let referenced = manifest.chunks
        guard referenced.map(\.sequenceNumber) == Array(0..<referenced.count) else { return damaged }
        var cumulativeFrames = 0
        for chunk in referenced {
            guard chunk.state == .completed,
                  chunk.fileName == TranscriptionArtifactPaths.canonicalChunkFileName(for: chunk.sequenceNumber),
                  chunk.frameCount > 0,
                  Self.validatedFrameCount(at: chunksDirectory.appendingPathComponent(chunk.fileName), format: format) == chunk.frameCount
            else {
                return damaged
            }
            cumulativeFrames += chunk.frameCount
        }

        // 2. Adopt a contiguous run of valid canonical chunks beyond it —
        // any length, never across a gap.
        let onDisk = Self.chunkFileInventory(in: chunksDirectory)
        var adopted: [ChunkMetadata] = []
        var next = referenced.count
        var runEndedAtShortChunk = referenced.last.map { $0.frameCount < framesPerChunk } ?? false
        while !runEndedAtShortChunk, onDisk.canonical.contains(next) {
            let url = chunksDirectory.appendingPathComponent(TranscriptionArtifactPaths.canonicalChunkFileName(for: next))
            guard let frameCount = Self.validatedFrameCount(at: url, format: format),
                  frameCount <= framesPerChunk else {
                break
            }
            if frameCount < framesPerChunk {
                // Only the writer's final chunk is ever short; anything
                // recorded after a short chunk is ambiguous.
                let hasLaterState = onDisk.canonical.contains { $0 > next } || onDisk.partial.contains { $0 > next }
                guard !hasLaterState else { break }
                runEndedAtShortChunk = true
            }
            guard (try? fileSystem.synchronizeFile(at: url)) != nil else {
                return ChunkPlan(
                    referencedChunksIntact: true,
                    adopted: [],
                    tail: .resolved(.none),
                    deferReason: "canonical chunk #\(next) could not be synchronized"
                )
            }
            adopted.append(Self.metadata(
                sequenceNumber: next,
                frameCount: frameCount,
                startFrame: cumulativeFrames,
                sampleRate: format.sampleRate
            ))
            cumulativeFrames += frameCount
            next += 1
        }
        if !adopted.isEmpty, (try? fileSystem.synchronizeDirectory(at: chunksDirectory)) == nil {
            // Adopted files' directory entries could not be confirmed
            // durable: defer rather than publish a manifest that would
            // exclude them forever.
            return ChunkPlan(
                referencedChunksIntact: true,
                adopted: [],
                tail: .resolved(.none),
                deferReason: "chunks directory could not be synchronized"
            )
        }

        // 3. Tail candidate. Ambiguous ownership is excluded here; the
        // promotion contract itself is enforced in `promoteTail`.
        let partials = onDisk.partial
        guard !partials.isEmpty else {
            return ChunkPlan(referencedChunksIntact: true, adopted: adopted, tail: .resolved(.none))
        }
        let ambiguityReason: String?
        if onDisk.canonical.contains(next) {
            ambiguityReason = "a canonical chunk already exists for the next sequence"
        } else if runEndedAtShortChunk {
            ambiguityReason = "the recording already ends with a final short chunk"
        } else if partials != [next] || onDisk.canonical.contains(where: { $0 > next }) {
            ambiguityReason = "partial sequence does not match the next expected chunk"
        } else {
            ambiguityReason = nil
        }
        if let ambiguityReason {
            return ChunkPlan(
                referencedChunksIntact: true,
                adopted: adopted,
                tail: .resolved(.preserved(sequenceNumber: partials.count == 1 ? partials.first : nil, reason: ambiguityReason))
            )
        }
        let candidate = TailCandidate(
            sequenceNumber: next,
            partialURL: chunksDirectory.appendingPathComponent(Self.partialChunkFileName(for: next)),
            startFrame: cumulativeFrames,
            format: format,
            framesPerChunk: framesPerChunk
        )
        return ChunkPlan(referencedChunksIntact: true, adopted: adopted, tail: .candidate(candidate))
    }

    // MARK: - Tail promotion (copy-based)

    private enum PromotionResult {
        case success(ChunkMetadata)
        /// The partial does not qualify; it is preserved untouched.
        case failure(String)
        /// A canonical copy was published but its directory entry could not
        /// be confirmed durable; the session's recovery is deferred.
        case deferred(String)
    }

    /// Promotes a crash-left partial only when every condition of the
    /// approved contract holds: safe regular file; written during the
    /// current boot (so unsynced data was still in the page cache rather
    /// than exposed to power loss); readable with stored and processing
    /// formats matching the session; `0 < frames <= framesPerChunk`; and a
    /// complete sequential decode of exactly that many finite samples. The
    /// decoded audio is copied into a fresh hidden file, closed normally,
    /// re-opened and re-validated, synchronized, renamed without
    /// replacement to the canonical name, and the directory synchronized.
    /// The original partial is never renamed, edited or deleted. Any
    /// failure preserves it and is never retried with looser validation.
    private func promoteTail(_ candidate: TailCandidate, chunksDirectory: URL) -> PromotionResult {
        let partialURL = candidate.partialURL
        guard CompletedSessionPathSafety.checkExistingRegularFile(partialURL) == .safe else {
            return .failure("partial is not a regular file")
        }
        guard let bootTime = bootTimeProvider() else {
            return .failure("current boot time unavailable")
        }
        guard let modified = (try? partialURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified >= bootTime else {
            return .failure("partial was not written during the current boot")
        }
        guard let source = try? AVAudioFile(forReading: partialURL),
              Self.formatMatches(source, format: candidate.format) else {
            return .failure("partial is unreadable or its format does not match")
        }
        let expectedFrames = Int(source.length)
        guard expectedFrames > 0, expectedFrames <= candidate.framesPerChunk else {
            return .failure("partial frame count \(expectedFrames) is outside 1...\(candidate.framesPerChunk)")
        }

        let canonicalURL = chunksDirectory.appendingPathComponent(
            TranscriptionArtifactPaths.canonicalChunkFileName(for: candidate.sequenceNumber)
        )
        guard CompletedSessionPathSafety.checkExistingRegularFile(canonicalURL) == .missing else {
            return .failure("a canonical chunk already exists for this sequence")
        }

        let temporaryURL = chunksDirectory.appendingPathComponent(".\(UUID().uuidString).recovering.caf")
        func abandon(_ reason: String) -> PromotionResult {
            // Only this pass's own hidden temporary copy is ever removed.
            try? FileManager.default.removeItem(at: temporaryURL)
            return .failure(reason)
        }

        do {
            let processingFormat = source.processingFormat
            var destination: AVAudioFile? = try AVAudioFile(
                forWriting: temporaryURL,
                settings: processingFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: 8_192) else {
                destination = nil
                return abandon("unable to allocate a decode buffer")
            }
            var decoded = 0
            while source.framePosition < source.length {
                try source.read(into: buffer, frameCount: 8_192)
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { break }
                guard Self.allSamplesFinite(buffer) else {
                    destination = nil
                    return abandon("partial contains non-finite samples")
                }
                try destination?.write(from: buffer)
                decoded += frames
            }
            destination?.close()
            destination = nil
            guard decoded == expectedFrames else {
                return abandon("decoded \(decoded) of \(expectedFrames) partial frames")
            }
        } catch {
            return abandon("partial could not be fully decoded and copied")
        }

        guard Self.validatedFrameCount(at: temporaryURL, format: candidate.format) == expectedFrames else {
            return abandon("recovered copy failed re-validation")
        }
        do {
            try fileSystem.synchronizeFile(at: temporaryURL)
        } catch {
            return abandon("recovered copy could not be synchronized")
        }
        do {
            try fileSystem.rename(from: temporaryURL, to: canonicalURL)
        } catch is ChunkRenameCollision {
            return abandon("a canonical chunk appeared for this sequence")
        } catch {
            return abandon("recovered copy could not be published")
        }
        guard (try? fileSystem.synchronizeDirectory(at: chunksDirectory)) != nil else {
            // The canonical copy exists but its directory entry is not
            // confirmed durable; the next pass adopts it as canonical.
            return .deferred("recovered chunk's directory entry could not be synchronized")
        }

        return .success(Self.metadata(
            sequenceNumber: candidate.sequenceNumber,
            frameCount: expectedFrames,
            startFrame: candidate.startFrame,
            sampleRate: candidate.format.sampleRate
        ))
    }

    // MARK: - Validation helpers

    static func isSupportedCaptureFormat(_ format: AudioFormatDescriptor) -> Bool {
        format.formatIdentifier == "lpcm-float32"
            && format.bitsPerChannel == 32
            && format.channelCount > 0
            && format.sampleRate.isFinite
            && format.sampleRate > 0
    }

    /// The frame count of a safe, readable chunk file whose stored and
    /// processing formats match `format`, or `nil` (including for an empty
    /// or header-only file).
    static func validatedFrameCount(at url: URL, format: AudioFormatDescriptor) -> Int? {
        guard CompletedSessionPathSafety.checkExistingRegularFile(url) == .safe,
              let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        defer { file.close() }
        guard formatMatches(file, format: format) else { return nil }
        let length = Int(file.length)
        return length > 0 ? length : nil
    }

    private static func formatMatches(_ file: AVAudioFile, format: AudioFormatDescriptor) -> Bool {
        let stored = file.fileFormat.streamDescription.pointee
        return stored.mFormatID == kAudioFormatLinearPCM
            && (stored.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && stored.mBitsPerChannel == format.bitsPerChannel
            && stored.mSampleRate == format.sampleRate
            && stored.mChannelsPerFrame == format.channelCount
            && file.processingFormat.sampleRate == format.sampleRate
            && file.processingFormat.channelCount == format.channelCount
    }

    private static func allSamplesFinite(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channels = buffer.floatChannelData else { return false }
        let frames = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for index in 0..<frames where !samples[index].isFinite {
                return false
            }
        }
        return true
    }

    /// Metadata computed exactly as `AudioChunkWriter` computes it.
    private static func metadata(sequenceNumber: Int, frameCount: Int, startFrame: Int, sampleRate: Double) -> ChunkMetadata {
        ChunkMetadata(
            sequenceNumber: sequenceNumber,
            fileName: TranscriptionArtifactPaths.canonicalChunkFileName(for: sequenceNumber),
            startOffsetSeconds: Double(Int64(startFrame)) / sampleRate,
            durationSeconds: Double(frameCount) / sampleRate,
            frameCount: frameCount,
            state: .completed
        )
    }

    static func partialChunkFileName(for sequenceNumber: Int) -> String {
        "chunk_\(String(format: "%06d", sequenceNumber)).partial.caf"
    }

    /// Sequence numbers of exactly-named canonical and partial chunk files.
    /// Every other name (including hidden temporary files) is ignored.
    private static func chunkFileInventory(in directory: URL) -> (canonical: Set<Int>, partial: Set<Int>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var canonical: Set<Int> = []
        var partial: Set<Int> = []
        for name in names {
            if let value = sequenceNumber(in: name, suffix: ".partial.caf"), name == partialChunkFileName(for: value) {
                partial.insert(value)
            } else if let value = sequenceNumber(in: name, suffix: ".caf"),
                      name == TranscriptionArtifactPaths.canonicalChunkFileName(for: value) {
                canonical.insert(value)
            }
        }
        return (canonical, partial)
    }

    private static func sequenceNumber(in name: String, suffix: String) -> Int? {
        let prefix = "chunk_"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard digits.count == 6, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(digits)
    }

    // MARK: - Recovery log

    /// Best-effort, content-free diagnostic line in the session's own log.
    private func appendRecoveryLog(_ result: AbandonedRecordingRecoveryReport.RecoveredSession, paths: SessionPaths) {
        let logURL = paths.logFileURL
        guard CompletedSessionPathSafety.checkExistingDirectory(logURL.deletingLastPathComponent()) == .safe else { return }
        switch CompletedSessionPathSafety.checkExistingRegularFile(logURL) {
        case .safe:
            break
        case .missing:
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        case .unsafe:
            return
        }

        let tailText: String
        switch result.tail {
        case .none:
            tailText = "no partial tail"
        case .promoted(let sequence, let frames):
            tailText = "partial tail #\(sequence) promoted (\(frames) frames; original partial preserved)"
        case .preserved(let sequence, let reason):
            tailText = "partial tail\(sequence.map { " #\($0)" } ?? "") preserved untouched: \(reason)"
        }
        let integrity = result.referencedChunksIntact ? "" : "; referenced chunks failed validation, chunk list left unchanged"
        let line = "\(ISO8601DateFormatter().string(from: now())) [WARN] Abandoned recording recovered at launch as interrupted: "
            + "\(result.referencedChunkCount) referenced chunk(s), \(result.adoptedCanonicalChunkCount) adopted canonical chunk(s), "
            + "\(tailText)\(integrity).\n"

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
