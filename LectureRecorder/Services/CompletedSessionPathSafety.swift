import Foundation

/// Read-only filesystem-shape checks for T4's completed-session discovery
/// and eligibility validation.
///
/// Scope: this guards against an app-owned session path unexpectedly being
/// a symlink or the wrong filesystem type — for example a session
/// directory or artifact file replaced by a symlink pointing elsewhere on
/// the same volume. It is **not** adversarial, descriptor-based hardening
/// against a concurrently-racing same-user attacker (TOCTOU between this
/// check and a later open is not closed here); it assumes the ordinary
/// case of app-owned storage without a competing external writer. Every
/// check below uses `URL.resourceValues`, whose `.isSymbolicLinkKey` is
/// computed on the path's own leaf component (an `lstat`-style check) and
/// is never followed — a symlinked path is detected and rejected without
/// this code ever opening or reading whatever it points to.
nonisolated enum CompletedSessionPathSafety {
    /// The result of checking one path against an expected filesystem
    /// shape: present and safe, absent entirely, or present but unsafe
    /// (a symlink, or the wrong type).
    nonisolated enum PathCheckResult: Sendable, Equatable {
        case safe
        case missing
        case unsafe
    }

    static func checkExistingDirectory(_ url: URL) -> PathCheckResult {
        check(url, expectedKey: \.isDirectory)
    }

    static func checkExistingRegularFile(_ url: URL) -> PathCheckResult {
        check(url, expectedKey: \.isRegularFile)
    }

    private static func check(
        _ url: URL,
        expectedKey: KeyPath<URLResourceValues, Bool?>
    ) -> PathCheckResult {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        } catch {
            return .missing
        }
        guard values.isSymbolicLink != true else { return .unsafe }
        return values[keyPath: expectedKey] == true ? .safe : .unsafe
    }
}
