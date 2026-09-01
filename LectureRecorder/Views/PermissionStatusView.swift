import SwiftUI

struct PermissionStatusView: View {
    let status: PermissionStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var text: String {
        switch status {
        case .undetermined:
            return "Microphone permission not yet requested."
        case .granted:
            return "Microphone access granted."
        case .denied:
            return "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
        case .restricted:
            return "Microphone access is restricted on this Mac."
        }
    }

    private var iconName: String {
        switch status {
        case .undetermined: return "mic.badge.plus"
        case .granted: return "mic.fill"
        case .denied, .restricted: return "mic.slash.fill"
        }
    }

    private var iconColor: Color {
        switch status {
        case .undetermined: return .secondary
        case .granted: return .green
        case .denied, .restricted: return .red
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        PermissionStatusView(status: .undetermined)
        PermissionStatusView(status: .granted)
        PermissionStatusView(status: .denied)
        PermissionStatusView(status: .restricted)
    }
    .padding()
}
