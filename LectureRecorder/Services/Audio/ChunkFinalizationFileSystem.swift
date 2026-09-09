//
//  ChunkFinalizationFileSystem.swift
//  LectureRecorder
//


import Darwin
import Foundation

/// A durability failure occurring while finalizing a completed chunk file
/// (syncing its data, renaming it into place, or syncing the containing
/// directory). Every case is terminal — there is no fallback path for any
/// of these operations.
///
/// `secondaryCloseErrno`/`secondaryCloseMessage` are populated only when a
/// descriptor's own `close(2)` fails *after* the primary sync operation on
/// that same descriptor also failed. In that pairing the sync failure stays
/// primary (it's the reason durability wasn't achieved); the close failure
/// is retained as diagnostic evidence, not discarded and not merely logged.
nonisolated struct ChunkDurabilityFailure: Error, Sendable, Equatable {
    nonisolated enum Stage: String, Sendable, Equatable {
        case partialFileOpen
        case partialFileSync
        case partialDescriptorClose
        case rename
        case directoryOpen
        case directorySync
        case directoryDescriptorClose
    }

    let stage: Stage
    let path: URL
    let primaryErrno: Int32
    let primaryMessage: String
    let secondaryCloseErrno: Int32?
    let secondaryCloseMessage: String?
}

/// Thrown by `ChunkFinalizationFileSystem.rename(from:to:)` specifically
/// when the destination already exists. This is kept distinct from
/// `ChunkDurabilityFailure` so a legitimate collision (something else
/// already owns this canonical name) can never be collapsed into a
/// generic durability failure by a caller's error handling.
nonisolated struct ChunkRenameCollision: Error, Sendable, Equatable {
    let destination: URL
}

/// Seam for the three filesystem operations a chunk's finalization needs
/// to durably commit a completed chunk file: syncing the completed
/// temporary file's data to stable storage, atomically (and
/// non-replacingly) renaming it into its canonical name, and syncing the
/// containing directory so that rename itself survives a crash.
///
/// This type deliberately owns only these three operations — not chunk
/// lifecycle, not error-to-domain-error mapping beyond the collision
/// distinction above. A caller (not implemented by this file) is
/// responsible for sequencing calls in the order that actually establishes
/// durability: `synchronizeFile` before `rename`, `rename` before
/// `synchronizeDirectory`.
nonisolated protocol ChunkFinalizationFileSystem: Sendable {
    /// Syncs the file at `url` to stable storage. Intended to be called on
    /// a chunk's completed temporary (`.partial`) file, after its
    /// `AVAudioFile` has already been closed and before it is renamed into
    /// place.
    func synchronizeFile(at url: URL) throws

    /// Renames `source` to `destination` without replacing an existing
    /// file at `destination`. Throws `ChunkRenameCollision` if
    /// `destination` already exists; throws `ChunkDurabilityFailure` for
    /// any other rename failure. Neither argument path is affected by a
    /// failure of either kind.
    func rename(from source: URL, to destination: URL) throws

    /// Syncs the directory at `url` to stable storage. Intended to be
    /// called on a chunk's containing chunks directory, after the rename
    /// above has already succeeded, so the rename's directory-entry
    /// update is itself durable.
    func synchronizeDirectory(at url: URL) throws
}

/// Production `ChunkFinalizationFileSystem` backed by raw Darwin syscalls:
/// `fcntl(_:F_FULLFSYNC)` for durability (never falls back to plain
/// `fsync` — an F_FULLFSYNC failure is always terminal), and
/// `renamex_np(_:_:RENAME_EXCL)` for a same-directory rename that refuses
/// to replace an existing destination.
///
/// The individual syscalls are routed through an injectable `Syscalls`
/// bundle so this adapter's own descriptor-close-pairing behavior (sync
/// succeeds/fails crossed with close succeeds/fails) can be proven
/// deterministically in tests without needing to force real POSIX failure
/// conditions on a live file descriptor. `init()` — what any real caller
/// uses — always wires up the live syscalls; only tests use the
/// `init(syscalls:)` seam.
nonisolated struct DarwinChunkFinalizationFileSystem: ChunkFinalizationFileSystem {
    /// A minimal syscall bundle returning `(returnValue, errno)` pairs
    /// rather than relying on the global `errno` still holding the right
    /// value by the time a caller inspects it. Production closures below
    /// capture `errno` immediately after their syscall and before
    /// anything else can run.
    struct Syscalls: Sendable {
        var open: @Sendable (String, Int32) -> (rv: Int32, errno: Int32)
        var fullfsync: @Sendable (Int32) -> (rv: Int32, errno: Int32)
        var close: @Sendable (Int32) -> (rv: Int32, errno: Int32)
        var renameExcl: @Sendable (String, String) -> (rv: Int32, errno: Int32)

        static let live = Syscalls(
            open: { path, flags in
                let rv = Darwin.open(path, flags)
                return (rv, rv < 0 ? errno : 0)
            },
            fullfsync: { fd in
                let rv = fcntl(fd, F_FULLFSYNC)
                return (rv, rv != 0 ? errno : 0)
            },
            close: { fd in
                // Never retried on EINTR — Darwin's close(2) man page gives
                // no guidance that the descriptor is still valid/safe to
                // retry after EINTR, so a single attempt is the only
                // documented-safe behavior.
                let rv = Darwin.close(fd)
                return (rv, rv != 0 ? errno : 0)
            },
            renameExcl: { source, destination in
                let rv = renamex_np(source, destination, UInt32(RENAME_EXCL))
                return (rv, rv != 0 ? errno : 0)
            }
        )
    }

    private let syscalls: Syscalls

    init() {
        self.syscalls = .live
    }

    init(syscalls: Syscalls) {
        self.syscalls = syscalls
    }

    func synchronizeFile(at url: URL) throws {
        try synchronize(
            at: url,
            openFlags: O_RDONLY,
            openStage: .partialFileOpen,
            syncStage: .partialFileSync,
            closeStage: .partialDescriptorClose
        )
    }

    func synchronizeDirectory(at url: URL) throws {
        try synchronize(
            at: url,
            openFlags: O_RDONLY | O_DIRECTORY,
            openStage: .directoryOpen,
            syncStage: .directorySync,
            closeStage: .directoryDescriptorClose
        )
    }

    func rename(from source: URL, to destination: URL) throws {
        let (rv, err) = syscalls.renameExcl(source.path, destination.path)
        guard rv == 0 else {
            if err == EEXIST {
                throw ChunkRenameCollision(destination: destination)
            }
            throw ChunkDurabilityFailure(
                stage: .rename,
                path: destination,
                primaryErrno: err,
                primaryMessage: String(cString: strerror(err)),
                secondaryCloseErrno: nil,
                secondaryCloseMessage: nil
            )
        }
    }

    /// Opens `url`, issues `F_FULLFSYNC`, then evaluates the descriptor's
    /// own close result — implementing the exact pairing policy required
    /// for both the partial-file and directory sync operations:
    /// sync-ok/close-ok continues; sync-ok/close-fails surfaces the close
    /// failure as terminal; sync-fails/close-ok surfaces the sync failure
    /// as terminal; sync-fails/close-fails keeps the sync failure primary
    /// and retains the close failure as secondary diagnostic information.
    private func synchronize(
        at url: URL,
        openFlags: Int32,
        openStage: ChunkDurabilityFailure.Stage,
        syncStage: ChunkDurabilityFailure.Stage,
        closeStage: ChunkDurabilityFailure.Stage
    ) throws {
        let (fd, openErr) = syscalls.open(url.path, openFlags)
        guard fd >= 0 else {
            throw ChunkDurabilityFailure(
                stage: openStage,
                path: url,
                primaryErrno: openErr,
                primaryMessage: String(cString: strerror(openErr)),
                secondaryCloseErrno: nil,
                secondaryCloseMessage: nil
            )
        }

        let (syncRv, syncErr) = syscalls.fullfsync(fd)
        let syncFailed = syncRv != 0

        let (closeRv, closeErr) = syscalls.close(fd)
        let closeFailed = closeRv != 0

        switch (syncFailed, closeFailed) {
        case (false, false):
            return
        case (false, true):
            throw ChunkDurabilityFailure(
                stage: closeStage,
                path: url,
                primaryErrno: closeErr,
                primaryMessage: String(cString: strerror(closeErr)),
                secondaryCloseErrno: nil,
                secondaryCloseMessage: nil
            )
        case (true, false):
            throw ChunkDurabilityFailure(
                stage: syncStage,
                path: url,
                primaryErrno: syncErr,
                primaryMessage: String(cString: strerror(syncErr)),
                secondaryCloseErrno: nil,
                secondaryCloseMessage: nil
            )
        case (true, true):
            throw ChunkDurabilityFailure(
                stage: syncStage,
                path: url,
                primaryErrno: syncErr,
                primaryMessage: String(cString: strerror(syncErr)),
                secondaryCloseErrno: closeErr,
                secondaryCloseMessage: String(cString: strerror(closeErr))
            )
        }
    }
}
