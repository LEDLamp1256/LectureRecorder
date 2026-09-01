import AVFoundation

enum PermissionStatus: Equatable, Sendable {
    case undetermined
    case granted
    case denied
    case restricted
}

protocol MicrophonePermissionServing: Sendable {
    /// Reads the current permission status without prompting the user.
    func currentStatus() -> PermissionStatus

    /// Prompts the user if the status is undetermined; otherwise returns
    /// the existing status immediately.
    func requestPermission() async -> PermissionStatus
}

/// Thin wrapper over `AVCaptureDevice`'s authorization APIs.
/// Stateless by design, so it is trivially `Sendable`.
struct MicrophonePermissionService: MicrophonePermissionServing, Sendable {
    func currentStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .undetermined
        @unknown default:
            return .undetermined
        }
    }

    func requestPermission() async -> PermissionStatus {
        let existing = currentStatus()
        guard existing == .undetermined else {
            return existing
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }
}
