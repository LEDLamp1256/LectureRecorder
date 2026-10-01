import Foundation

/// The Note items one Summary passage was derived from, carrying the full
/// Summary source identity so it can only ever be applied to that exact
/// session, Notes generation, Notes document version, and transcript.
/// Derived from a `LectureSummaryDocument` and one of its passages; never
/// persisted.
nonisolated struct SummaryNotesRevealTarget: Equatable, Sendable {
    let sessionID: UUID
    let sourceNotesGenerationID: UUID
    let sourceNotesDocumentFingerprint: NotesDocumentFingerprint
    let transcriptFingerprint: TranscriptSourceFingerprint
    let supportingNoteItemIDs: [UUID]
}

extension SummaryNotesRevealTarget {
    /// `nil` when `passage` is not one of `document`'s passages, so a target
    /// can never pair one Summary's source identity with another's support.
    init?(document: LectureSummaryDocument, passage: LectureSummaryPassage) {
        let containsPassage = document.sections.contains { section in
            section.passages.contains { $0 == passage }
        }
        guard containsPassage else { return nil }
        self.init(
            sessionID: document.sessionID,
            sourceNotesGenerationID: document.sourceNotesGenerationID,
            sourceNotesDocumentFingerprint: document.sourceNotesDocumentFingerprint,
            transcriptFingerprint: document.transcriptFingerprint,
            supportingNoteItemIDs: passage.supportingNoteItemIDs
        )
    }
}

/// The Note items a `SummaryNotesRevealTarget` covers. Every selected item is
/// equally supporting evidence; the scroll target is only where to start.
nonisolated struct SummaryNotesRevealSelection: Equatable, Sendable {
    /// The first selected item, in Notes document order.
    let scrollTargetItemID: UUID
    /// Every supporting item, in Notes document order; never empty.
    let selectedItemIDs: [UUID]
}

/// Maps a `SummaryNotesRevealTarget` onto a `LectureNotesDocument`'s items by
/// Note item ID alone. Pure: never matches text, headings, or source
/// references, and never guesses.
///
/// Proves structural identity and membership only. The Notes document
/// fingerprint is not recomputed here; callers revalidate it through
/// `LectureSummarySourceLoading` before applying a selection.
nonisolated enum SummaryNotesRevealSelectionBuilder {
    /// Returns `nil` — never a partial selection — when the document's
    /// session, generation, or transcript differs from the target's, when
    /// the target's support is empty or repeats an ID, or when any
    /// supporting ID is missing from or repeated in the document.
    ///
    /// Work is bounded by the document's items.
    static func select(_ target: SummaryNotesRevealTarget, in document: LectureNotesDocument) -> SummaryNotesRevealSelection? {
        guard document.sessionID == target.sessionID,
              document.generationID == target.sourceNotesGenerationID,
              document.transcriptFingerprint == target.transcriptFingerprint else {
            return nil
        }
        let requestedIDs = Set(target.supportingNoteItemIDs)
        guard !requestedIDs.isEmpty, requestedIDs.count == target.supportingNoteItemIDs.count else { return nil }

        var selectedItemIDs: [UUID] = []
        var seenIDs: Set<UUID> = []
        for section in document.sections {
            for item in section.items where requestedIDs.contains(item.id) {
                guard seenIDs.insert(item.id).inserted else { return nil }
                selectedItemIDs.append(item.id)
            }
        }

        // Every seen ID is a requested ID, so support is fully covered
        // exactly when the counts match.
        guard seenIDs.count == requestedIDs.count, let scrollTargetItemID = selectedItemIDs.first else {
            return nil
        }
        return SummaryNotesRevealSelection(scrollTargetItemID: scrollTargetItemID, selectedItemIDs: selectedItemIDs)
    }
}
