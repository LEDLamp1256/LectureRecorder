import XCTest
@testable import LectureRecorder

/// Pure speaker-presentation rules: display names, turn headers,
/// availability, status, and user-facing copy.
@MainActor
final class SessionSpeakerPresentationTests: XCTestCase {
    private typealias F = SpeakerPresentationFixture
    private typealias Calc = SpeakerIdentificationAvailabilityCalculator

    private func speaker(_ index: Int) -> SpeakerID {
        try! SpeakerID(index: index)
    }

    // MARK: - Names

    func testMachineIDsMapToOneBasedDisplayNames() throws {
        XCTAssertEqual(SpeakerDisplayName.name(for: try SpeakerID("speaker_0")), "Speaker 1")
        XCTAssertEqual(SpeakerDisplayName.name(for: try SpeakerID("speaker_1")), "Speaker 2")
        XCTAssertEqual(SpeakerDisplayName.name(for: try SpeakerID("speaker_9")), "Speaker 10")
        XCTAssertEqual(SpeakerRowHeader.speaker(speaker(2)).title, "Speaker 3")
        XCTAssertEqual(SpeakerRowHeader.notIdentified.title, "Speaker not identified")
    }

    func testAccessibilityNamesASpeakerOnlyForASpeakerAttribution() {
        XCTAssertEqual(SpeakerDisplayName.accessibilityDescription(for: .speaker(speaker(0))), "Speaker 1")
        let ambiguous = SpeakerDisplayName.accessibilityDescription(for: .ambiguous([speaker(0), speaker(1)]))
        XCTAssertTrue(ambiguous.hasPrefix("Speaker not identified"))
        XCTAssertFalse(ambiguous.contains("Speaker 1") || ambiguous.contains("Speaker 2"), "ambiguous candidates are never listed")
        XCTAssertEqual(SpeakerDisplayName.accessibilityDescription(for: .unknown), "Speaker not identified")
        XCTAssertTrue(SpeakerDisplayName.accessibilityDescription(for: .ineligible).hasPrefix("Speaker not identified"))
    }

    // MARK: - Turn headers

    private func items(_ count: Int) -> [TranscriptPlaybackItem] {
        (0..<count).map { F.item(0, .timedSegment(index: $0), Int64($0) * 100, Int64($0 + 1) * 100) }
    }

    private func decoration(_ attributions: [SpeakerAttribution]) -> (TranscriptSpeakerDecoration, [TranscriptPlaybackItem]) {
        let items = items(attributions.count)
        let navigation = F.navigation(sessionID: UUID(), items: items)
        let alignments = zip(items, attributions).map { SpeakerItemAlignment(itemID: $0.id, attribution: $1, overlaps: []) }
        return (TranscriptSpeakerDecoration.build(navigation: navigation, alignments: alignments), items)
    }

    private func headers(_ attributions: [SpeakerAttribution]) -> [SpeakerRowHeader?] {
        let (decoration, items) = decoration(attributions)
        return items.map { decoration.headerByItemID[$0.id] }
    }

    func testConsecutiveRowsOfOneSpeakerShareOneHeaderAndAChangeOpensANewOne() {
        XCTAssertEqual(
            headers([.speaker(speaker(0)), .speaker(speaker(0)), .speaker(speaker(1)), .speaker(speaker(0))]),
            [.speaker(speaker(0)), nil, .speaker(speaker(1)), .speaker(speaker(0))]
        )
    }

    func testEveryUncertainAttributionBreaksTheSpeakerGroup() {
        for uncertain in [SpeakerAttribution.ambiguous([speaker(0), speaker(1)]), .unknown, .ineligible] {
            XCTAssertEqual(
                headers([.speaker(speaker(0)), uncertain, uncertain, .speaker(speaker(0))]),
                [.speaker(speaker(0)), .notIdentified, nil, .speaker(speaker(0))],
                "\(uncertain) rows are never shown under the previous speaker"
            )
        }
    }

    func testMixedUncertainRowsFormOneNotIdentifiedGroup() {
        XCTAssertEqual(
            headers([.speaker(speaker(1)), .unknown, .ambiguous([speaker(0), speaker(1)]), .ineligible, .speaker(speaker(1))]),
            [.speaker(speaker(1)), .notIdentified, nil, nil, .speaker(speaker(1))]
        )
    }

    func testUncertainRowsBeforeTheFirstSpeakerGetNoHeader() {
        XCTAssertEqual(
            headers([.unknown, .ineligible, .speaker(speaker(0)), .unknown]),
            [nil, nil, .speaker(speaker(0)), .notIdentified]
        )
        XCTAssertEqual(headers([.unknown, .unknown]), [nil, nil])
    }

    func testDomainDistinctionsArePreservedInTheAttributionMap() {
        let attributions: [SpeakerAttribution] = [.speaker(speaker(0)), .ambiguous([speaker(0), speaker(1)]), .unknown, .ineligible]
        let (decoration, items) = decoration(attributions)
        XCTAssertEqual(items.map { decoration.attributionByItemID[$0.id] }, attributions)
    }

    func testAlignmentsForItemsOutsideTheNavigationAreIgnored() {
        let items = items(2)
        let navigation = F.navigation(sessionID: UUID(), items: items)
        let stray = F.item(9, .chunkStart, 0, 1)
        let decoration = TranscriptSpeakerDecoration.build(navigation: navigation, alignments: [
            SpeakerItemAlignment(itemID: stray.id, attribution: .speaker(speaker(0)), overlaps: []),
            SpeakerItemAlignment(itemID: items[1].id, attribution: .speaker(speaker(0)), overlaps: []),
        ])
        XCTAssertEqual(Set(decoration.attributionByItemID.keys), [items[1].id])
        XCTAssertEqual(decoration.headerByItemID, [items[1].id: .speaker(speaker(0))])
    }

    // MARK: - Durable display mapping

    func testUnsafeStorageIsNotRerunnableButOtherUnavailableSidecarsAre() {
        XCTAssertEqual(SpeakerDurableDisplay(.unavailable(.unsafePath)), .storageUnavailable)
        XCTAssertEqual(SpeakerDurableDisplay(.unavailable(.audioSourceMismatch)), .outOfDate)
        XCTAssertEqual(SpeakerDurableDisplay(.unavailable(.corrupt)), .unreadable(.sidecar(.corrupt)))
        XCTAssertEqual(SpeakerDurableDisplay(.absent), .absent)
        XCTAssertEqual(SpeakerDurableDisplay(.sourceUnavailable(.manifestUnreadable)), .sourceUnavailable(.manifestUnreadable))

        XCTAssertFalse(Calc.availability(display: .storageUnavailable, ownership: .none, phase: .idle).canIdentify)
        XCTAssertTrue(Calc.availability(display: .outOfDate, ownership: .none, phase: .idle).canIdentify)
        XCTAssertTrue(Calc.availability(display: .unreadable(.sidecar(.corrupt)), ownership: .none, phase: .idle).canIdentify)
    }

    // MARK: - Availability

    func testActionWordingFollowsDurableState() {
        let cases: [(SpeakerDurableDisplay, String, Bool)] = [
            (.loading, "Identify Speakers", false),
            (.absent, "Identify Speakers", true),
            (.available(speakerCount: 2), "Identify Speakers Again", true),
            (.outOfDate, "Identify Speakers", true),
            (.unreadable(.sidecar(.unsupportedSchemaVersion(2))), "Identify Speakers", true),
            (.unreadable(.alignment(.sampleRateMismatch)), "Identify Speakers", true),
            (.sourceUnavailable(.notTerminal(.recording)), "Identify Speakers", false),
            (.storageUnavailable, "Identify Speakers", false),
        ]
        for (display, title, canIdentify) in cases {
            let availability = Calc.availability(display: display, ownership: .none, phase: .idle)
            XCTAssertEqual(availability.actionTitle, title, "\(display)")
            XCTAssertEqual(availability.canIdentify, canIdentify, "\(display)")
            XCTAssertFalse(availability.showsCancel, "\(display)")
            XCTAssertFalse(availability.canCancel, "\(display)")
        }
    }

    func testAnyActiveOperationDisablesIdentifyAndOnlyTheOwningSessionShowsCancel() {
        let displays: [SpeakerDurableDisplay] = [.absent, .available(speakerCount: 1), .outOfDate]
        let phases: [SessionDiarizationService.OperationPhase] = [.preparingSource, .diarizing, .validating, .saving, .cancelling, .finished(.cancelled)]
        for display in displays {
            for phase in phases {
                let elsewhere = Calc.availability(display: display, ownership: .busyElsewhere, phase: phase)
                XCTAssertFalse(elsewhere.canIdentify)
                XCTAssertFalse(elsewhere.showsCancel)
                XCTAssertFalse(elsewhere.canCancel)

                let here = Calc.availability(display: display, ownership: .activeHere, phase: phase)
                XCTAssertFalse(here.canIdentify)
                XCTAssertTrue(here.showsCancel)
            }
        }
    }

    func testCancelIsEnabledOnlyBeforeCommitAuthorization() {
        let expectations: [(SessionDiarizationService.OperationPhase, Bool)] = [
            (.idle, false),
            (.preparingSource, true),
            (.diarizing, true),
            (.validating, true),
            (.saving, false),
            (.cancelling, false),
            (.finished(.staleSource), false),
            (.finished(.cancelled), false),
        ]
        for (phase, canCancel) in expectations {
            let availability = Calc.availability(display: .available(speakerCount: 2), ownership: .activeHere, phase: phase)
            XCTAssertEqual(availability.canCancel, canCancel, "\(phase)")
            XCTAssertTrue(availability.showsCancel, "Cancel stays present (disabled) through \(phase)")
            XCTAssertEqual(availability.actionTitle, "Identify Speakers Again", "existing labels stay the current state")
        }
    }

    // MARK: - Status

    func testLivePhaseTextIsHonestAndIndeterminate() {
        let expectations: [(SessionDiarizationService.OperationPhase, String?)] = [
            (.preparingSource, "Preparing audio…"),
            (.diarizing, "Identifying speakers…"),
            (.validating, "Checking results…"),
            (.saving, "Saving speaker labels…"),
            (.cancelling, "Cancelling…"),
            (.finished(.cancelled), nil),
            (.idle, nil),
        ]
        for (phase, text) in expectations {
            let status = Calc.status(display: .absent, ownership: .activeHere, phase: phase)
            XCTAssertEqual(status.text, text, "\(phase)")
            XCTAssertTrue(status.showsProgress, "\(phase)")
            XCTAssertFalse(status.text?.contains("%") ?? false)
        }
    }

    func testBusyElsewhereStatusIgnoresThisSessionsPhaseAndDurableState() {
        for display in [SpeakerDurableDisplay.absent, .available(speakerCount: 3), .outOfDate] {
            let status = Calc.status(display: display, ownership: .busyElsewhere, phase: .diarizing)
            XCTAssertEqual(status.text, "Speakers are being identified for another session.")
            XCTAssertFalse(status.showsProgress)
        }
    }

    func testIdleStatusDescribesDurableStateWithoutTechnicalDetail() {
        let expectations: [(SpeakerDurableDisplay, String?)] = [
            (.loading, nil),
            (.absent, nil),
            (.available(speakerCount: 1), "1 speaker identified"),
            (.available(speakerCount: 3), "3 speakers identified"),
            (.outOfDate, "Saved speaker labels are out of date."),
            (.unreadable(.sidecar(.corrupt)), "Saved speaker labels can't be read."),
            (.unreadable(.alignment(.sessionMismatch)), "Saved speaker labels can't be read."),
            (.sourceUnavailable(.audioUnavailable(.invalidChannelCount)), "Speaker identification isn't available for this session's audio."),
            (.storageUnavailable, "Speaker identification isn't available for this session."),
        ]
        for (display, text) in expectations {
            XCTAssertEqual(Calc.status(display: display, ownership: .none, phase: .idle).text, text, "\(display)")
        }
        XCTAssertTrue(Calc.status(display: .loading, ownership: .none, phase: .idle).showsProgress)
    }

    // MARK: - Messages

    func testOutcomeMessagesNeverExposeBackendDetail() {
        let detail = "Speaker-diarization model file Segmentation.mlmodelc is missing. Run Scripts/provision.sh at /Users/x"
        XCTAssertEqual(SpeakerIdentificationMessage.message(for: .failed(.backendFailed(description: detail))), "Speaker identification couldn't finish.")
        XCTAssertEqual(SpeakerIdentificationMessage.message(for: .failed(.saveFailed(description: detail))), "Speaker labels couldn't be saved.")
        XCTAssertEqual(SpeakerIdentificationMessage.message(for: .failed(.invalidBackendOutput)), "Speaker identification produced an unusable result.")
        XCTAssertEqual(SpeakerIdentificationMessage.message(for: .cancelled), "Speaker identification cancelled.")
        XCTAssertEqual(SpeakerIdentificationMessage.message(for: .staleSource), "The recording changed while speakers were being identified. Try again.")
        XCTAssertEqual(SpeakerIdentificationMessage.message(for: .sourceUnavailable(.manifestUnreadable)), "This session's audio couldn't be read.")
        XCTAssertNil(SpeakerIdentificationMessage.message(for: nil))
    }
}
