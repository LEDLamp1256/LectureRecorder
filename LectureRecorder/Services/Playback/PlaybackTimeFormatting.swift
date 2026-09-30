import Foundation

/// Deterministic session-relative time labels: `M:SS` under an hour,
/// `H:MM:SS` from an hour on. Whole seconds are truncated (elapsed-time
/// convention); negative or non-finite input displays as `0:00`.
nonisolated enum PlaybackTimeFormatting {
    static func label(forSeconds seconds: Double) -> String {
        // The upper bound only keeps `Int(_:)` from trapping on absurd input.
        let total = seconds.isFinite && seconds > 0 ? Int(min(seconds, 1e12).rounded(.down)) : 0
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))"
        }
        return "\(minutes):\(twoDigits(secs))"
    }

    /// `elapsed / total`, e.g. `12:34 / 1:26:54`.
    static func progressLabel(elapsedSeconds: Double, totalSeconds: Double) -> String {
        "\(label(forSeconds: elapsedSeconds)) / \(label(forSeconds: totalSeconds))"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
