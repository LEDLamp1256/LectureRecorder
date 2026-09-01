import Foundation

#if DEBUG
/// Test/preview double for `MicrophonePermissionServing`.
///
/// Wrapped in `#if DEBUG` so it never compiles into a Release build.
/// Xcode Previews and the `LectureRecorderTests` target both build using
/// the Debug configuration by default, so this remains available to both
/// without shipping in a Release/App Store build. If a custom scheme ever
/// points its Test or Preview action at a Release-style configuration,
/// this type (and anything referencing it) will fail to compile until
/// that's changed back — that's the intended safety net, not a bug.
final class MockMicrophonePermissionService: MicrophonePermissionServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: PermissionStatus

    init(status: PermissionStatus = .granted) {
        self._status = status
    }

    var status: PermissionStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _status
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _status = newValue
        }
    }

    func currentStatus() -> PermissionStatus {
        status
    }

    func requestPermission() async -> PermissionStatus {
        status
    }
}
#endif
