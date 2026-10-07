import Foundation
import os
import XCTest
@testable import LectureRecorder

/// Small real on-disk sessions (16 kHz mono CAF chunks plus `session.json`)
/// for the D3 source loader and service tests.
enum SessionDiarizationTestSupport {
    static let sampleRate: Double = 16_000
    /// 1 s + 0.5 s.
    static let defaultFrameCounts = [16_000, 8_000]
    static let createdDate = Date(timeIntervalSince1970: 1_800_000_000)

    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionDiarizationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes (or rewrites) a session's chunk files and manifest. Rewriting
    /// an existing session replaces its audio and manifest in place.
    @discardableResult
    static func writeSession(
        root: URL,
        sessionID: UUID = UUID(),
        status: SessionStatus = .completed,
        frameCounts: [Int] = defaultFrameCounts
    ) throws -> (manifest: SessionManifest, paths: SessionPaths) {
        var manifest = PlaybackTestManifest.make(sessionID: sessionID, sampleRate: sampleRate, frameCounts: frameCounts)
        manifest.status = status
        if status != .completed {
            manifest.endedCleanly = false
            manifest.endReason = status == .failed ? .error : .appTerminated
        }
        let paths = try DefaultFileSystemLocator.buildPaths(rootDirectory: root, sessionID: sessionID)
        for name in try FileManager.default.contentsOfDirectory(atPath: paths.chunksDirectory.path) {
            try FileManager.default.removeItem(at: paths.chunksDirectory.appendingPathComponent(name))
        }
        var firstFrame: Int64 = 0
        for chunk in manifest.chunks {
            try PlaybackTestAudio.writeChunk(
                to: paths.chunksDirectory.appendingPathComponent(chunk.fileName),
                frameCount: chunk.frameCount,
                firstSessionFrame: firstFrame,
                sampleRate: sampleRate
            )
            firstFrame += Int64(chunk.frameCount)
        }
        try writeManifest(manifest, paths: paths)
        return (manifest, paths)
    }

    static func writeManifest(_ manifest: SessionManifest, paths: SessionPaths) throws {
        try AtomicFileWriter.writeJSON(manifest, to: paths.manifestURL)
    }

    static func loader(root: URL) -> SessionDiarizationSourceLoader {
        SessionDiarizationSourceLoader(sessionsRootResolver: { root })
    }

    static let provenance = SpeakerDiarizationProvenance(
        backendIdentifier: "fake-diarizer",
        backendVersion: "1",
        configurationIdentifier: "test"
    )

    /// Raw backend labels deliberately not in first-speech order, so
    /// normalization is observable.
    static func output(provenance: SpeakerDiarizationProvenance = provenance) -> SpeakerDiarizationOutput {
        SpeakerDiarizationOutput(
            provenance: provenance,
            segments: [
                DiarizationBackendSegment(label: "SPEAKER_B", startSeconds: 0, endSeconds: 0.6),
                DiarizationBackendSegment(label: "SPEAKER_A", startSeconds: 0.6, endSeconds: 1.2),
                DiarizationBackendSegment(label: "SPEAKER_B", startSeconds: 1.2, endSeconds: 1.5),
            ]
        )
    }

    static func sidecarURL(_ paths: SessionPaths) -> URL {
        DiarizationArtifactPaths.resultURL(sessionPaths: paths)
    }

    static func sidecarData(_ paths: SessionPaths) -> Data? {
        try? Data(contentsOf: sidecarURL(paths))
    }

    /// Saves an ordinary valid sidecar for the session's current audio
    /// through the real store and returns its exact bytes.
    @discardableResult
    static func seedSidecar(root: URL, sessionID: UUID) async throws -> Data {
        let snapshot = try await loader(root: root).loadSourceSnapshot(sessionID: sessionID)
        let old = try SpeakerDiarizationResult(
            sessionID: sessionID,
            createdDate: Date(timeIntervalSince1970: 1_000_000),
            provenance: SpeakerDiarizationProvenance(backendIdentifier: "older", backendVersion: "0", configurationIdentifier: "old"),
            audioSource: snapshot.audioSource,
            ranges: [SpeakerTimeRange(speakerID: try SpeakerID(index: 0), startSeconds: 0, endSeconds: 1)]
        )
        try SpeakerDiarizationStore().save(old, source: snapshot.source, sessionPaths: snapshot.sessionPaths)
        return try XCTUnwrap(sidecarData(snapshot.sessionPaths))
    }

    /// Every entry beneath `directory` by relative path: file bytes, a
    /// symlink's destination, or a directory marker — for proving nothing
    /// was created, changed, or removed.
    static func tree(_ directory: URL) throws -> [String: String] {
        var entries: [String: String] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: directory.path) else { return entries }
        for case let relative as String in enumerator {
            let path = directory.appendingPathComponent(relative).path
            let attributes = try fm.attributesOfItem(atPath: path)
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink?:
                entries[relative] = "link:" + (try fm.destinationOfSymbolicLink(atPath: path))
            case .typeDirectory?:
                entries[relative] = "dir"
            default:
                entries[relative] = "file:" + (try Data(contentsOf: URL(fileURLWithPath: path))).base64EncodedString()
            }
        }
        return entries
    }
}

struct FakeDiarizerError: LocalizedError, Equatable {
    var errorDescription: String? { "fake backend failure" }
}

/// How `FakeSpeakerDiarizer` holds its call. `.cooperative` waits
/// (honoring cancellation) until opened; `.uncooperative` ignores
/// cancellation until opened, like FluidAudio's final clustering step.
enum FakeDiarizerGate: Sendable {
    case open
    case cooperative
    case uncooperative
}

/// A controllable `SpeakerDiarizing` fake. State is lock-guarded so the
/// fake is `Sendable` without being an actor.
final class FakeSpeakerDiarizer: SpeakerDiarizing, Sendable {
    private struct State {
        var isOpen = false
        var requests: [SpeakerDiarizationRequest] = []
        var sawCancellationWhileGated = false
    }

    private let gate: FakeDiarizerGate
    private let response: Result<SpeakerDiarizationOutput, FakeDiarizerError>
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        gate: FakeDiarizerGate = .open,
        response: Result<SpeakerDiarizationOutput, FakeDiarizerError>? = nil
    ) {
        self.gate = gate
        self.response = response ?? .success(SessionDiarizationTestSupport.output())
    }

    var requests: [SpeakerDiarizationRequest] { state.withLock { $0.requests } }
    var callCount: Int { requests.count }
    var hasEntered: Bool { callCount > 0 }
    var sawCancellationWhileGated: Bool { state.withLock { $0.sawCancellationWhileGated } }

    func open() { state.withLock { $0.isOpen = true } }

    private var isOpen: Bool { state.withLock { $0.isOpen } }

    func diarize(_ request: SpeakerDiarizationRequest) async throws -> SpeakerDiarizationOutput {
        state.withLock { $0.requests.append(request) }
        switch gate {
        case .open:
            break
        case .cooperative:
            while !isOpen {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        case .uncooperative:
            while !isOpen {
                if Task.isCancelled { state.withLock { $0.sawCancellationWhileGated = true } }
                await Task.yield()
            }
        }
        return try response.get()
    }
}

/// Wraps the production committer and, when armed, holds each commit
/// before the real atomic save starts until released — so a test can act
/// while an operation is commit-authorized but nothing is written yet.
final class HoldingSidecarCommitter: SessionDiarizationSidecarCommitting, Sendable {
    private struct State {
        var isReleased = false
        var commitCount = 0
        var completedSaveCount = 0
    }

    private let holds: Bool
    private let wrapped = SpeakerDiarizationStoreCommitter()
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(holds: Bool = true) {
        self.holds = holds
    }

    var commitCount: Int { state.withLock { $0.commitCount } }
    var completedSaveCount: Int { state.withLock { $0.completedSaveCount } }
    var hasEntered: Bool { commitCount > 0 }

    func release() { state.withLock { $0.isReleased = true } }

    func commit(_ result: SpeakerDiarizationResult, to snapshot: SessionDiarizationSourceSnapshot) async throws {
        state.withLock { $0.commitCount += 1 }
        // Deliberately ignores cancellation: an authorized save must run.
        while holds, !state.withLock({ $0.isReleased }) {
            await Task.yield()
        }
        try await wrapped.commit(result, to: snapshot)
        state.withLock { $0.completedSaveCount += 1 }
    }
}

/// Wraps the production source loader and holds the `heldCall`-th load
/// (1-based) after it has fully loaded and validated, until opened — the
/// last suspension a run makes before commit authorization when
/// `heldCall` is the post-inference reload.
final class HoldingSourceLoader: SessionDiarizationSourceLoading, Sendable {
    private struct State {
        var callCount = 0
        var heldCallLoaded = false
        var isOpen = false
    }

    private let wrapped: SessionDiarizationSourceLoader
    private let heldCall: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(root: URL, heldCall: Int = 2) {
        self.wrapped = SessionDiarizationTestSupport.loader(root: root)
        self.heldCall = heldCall
    }

    var heldCallLoaded: Bool { state.withLock { $0.heldCallLoaded } }

    func open() { state.withLock { $0.isOpen = true } }

    func loadSourceSnapshot(sessionID: UUID) async throws -> SessionDiarizationSourceSnapshot {
        let call = state.withLock { state -> Int in
            state.callCount += 1
            return state.callCount
        }
        let snapshot = try await wrapped.loadSourceSnapshot(sessionID: sessionID)
        guard call == heldCall else { return snapshot }
        state.withLock { $0.heldCallLoaded = true }
        while !state.withLock({ $0.isOpen }) {
            await Task.yield()
        }
        return snapshot
    }
}
