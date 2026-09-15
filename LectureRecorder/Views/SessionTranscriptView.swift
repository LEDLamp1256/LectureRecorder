import SwiftUI

/// Displays one selected completed session's metadata, transcription
/// status/progress, actions, and (once available) its ordered transcript.
///
/// Observes the single, shared `CompletedSessionTranscriptionService` (for
/// live operation phase/progress/segments) and owns one window-local
/// `SessionTranscriptPresenter` for its own best-effort status/transcript
/// display cache. This view issues no `TranscriptionCoordinator` calls of
/// its own, owns no persistent background `Task`, and Transcribe/Continue/
/// Retry/Cancel all call straight through to the shared `service`. Action
/// enablement and the Busy-elsewhere banner are computed by the pure
/// `SessionActionAvailabilityCalculator` — this session's own saved status
/// is never reinterpreted as an integrity problem merely because a
/// *different* session currently owns the shared operation.
struct SessionTranscriptView: View {
    let entry: CompletedSessionEntry
    @ObservedObject var service: CompletedSessionTranscriptionService
    @StateObject private var presenter: SessionTranscriptPresenter

    init(entry: CompletedSessionEntry, service: CompletedSessionTranscriptionService) {
        self.entry = entry
        self.service = service
        _presenter = StateObject(wrappedValue: SessionTranscriptPresenter(loader: service))
    }

    private var sessionID: UUID { entry.manifest.sessionID }

    private var ownership: SessionOwnershipDisplay {
        SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: service.activeSessionID, sessionID: sessionID)
    }

    private var isActiveOperation: Bool { ownership == .activeHere }

    private var peekedStatus: SessionTranscriptionStatus? {
        presenter.displayedSessionID == sessionID ? presenter.status : nil
    }

    private var availability: SessionActionAvailability {
        SessionActionAvailabilityCalculator.availability(peekedStatus: peekedStatus, ownership: ownership)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            metadataSection
            statusSection
            actionButtons
            Divider()
            transcriptSection
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: sessionID) {
            await presenter.refresh(for: entry)
        }
        .onChange(of: service.activeSessionID) { oldValue, newValue in
            guard SessionOwnershipTransition.shouldRefreshDurableState(
                oldActiveSessionID: oldValue,
                newActiveSessionID: newValue,
                sessionID: sessionID
            ) else { return }
            Task { await presenter.refresh(for: entry) }
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Session \(sessionID.uuidString)")
                .font(.title3.bold())
            Text("Recorded \(entry.manifest.creationDate.formatted(date: .abbreviated, time: .shortened)) · \(entry.manifest.chunks.count) chunks")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch ownership {
        case .activeHere:
            liveStatusText(service.phase)
        case .busyElsewhere:
            Label("Busy — another session is currently being transcribed", systemImage: "hourglass.circle")
                .foregroundStyle(.secondary)
        case .none:
            if let peekedStatus {
                savedStatusText(peekedStatus)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder private func liveStatusText(_ phase: CompletedSessionTranscriptionService.OperationPhase) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .preparing:
            Label("Preparing…", systemImage: "hourglass")
        case .recovering:
            Label("Checking previous progress…", systemImage: "arrow.triangle.2.circlepath")
        case .enqueuing:
            Label("Preparing chunks…", systemImage: "tray.and.arrow.down")
        case .processing(let completed, let total, let processing):
            Label(
                SessionProgressFormatting.processingLabel(completed: completed, total: total, currentlyProcessingSequence: processing),
                systemImage: "waveform"
            )
        case .cancelling:
            Label("Cancelling…", systemImage: "xmark.circle")
        case .finished(let status):
            savedStatusText(status)
        }
    }

    @ViewBuilder private func savedStatusText(_ status: SessionTranscriptionStatus) -> some View {
        switch status {
        case .notTranscribed:
            Label("Not transcribed", systemImage: "circle.dashed")
        case .zeroChunkSession:
            Label("No recorded audio", systemImage: "exclamationmark.triangle")
        case .incomplete(let completed, let total):
            Label("\(completed) / \(total) saved", systemImage: "waveform")
        case .interrupted:
            Label("Interrupted — recovery available", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
        case .recoveryPending:
            Label("Recovery pending", systemImage: "clock.arrow.circlepath")
        case .completed:
            Label("Completed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .blocked(let reasons):
            Label("Needs attention: \(reasons.joined(separator: "; "))", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("Transcribe") {
                service.transcribe(sessionID: sessionID)
            }
            .disabled(!availability.canTranscribe)

            Button(continueOrRetryLabel) {
                service.continueOrRetry(sessionID: sessionID)
            }
            .disabled(!availability.canContinueOrRetry)

            Button("Cancel", role: .destructive) {
                service.cancel(sessionID: sessionID)
            }
            .disabled(!availability.canCancel)
        }
        .buttonStyle(.bordered)
    }

    private var continueOrRetryLabel: String {
        if case .interrupted = peekedStatus { return "Retry" }
        return "Continue"
    }

    @ViewBuilder private var transcriptSection: some View {
        let segments = isActiveOperation ? service.displayedSegments : (presenter.displayedSessionID == sessionID ? presenter.segments : [])
        if !segments.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(segments, id: \.sequenceNumber) { segment in
                        segmentView(segment)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func segmentView(_ segment: OrderedSegment) -> some View {
        switch segment.state {
        case .completed(let text):
            Text(text.isEmpty ? "(silence)" : text)
                .textSelection(.enabled)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
        case .failed(let failure):
            Text("Chunk #\(segment.sequenceNumber): \(failure.message)")
                .foregroundStyle(.red)
                .font(.caption)
        case .inProgress:
            Text("Chunk #\(segment.sequenceNumber): in progress…")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .missing:
            Text("Chunk #\(segment.sequenceNumber): missing")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }
}
