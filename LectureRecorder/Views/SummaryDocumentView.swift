import SwiftUI

/// Read-only, structured renderer for one `LectureSummaryDocument` — never a
/// Markdown/plain-text blob, mirroring `NotesDocumentView`'s own contract.
/// `LectureSummaryDocument` has no Notes-style `overview` field; this view
/// does not invent one. Each `LectureSummaryPassage` is passed through
/// unmodified, including its `supportingNoteItemIDs`/`sourceReferences`:
/// this view performs no flattening transformation. When
/// `onSupportingNotesActivated` is set, each passage with valid support
/// gets one Supporting Notes action that hands back this exact document and
/// passage; loading and validating the support is entirely the caller's
/// job. There is no direct transcript navigation from a Summary.
struct SummaryDocumentView: View {
    let document: LectureSummaryDocument
    var onSupportingNotesActivated: ((LectureSummaryDocument, LectureSummaryPassage) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(document.sections, id: \.id) { section in
                sectionView(section)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionView(_ section: LectureSummarySection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.heading)
                .font(.title3.bold())
            ForEach(section.passages, id: \.id) { passage in
                SummaryPassageView(
                    passage: passage,
                    notesActions: SummaryPassageNotesActions.actions(for: passage, in: document),
                    onSupportingNotesActivated: onSupportingNotesActivated.map { activate in
                        { activate(document, passage) }
                    }
                )
            }
        }
    }
}

/// One labeled Supporting Notes action for a Summary passage.
nonisolated struct SummaryPassageNotesAction: Equatable {
    let label: String
}

/// The Notes actions for a Summary passage: exactly one "Supporting Notes"
/// action when the passage yields a valid `SummaryNotesRevealTarget` with
/// nonempty, non-repeating support, and none otherwise. Never one action per
/// supporting Note: the whole set grounds the passage, so no single Note is
/// presented as independently supporting it.
nonisolated enum SummaryPassageNotesActions {
    static let label = "Supporting Notes"

    static func actions(for passage: LectureSummaryPassage, in document: LectureSummaryDocument) -> [SummaryPassageNotesAction] {
        guard let target = SummaryNotesRevealTarget(document: document, passage: passage),
              !target.supportingNoteItemIDs.isEmpty,
              Set(target.supportingNoteItemIDs).count == target.supportingNoteItemIDs.count else {
            return []
        }
        return [SummaryPassageNotesAction(label: label)]
    }
}

/// One structured Summary passage. `supportingNoteItemIDs`/
/// `sourceReferences` are never rendered as text — only as the single
/// Supporting Notes action, and only when an activation handler is set.
private struct SummaryPassageView: View {
    let passage: LectureSummaryPassage
    let notesActions: [SummaryPassageNotesAction]
    let onSupportingNotesActivated: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if passage.fidelity != .transcriptSupported {
                Text(fidelityLabel)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(fidelityColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(fidelityColor)
            }

            Text(passage.text)
                .textSelection(.enabled)

            if let uncertaintyNote = passage.uncertaintyNote {
                Text(uncertaintyNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            supportingNotesAction
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var supportingNotesAction: some View {
        if let onSupportingNotesActivated, let action = notesActions.first {
            Button(action.label) {
                onSupportingNotesActivated()
            }
            .buttonStyle(.link)
            .font(.caption)
            .pointerStyle(.link)
            .help("Show the Notes this passage was summarized from")
        }
    }

    private var fidelityLabel: String {
        switch passage.fidelity {
        case .transcriptSupported: return "Transcript-supported"
        case .reconstructed: return "Reconstructed"
        case .uncertain: return "Uncertain"
        }
    }

    private var fidelityColor: Color {
        switch passage.fidelity {
        case .transcriptSupported: return .secondary
        case .reconstructed: return .blue
        case .uncertain: return .orange
        }
    }
}
