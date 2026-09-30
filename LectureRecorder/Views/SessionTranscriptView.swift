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
///
/// Playback is independent of transcription: a window-local
/// `SessionPlaybackPresenter` prepares this session's audio when the view
/// appears (never auto-playing) and stops it when the view disappears. A
/// completed transcript with loaded navigation shows each passage with a
/// timestamp button that plays from that passage.
struct SessionTranscriptView: View {
    let entry: CompletedSessionEntry
    @ObservedObject var service: CompletedSessionTranscriptionService
    @StateObject private var presenter: SessionTranscriptPresenter
    @StateObject private var playback = SessionPlaybackPresenter()
    /// While the time slider is being dragged, the position it previews.
    /// UI-only: the presenter's position stays authoritative, and one seek
    /// is issued when the drag ends.
    @State private var scrubPreviewSeconds: Double?

    init(
        entry: CompletedSessionEntry,
        service: CompletedSessionTranscriptionService,
        navigationLoader: any CompletedTranscriptNavigationLoading
    ) {
        self.entry = entry
        self.service = service
        _presenter = StateObject(wrappedValue: SessionTranscriptPresenter(loader: service, navigationLoader: navigationLoader))
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
            playbackBar
            transcriptSection
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: sessionID) {
            await presenter.refresh(for: entry)
        }
        .task(id: sessionID) {
            scrubPreviewSeconds = nil
            await playback.prepare(for: entry)
        }
        .onDisappear {
            scrubPreviewSeconds = nil
            playback.tearDown()
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

    // MARK: - Playback

    private var playbackForThisSession: Bool { playback.displayedSessionID == sessionID }

    private var playbackBar: some View {
        HStack(spacing: 12) {
            Button {
                playback.togglePlayPause()
            } label: {
                // Both labels are laid out so the button keeps the wider
                // one's width and toggling never shifts the bar.
                ZStack {
                    Label("Play", systemImage: "play.fill")
                        .opacity(playback.isPlaying ? 0 : 1)
                        .accessibilityHidden(playback.isPlaying)
                    Label("Pause", systemImage: "pause.fill")
                        .opacity(playback.isPlaying ? 1 : 0)
                        .accessibilityHidden(!playback.isPlaying)
                }
            }
            .disabled(!playbackForThisSession || !playback.canPlayOrPause)

            // Stops playback and returns to the beginning (`stop()` resets
            // the controller to frame 0, ready).
            Button {
                playback.stop()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .disabled(!playbackForThisSession || !playback.canStop)
            .help("Stop playback and return to the beginning")

            playbackSlider

            Text(playbackTimeLabel)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)

            playbackStatusText
        }
        .buttonStyle(.bordered)
    }

    /// The slider's range end, or `nil` when there is nothing seekable.
    private var sliderDuration: Double? {
        guard playbackForThisSession, playback.canSeek,
              let duration = playback.durationSeconds, duration.isFinite, duration > 0 else {
            return nil
        }
        return duration
    }

    /// Follows the presenter's position except while dragging, when it shows
    /// the local preview so position samples never move the thumb. Releasing
    /// issues exactly one seek; a value change outside a drag (keyboard or
    /// accessibility adjustment) seeks immediately. Seeking keeps the play
    /// state — unlike transcript timestamps, the slider never starts playback.
    private var playbackSlider: some View {
        let duration = sliderDuration
        let upperBound = duration ?? 1
        let position = Binding<Double>(
            get: {
                let seconds = scrubPreviewSeconds ?? playback.currentSessionTime
                guard duration != nil, seconds.isFinite else { return 0 }
                return min(max(seconds, 0), upperBound)
            },
            set: { newValue in
                guard duration != nil, newValue.isFinite else { return }
                if scrubPreviewSeconds != nil {
                    scrubPreviewSeconds = newValue
                } else {
                    playback.seek(toSessionTime: newValue)
                }
            }
        )
        return Slider(value: position, in: 0...upperBound) { isEditing in
            if isEditing {
                scrubPreviewSeconds = playback.currentSessionTime
            } else if let target = scrubPreviewSeconds {
                scrubPreviewSeconds = nil
                playback.seek(toSessionTime: target)
            }
        }
        .controlSize(.small)
        .frame(minWidth: 160, maxWidth: .infinity)
        .disabled(duration == nil)
        .onChange(of: duration == nil) { _, isDisabled in
            // A drag cut short by the slider disabling (e.g. playback
            // failure) must not leave a stale preview behind.
            if isDisabled { scrubPreviewSeconds = nil }
        }
    }

    private var playbackTimeLabel: String {
        guard playbackForThisSession, let duration = playback.durationSeconds else { return "–:– / –:–" }
        let elapsed = scrubPreviewSeconds ?? playback.currentSessionTime
        return PlaybackTimeFormatting.progressLabel(elapsedSeconds: elapsed, totalSeconds: duration)
    }

    @ViewBuilder private var playbackStatusText: some View {
        if playbackForThisSession {
            switch playback.status {
            case .idle, .available(.ready), .available(.playing), .available(.paused), .available(.ended):
                EmptyView()
            case .preparing:
                ProgressView().controlSize(.small)
            case .unavailable(let message):
                Label("Playback unavailable: \(message)", systemImage: "speaker.slash")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            case .available(.failed(let failure)):
                Label("Playback failed: \(failure.localizedDescription)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Transcript

    /// Navigation for this session's saved transcript — never while this
    /// session's own operation is live (its segments are shown instead).
    private var displayedNavigation: TranscriptPlaybackNavigation? {
        guard !isActiveOperation, presenter.displayedSessionID == sessionID,
              let navigation = presenter.navigation, navigation.sessionID == sessionID else {
            return nil
        }
        return navigation
    }

    @ViewBuilder private var transcriptSection: some View {
        let segments = isActiveOperation ? service.displayedSegments : (presenter.displayedSessionID == sessionID ? presenter.segments : [])
        if let navigation = displayedNavigation {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(navigation.items) { item in
                        navigationRow(item, in: navigation)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if !segments.isEmpty {
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

    /// The timestamp button is the only navigation affordance; the passage
    /// text stays selectable.
    private func navigationRow(_ item: TranscriptPlaybackItem, in navigation: TranscriptPlaybackNavigation) -> some View {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEnabled = playbackForThisSession && playback.canPlayOrPause
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(PlaybackTimeFormatting.label(forSeconds: navigation.startTime(of: item))) {
                playback.navigate(to: item, in: navigation)
            }
            .buttonStyle(.link)
            .font(.caption.monospacedDigit())
            .disabled(!isEnabled)
            .pointerStyle(isEnabled ? .link : nil)
            .help(item.target == .chunkStart ? "Play from the start of this chunk" : "Play from this passage")

            Text(text.isEmpty ? "(silence)" : text)
                .textSelection(.enabled)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
