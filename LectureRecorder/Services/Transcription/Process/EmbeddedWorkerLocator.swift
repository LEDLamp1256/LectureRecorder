import Foundation

/// Every way `EmbeddedWorkerLocator` can refuse to hand back an executable
/// URL. Distinguished from `ProcessRunFailure` because these are resolution
/// failures that occur before any process is ever considered for launch.
nonisolated enum EmbeddedWorkerLocatorError: LocalizedError, Sendable, Equatable {
    case executablesDirectoryUnavailable
    case helperMissing(URL)
    case helperNotARegularFile(URL)
    case helperNotExecutable(URL)
    case helperEscapesExecutablesDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .executablesDirectoryUnavailable:
            return "The running app bundle's executable directory could not be resolved."
        case .helperMissing(let url):
            return "Embedded worker helper not found at \(url.path)."
        case .helperNotARegularFile(let url):
            return "Embedded worker helper at \(url.path) is not a regular file (symbolic links, FIFOs, sockets, devices, and directories are all rejected)."
        case .helperNotExecutable(let url):
            return "Embedded worker helper at \(url.path) is not executable."
        case .helperEscapesExecutablesDirectory(let url):
            return "Resolved embedded worker helper location \(url.path) does not remain inside the app's executable directory."
        }
    }
}

/// The single, trusted source of the embedded worker helper's executable
/// location. This is deliberately the *only* place in the app target that
/// is allowed to answer "which executable should the process runner
/// launch" — `TranscriptionWorkerClient` consumes this and never accepts an
/// executable path from job, request, environment, or any other untrusted
/// source. Mirrors this repository's existing "validate a path before ever
/// touching disk" precedent (`TranscriptionArtifactPaths.validated`), which
/// also standardizes a candidate URL and proves it remains beneath its
/// intended directory before trusting it.
nonisolated enum EmbeddedWorkerLocator {
    /// The helper's fixed filename, exactly as produced by the "Embed
    /// Helper Tools" Copy Files build phase into
    /// `LectureRecorder.app/Contents/MacOS/`.
    static let helperFileName = "LectureRecorderWorkerFixture"

    /// Resolves, standardizes, and validates the embedded worker helper's
    /// location. Never derives the executable directory from job, request,
    /// or environment data — always from `Bundle.main.executableURL`, the
    /// one trusted resolver for "where is this running app's own
    /// executable."
    static func resolve(bundle: Bundle = .main, fileManager: FileManager = .default) -> Result<URL, EmbeddedWorkerLocatorError> {
        guard let executableURL = bundle.executableURL else {
            return .failure(.executablesDirectoryUnavailable)
        }

        let executablesDirectory = executableURL.deletingLastPathComponent().standardizedFileURL
        let candidate = executablesDirectory
            .appendingPathComponent(helperFileName)
            .standardizedFileURL

        return validate(candidate: candidate, expectedDirectory: executablesDirectory, fileManager: fileManager)
    }

    /// The independently-testable core of `resolve(bundle:fileManager:)`,
    /// separated from `Bundle` resolution specifically so its rejection
    /// rules (symlinks, non-regular files, directory escape, executable
    /// permission) can be exercised directly against a temporary
    /// directory in tests, without needing a real signed app bundle.
    ///
    /// Rejects:
    /// - a missing path;
    /// - anything that is itself a symbolic link, regardless of what it
    ///   points to (checked via `URLResourceValues.isSymbolicLink`, which
    ///   reflects the candidate path itself — `lstat` semantics — never
    ///   what a symlink resolves to);
    /// - anything that is not a regular file once symlinks are ruled out
    ///   (`URLResourceValues.isRegularFile`) — this covers directories,
    ///   FIFOs, sockets, and device nodes in one check, rather than only
    ///   distinguishing "directory" from "not directory" as an earlier
    ///   version of this type did;
    /// - anything without the executable permission bit;
    /// - anything whose *symlink-resolved* absolute path does not remain
    ///   inside `expectedDirectory`'s own symlink-resolved absolute path
    ///   — containment is checked against resolved paths, not merely
    ///   standardized ones, as defense in depth beyond the symlink
    ///   rejection above.
    static func validate(
        candidate: URL,
        expectedDirectory: URL,
        fileManager: FileManager = .default
    ) -> Result<URL, EmbeddedWorkerLocatorError> {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return .failure(.helperMissing(candidate))
        }

        let resourceKeys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey]
        let resourceValues: URLResourceValues
        do {
            resourceValues = try candidate.resourceValues(forKeys: resourceKeys)
        } catch {
            return .failure(.helperNotARegularFile(candidate))
        }

        // `isSymbolicLink` reflects the candidate path itself (lstat-style
        // semantics) regardless of what it points to — a symlink to a
        // perfectly valid executable is still rejected here, before
        // `isRegularFile` (which follows symlinks) would otherwise let it
        // through.
        guard resourceValues.isSymbolicLink != true else {
            return .failure(.helperNotARegularFile(candidate))
        }
        guard resourceValues.isRegularFile == true else {
            return .failure(.helperNotARegularFile(candidate))
        }

        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let resolvedDirectory = expectedDirectory.resolvingSymlinksInPath()
        let directoryPrefix = resolvedDirectory.path.hasSuffix("/")
            ? resolvedDirectory.path
            : resolvedDirectory.path + "/"
        guard resolvedCandidate.path.hasPrefix(directoryPrefix) else {
            return .failure(.helperEscapesExecutablesDirectory(candidate))
        }

        guard fileManager.isExecutableFile(atPath: candidate.path) else {
            return .failure(.helperNotExecutable(candidate))
        }

        return .success(candidate)
    }
}
