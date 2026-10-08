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
/// Playback is independent of transcription and of this pane's lifetime:
/// the `SessionPlaybackPresenter` is owned, prepared, and torn down by the
/// parent `CompletedSessionDetailView`, so playback continues while this
/// pane is unmounted. This view only shows its state and issues the same
/// play/pause/reset/seek/timestamp commands through it. A completed
/// transcript with loaded navigation shows each passage with a timestamp
/// button that plays from that passage.
///
/// A Notes Source reveal arrives through the parent-owned
/// `SessionTranscriptRevealPresenter`. Once this session's transcript is
/// loaded and the target passes its application-time revalidation, the
/// transcript scrolls to the first row of the referenced chunks and
/// highlights every row of those chunks — whole-chunk evidence, never one
/// segment. Navigation rows are preferred; without navigation, the plain
/// per-chunk rows are used, and only completed ones count. A newer Source
/// request clears the previous reveal's highlight and message as soon as it
/// starts resolving. Revealing never touches playback: only timestamp
/// buttons seek.
///
/// Speaker labels are optional decoration from the shared
/// `SessionDiarizationService`: a pane-local `SessionSpeakerPresenter`
/// rebuilds them from the durable sidecar and re-reads it whenever a new
/// operation for this session is released. Labels never change transcript
/// rows, their IDs, or playback, and missing or unusable speaker data only
/// leaves rows undecorated.
struct SessionTranscriptView: View {
    /// Re-runs reveal application when a new target arrives or this
    /// session's displayed transcript changes kind (e.g. finishes loading).
    private struct RevealTrigger: Equatable {
        enum TranscriptKind: Equatable {
            case loading, navigation, plain
        }

        let target: TranscriptRevealTarget?
        let transcriptKind: TranscriptKind
    }

    let entry: CompletedSessionEntry
    @ObservedObject var service: CompletedSessionTranscriptionService
    @StateObject private var presenter: SessionTranscriptPresenter
    /// Parent-owned; this view never prepares or tears it down.
    @ObservedObject var playback: SessionPlaybackPresenter
    /// While the time slider is being dragged, the position it previews.
    /// UI-only: the presenter's position stays authoritative, and one seek
    /// is issued when the drag ends.
    @State private var scrubPreviewSeconds: Double?
    @ObservedObject var revealPresenter: SessionTranscriptRevealPresenter
    /// Rows of the last applied reveal; kept until another reveal replaces
    /// it, the session or navigation changes, or this view unmounts.
    @State private var revealedItemIDs: Set<TranscriptPlaybackItem.ID> = []
    @State private var revealScrollTargetID: TranscriptPlaybackItem.ID?
    /// The same, for a reveal applied to the plain rows (no navigation).
    @State private var revealedSequenceNumbers: Set<Int> = []
    @State private var revealScrollTargetSequenceNumber: Int?
    /// Bumped once per applied reveal so the same row can be scrolled to
    /// again by a later activation.
    @State private var revealScrollRequest = 0
    @State private var revealMessage: String?
    /// The single, shared diarization owner: observed for live phase and
    /// ownership, and called only for the explicit Identify Speakers and
    /// Cancel actions. This view never cancels on disappearance.
    @ObservedObject var diarizationService: SessionDiarizationService
    @StateObject private var speakerPresenter: SessionSpeakerPresenter

    init(
        entry: CompletedSessionEntry,
        service: CompletedSessionTranscriptionService,
        navigationLoader: any CompletedTranscriptNavigationLoading,
        revealPresenter: SessionTranscriptRevealPresenter,
        playback: SessionPlaybackPresenter,
        diarizationService: SessionDiarizationService
    ) {
        self.entry = entry
        self.service = service
        self.revealPresenter = revealPresenter
        self.playback = playback
        self.diarizationService = diarizationService
        _presenter = StateObject(wrappedValue: SessionTranscriptPresenter(loader: service, navigationLoader: navigationLoader))
        _speakerPresenter = StateObject(wrappedValue: SessionSpeakerPresenter(
            peeker: diarizationService,
            initialRelease: diarizationService.lastReleasedOperation
        ))
    }

    private var sessionID: UUID { entry.manifest.sessionID }

    private var ownership: SessionOwnershipDisplay {
        SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: service.activeSessionID, sessionID: sessionID)
    }

    private var isActiveOperation: Bool { ownership == .activeHere }

    private var peekedStatus: SessionTranscriptionStatus? {
        presenter.displayedSessionID == sessionID ? presenter.status : nil
    }

    private var peekedFailureOverview: TranscriptionFailureOverview? {
        presenter.displayedSessionID == sessionID ? presenter.failureOverview : nil
    }

    private var availability: SessionActionAvailability {
        SessionActionAvailabilityCalculator.availability(
            peekedStatus: peekedStatus,
            failureOverview: peekedFailureOverview,
            ownership: ownership
        )
    }

    /// Transient explanation of the most recent refused Transcribe/Continue
    /// tap in this view. Holds only the service's own `AdmissionResult`
    /// label; cleared by the next admitted action.
    @State private var admissionMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            metadataSection
            statusSection
            actionButtons
            Divider()
            playbackBar
            speakerSection
            transcriptSection
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: sessionID) {
            clearReveal()
            await presenter.refresh(for: entry)
        }
        .task(id: sessionID) {
            // Catches a release published before the `onChange` below was
            // observing, without resurrecting one that predates this pane.
            await speakerPresenter.reconcileOnAppear(for: entry, currentRelease: diarizationService.lastReleasedOperation)
        }
        .onChange(of: displayedNavigation, initial: true) {
            // Recomputes speaker decoration only when the displayed
            // navigation itself changes — never per playback poll.
            speakerPresenter.update(navigation: displayedNavigation)
        }
        .onChange(of: diarizationService.lastReleasedOperation) { _, release in
            // A release is only a cue: durable state is re-read from disk.
            guard speakerPresenter.observeRelease(release, sessionID: sessionID) else { return }
            Task { await speakerPresenter.refresh(for: entry) }
        }
        .task(id: RevealTrigger(target: revealPresenter.pendingTarget, transcriptKind: revealTranscriptKind)) {
            await applyPendingReveal()
        }
        .onChange(of: presenter.navigation) {
            // Highlighted IDs belong to the navigation they were mapped in.
            clearReveal()
        }
        .onChange(of: presenter.segments) {
            // Likewise for the plain rows' sequence numbers.
            clearReveal()
        }
        .onChange(of: revealPresenter.state) { _, newState in
            // A newer Source request supersedes the previous reveal's
            // evidence and message; it will apply its own or fail itself.
            if newState == .resolving { clearReveal() }
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
            if let recordingStatus = SessionRecordingStatusDisplay.detailStatus(for: entry.manifest) {
                Label(recordingStatus, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
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
                VStack(alignment: .leading, spacing: 4) {
                    savedStatusText(peekedStatus)
                    if let peekedFailureOverview {
                        ForEach(TranscriptionFailedPartMessage.lines(for: peekedFailureOverview), id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let explanation = SessionActionAvailabilityCalculator.continueUnavailableExplanation(
                        peekedStatus: peekedStatus,
                        failureOverview: peekedFailureOverview,
                        ownership: ownership
                    ) {
                        Text(explanation)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
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
        case .blocked:
            // The raw reasons are internal diagnostics; they are never the
            // user-facing text.
            Label(TranscriptionStatusMessage.blocked, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button("Transcribe") {
                    handle(service.transcribe(sessionID: sessionID))
                }
                .disabled(!availability.canTranscribe)

                Button(continueOrRetryLabel) {
                    handle(service.continueOrRetry(sessionID: sessionID))
                }
                .disabled(!availability.canContinueOrRetry)

                Button("Cancel", role: .destructive) {
                    service.cancel(sessionID: sessionID)
                }
                .disabled(!availability.canCancel)

                if availability.canRetryFailedParts {
                    Button("Try Failed Parts Again") {
                        handle(service.retryPermanentlyFailedParts(sessionID: sessionID))
                    }
                    .help("Retry parts that couldn't be transcribed. They may fail again.")
                }
            }
            .buttonStyle(.bordered)

            if let admissionMessage {
                Text(admissionMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Labels the service's own authoritative admission result; never
    /// decides admission itself.
    private func handle(_ result: CompletedSessionTranscriptionService.AdmissionResult) {
        admissionMessage = TranscriptionAdmissionMessage.message(for: result)
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

    // MARK: - Speakers

    private var speakerOwnership: SessionOwnershipDisplay {
        SessionActionAvailabilityCalculator.ownershipDisplay(activeSessionID: diarizationService.activeSessionID, sessionID: sessionID)
    }

    private var speakerDisplay: SpeakerDurableDisplay {
        speakerPresenter.displayedSessionID == sessionID ? speakerPresenter.display : .loading
    }

    /// Explicit Identify Speakers / Cancel controls and status. Rendered
    /// state follows `diarizationService.phase` and ownership alone; there
    /// is no local, optimistic cancellation state.
    private var speakerSection: some View {
        let ownership = speakerOwnership
        let phase = diarizationService.phase
        let availability = SpeakerIdentificationAvailabilityCalculator.availability(display: speakerDisplay, ownership: ownership, phase: phase)
        let status = SpeakerIdentificationAvailabilityCalculator.status(display: speakerDisplay, ownership: ownership, phase: phase)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(availability.actionTitle) {
                    speakerPresenter.recordAdmission(diarizationService.diarize(sessionID: sessionID))
                }
                .disabled(!availability.canIdentify)

                if availability.showsCancel {
                    Button("Cancel", role: .destructive) {
                        diarizationService.cancel(sessionID: sessionID)
                    }
                    .disabled(!availability.canCancel)
                    .help(phase == .saving ? "Saving can't be cancelled." : "Cancel speaker identification")
                    .accessibilityLabel("Cancel speaker identification")
                }

                if status.showsProgress {
                    ProgressView().controlSize(.small)
                }
                if let text = status.text {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(status.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
            .buttonStyle(.bordered)

            if let message = speakerPresenter.admissionMessage ?? (ownership == .activeHere ? nil : speakerPresenter.releaseMessage) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
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

    // MARK: - Note source reveal

    /// Exactly what `transcriptSection` renders for this session's saved
    /// transcript. `.loading` until this session's load has published (all
    /// of status, segments, and navigation at once) or while its own
    /// operation is live, so a target waits instead of failing.
    private var revealTranscript: TranscriptRevealDisplayedTranscript {
        guard !isActiveOperation, presenter.displayedSessionID == sessionID else { return .loading }
        if let navigation = displayedNavigation { return .navigation(navigation) }
        return .plain(sessionID: sessionID, segments: presenter.segments)
    }

    private var revealTranscriptKind: RevealTrigger.TranscriptKind {
        switch revealTranscript {
        case .loading: .loading
        case .navigation: .navigation
        case .plain: .plain
        }
    }

    private func clearReveal() {
        revealedItemIDs = []
        revealScrollTargetID = nil
        revealedSequenceNumbers = []
        revealScrollTargetSequenceNumber = nil
        revealMessage = nil
    }

    /// Applies the pending reveal once it is for this session and its
    /// transcript is loaded. Never partially applies: a target the loaded
    /// transcript cannot fully represent is rejected, which also stops it
    /// being retried.
    private func applyPendingReveal() async {
        guard let target = revealPresenter.pendingTarget,
              TranscriptRevealApplicationPlanner.outcome(for: target, sessionID: sessionID, transcript: revealTranscript) != .notApplicable else {
            return
        }
        guard let application = await revealPresenter.revalidateReadyTarget(for: entry) else {
            if !Task.isCancelled, revealPresenter.sessionID == sessionID, case .failed(let failure) = revealPresenter.state {
                revealMessage = TranscriptRevealFailureMessage.message(for: failure)
            }
            return
        }
        // A superseded run leaves the still-ready target to the newer run.
        guard !Task.isCancelled else { return }
        switch TranscriptRevealApplicationPlanner.outcome(for: application.target, sessionID: sessionID, transcript: revealTranscript) {
        case .notApplicable:
            return
        case .locationUnavailable:
            revealPresenter.reject(application, with: .locationUnavailable)
            revealMessage = TranscriptRevealFailureMessage.message(for: .locationUnavailable)
        case .apply(let selection):
            clearReveal()
            revealedItemIDs = Set(selection.selectedItemIDs)
            revealScrollTargetID = selection.scrollTargetID
            revealScrollRequest += 1
            revealPresenter.consume(application)
        case .applyFallback(let selection):
            clearReveal()
            revealedSequenceNumbers = Set(selection.selectedSequenceNumbers)
            revealScrollTargetSequenceNumber = selection.scrollTargetSequenceNumber
            revealScrollRequest += 1
            revealPresenter.consume(application)
        }
    }

    @ViewBuilder private var transcriptSection: some View {
        let segments = isActiveOperation ? service.displayedSegments : (presenter.displayedSessionID == sessionID ? presenter.segments : [])
        if let revealMessage {
            Label(revealMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let navigation = displayedNavigation {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(navigation.items) { item in
                            navigationRow(item, in: navigation)
                                .id(item.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: revealScrollRequest) {
                    guard let revealScrollTargetID else { return }
                    withAnimation {
                        proxy.scrollTo(revealScrollTargetID, anchor: .top)
                    }
                }
            }
        } else if !segments.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(segments, id: \.sequenceNumber) { segment in
                            segmentView(segment)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .revealHighlight(revealedSequenceNumbers.contains(segment.sequenceNumber))
                                .id(segment.sequenceNumber)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: revealScrollRequest) {
                    guard let revealScrollTargetSequenceNumber else { return }
                    withAnimation {
                        proxy.scrollTo(revealScrollTargetSequenceNumber, anchor: .top)
                    }
                }
            }
        }
    }

    /// The timestamp button is the only navigation affordance; the passage
    /// text stays selectable. Speaker decoration only adds an optional
    /// group header above the unchanged passage row, looked up by the
    /// item's existing ID.
    private func navigationRow(_ item: TranscriptPlaybackItem, in navigation: TranscriptPlaybackNavigation) -> some View {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEnabled = playbackForThisSession && playback.canPlayOrPause
        let isRevealed = revealedItemIDs.contains(item.id)
        let decoration = speakerPresenter.displayedSessionID == sessionID ? speakerPresenter.decoration : nil
        let speakerHeader = decoration?.headerByItemID[item.id]
        let speakerDescription = decoration?.attributionByItemID[item.id].map { SpeakerDisplayName.accessibilityDescription(for: $0) }
        return VStack(alignment: .leading, spacing: 2) {
            if let speakerHeader {
                Text(speakerHeader.title)
                    .font(speakerHeader == .notIdentified ? .caption : .caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                    .accessibilityValue(speakerDescription ?? "")
            }
            .revealHighlight(isRevealed)
        }
    }

    @ViewBuilder private func segmentView(_ segment: OrderedSegment) -> some View {
        switch segment.state {
        case .completed(let text):
            Text(text.isEmpty ? "(silence)" : text)
                .textSelection(.enabled)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
        case .failed(let failure):
            Text(TranscriptionFailedPartMessage.message(
                sequenceNumber: segment.sequenceNumber,
                category: failure.category,
                retryDisposition: failure.retryDisposition
            ))
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

private extension View {
    /// Marks a row of a revealed Note source. Drawn outside the row's bounds
    /// so revealing never shifts layout; every row of a revealed chunk gets
    /// the same treatment, in both the navigation and plain transcripts.
    func revealHighlight(_ isRevealed: Bool) -> some View {
        background {
            if isRevealed {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                    .padding(-4)
            }
        }
        .accessibilityAddTraits(isRevealed ? .isSelected : [])
    }
}
