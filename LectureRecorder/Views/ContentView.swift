import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.openWindow) private var openWindow
    @State private var showAbandonRecoveryConfirmation = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Lecture Recorder")
                .font(.title)
                .bold()

            PermissionStatusView(status: sessionManager.lastKnownPermissionStatus)

            StateBadge(state: sessionManager.state)

            if let issue = sessionManager.unresolvedIssue {
                UnresolvedIssueView(issue: issue)
                HStack(spacing: 12) {
                    Button("Retry") {
                        Task { await sessionManager.retryResolution() }
                    }
                    .disabled(!sessionManager.canRetry)

                    Button("Abandon Recovery Attempt", role: .destructive) {
                        showAbandonRecoveryConfirmation = true
                    }
                    .disabled(!sessionManager.canDiscard)
                }
            } else if sessionManager.canReset {
                Button("Reset") {
                    sessionManager.resetAfterFailure()
                }
            }

            if let session = sessionManager.activeSession {
                SessionInfoView(title: "Active Session", session: session)
            } else if let session = sessionManager.lastCompletedSession {
                SessionInfoView(title: "Last Completed Session", session: session)
            }

            HStack(spacing: 16) {
                Button {
                    Task { await sessionManager.startSession() }
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(minWidth: 150)
                }
                .disabled(!sessionManager.canStart)

                Button {
                    Task { await sessionManager.stopSession() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle")
                        .frame(minWidth: 150)
                }
                .disabled(!sessionManager.canStop)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if case .failed(let message) = sessionManager.state, sessionManager.unresolvedIssue == nil {
                Text("Last error: \(message)")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            Divider()

            Button {
                Task { await sessionManager.revealSessionsFolderInFinder() }
            } label: {
                Label("Show Sessions Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Button {
                openWindow(id: "completed-sessions")
            } label: {
                Label("Completed Sessions", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.bordered)

            if let error = sessionManager.revealFolderErrorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 520)
        .task {
            await sessionManager.refreshPermissionStatus()
        }
        .alert(
            "Abandon Recovery Attempt?",
            isPresented: $showAbandonRecoveryConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Abandon Recovery", role: .destructive) {
                Task {
                    await sessionManager.discardUnresolvedSession()
                    sessionManager.resetAfterFailure()
                }
            }
        } message: {
            Text("The app will stop trying to confirm whether this session finished saving. Nothing on disk is deleted — the session's files remain in the Sessions folder exactly as they are now. Use \"Show Sessions Folder\" afterward if you want to inspect or recover them by hand.")
        }
    }
}

private struct StateBadge: View {
    let state: RecordingState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private var label: String {
        switch state {
        case .idle: return "Idle"
        case .requestingPermission: return "Requesting Permission"
        case .preparing: return "Preparing Session"
        case .recording: return "Recording"
        case .stopping: return "Stopping"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private var color: Color {
        switch state {
        case .idle, .completed:
            return .secondary
        case .requestingPermission, .preparing, .stopping:
            return .orange
        case .recording, .failed:
            return .red
        }
    }
}

private struct UnresolvedIssueView: View {
    let issue: UnresolvedSessionIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Unresolved session issue", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(issue.message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SessionInfoView: View {
    let title: String
    let session: SessionManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text("Session ID: \(session.sessionID.uuidString)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Started: \(session.creationDate.formatted(date: .abbreviated, time: .standard))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let endDate = session.endDate {
                Text("Ended: \(endDate.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failureDescription = session.failureDescription {
                Text("Failure: \(failureDescription)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environmentObject(
            SessionManager(
                store: SessionStore(),
                permissionService: MockMicrophonePermissionService(status: .granted),
                captureService: MockAudioCaptureService(
                    formatToPrepare: AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: 44_100,
                        channels: 1,
                        interleaved: false
                    )!
                ),
                chunkWriterFactory: DefaultAudioChunkWriterFactory()
            )
        )
}
#endif
