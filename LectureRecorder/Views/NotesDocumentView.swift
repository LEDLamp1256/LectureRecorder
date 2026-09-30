import SwiftUI

/// Read-only, structured renderer for one `LectureNotesDocument` — never a
/// Markdown/plain-text blob (see the model's own contract). Each
/// `LectureNoteItem` is passed through unmodified, including its
/// `sourceReferences`: this view performs no flattening transformation.
/// When `onSourceActivated` is set, each stored reference becomes a Source
/// action that hands back that exact reference together with the document's
/// `transcriptFingerprint`; resolving it is entirely the caller's job.
struct NotesDocumentView: View {
    let document: LectureNotesDocument
    var onSourceActivated: ((NotesSourceReference, TranscriptSourceFingerprint) -> Void)?

    var body: some View {
        if NotesDocumentPresentation.hasNoStudyNotes(document) {
            // Every analysis window abstained: an intentional, valid result,
            // not an error — shown instead of an empty Overview.
            ContentUnavailableView(
                NotesDocumentPresentation.emptyTitle,
                systemImage: "doc.text.magnifyingglass",
                description: Text(NotesDocumentPresentation.emptyDescription)
            )
        } else {
            VStack(alignment: .leading, spacing: 24) {
                overviewSection
                ForEach(document.sections, id: \.id) { section in
                    sectionView(section)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Overview")
                .font(.headline)
            Text(document.overview)
                .textSelection(.enabled)
        }
    }

    private func sectionView(_ section: LectureNoteSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.heading)
                    .font(.title3.bold())
                // Descriptive metadata only — not interactive, and absent
                // (no placeholder or spacing) when a section has no topics.
                if let topics = NotesSectionTopicsFormatting.displayText(for: section.topics) {
                    Text(topics)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel(NotesSectionTopicsFormatting.accessibilityLabel(for: topics))
                }
            }
            ForEach(section.items, id: \.id) { item in
                NotesItemView(item: item, onSourceActivated: onSourceActivated.map { activate in
                    { reference in activate(reference, document.transcriptFingerprint) }
                })
            }
        }
    }
}

/// Whether a completed Notes document has any study notes to show. A
/// document whose every window abstained has no sections (or no items); it
/// is shown as an intentional empty state, never as an empty Overview.
nonisolated enum NotesDocumentPresentation {
    static let emptyTitle = "No Study Notes"
    static let emptyDescription = "This lecture's transcript didn't contain material that could be turned into reliable study notes."

    static func hasNoStudyNotes(_ document: LectureNotesDocument) -> Bool {
        document.sections.allSatisfy { $0.items.isEmpty }
    }
}

/// How a section's `topics` appear beneath its heading: every topic, in
/// order and unmodified, joined with `separator` so the list wraps as
/// ordinary text; nothing at all for a section without topics (legacy
/// documents and generators that do not produce them).
nonisolated enum NotesSectionTopicsFormatting {
    static let separator = " · "

    static func displayText(for topics: [String]) -> String? {
        topics.isEmpty ? nil : topics.joined(separator: separator)
    }

    static func accessibilityLabel(for displayText: String) -> String {
        "Topics: \(displayText)"
    }
}

/// One labeled Source action for a stored `NotesSourceReference`.
nonisolated struct NotesSourceAction: Equatable {
    let label: String
    let reference: NotesSourceReference
}

/// The Source actions for a note item, one per stored reference in stored
/// order: none for no references, "Source" for exactly one, and "Source 1",
/// "Source 2", … otherwise. Never reconstructs or previews source text.
nonisolated enum NotesSourceActions {
    static func actions(for references: [NotesSourceReference]) -> [NotesSourceAction] {
        guard references.count > 1 else {
            return references.map { NotesSourceAction(label: "Source", reference: $0) }
        }
        return references.enumerated().map { index, reference in
            NotesSourceAction(label: "Source \(index + 1)", reference: reference)
        }
    }
}

/// One structured note item. Its `sourceReferences` are never rendered as
/// text — only as Source actions, and only when `onSourceActivated` is set.
private struct NotesItemView: View {
    let item: LectureNoteItem
    let onSourceActivated: ((NotesSourceReference) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(kindLabel, systemImage: kindSystemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.fidelity != .transcriptSupported {
                    Text(fidelityLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(fidelityColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(fidelityColor)
                }
            }

            if let title = item.title {
                Text(title)
                    .font(.subheadline.bold())
            }

            bodyText

            if let uncertaintyNote = item.uncertaintyNote {
                Text(uncertaintyNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            sourceActions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var sourceActions: some View {
        let actions = NotesSourceActions.actions(for: item.sourceReferences)
        if let onSourceActivated, !actions.isEmpty {
            HStack(spacing: 10) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button(action.label) {
                        onSourceActivated(action.reference)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .pointerStyle(.link)
                    .help("Show the supporting transcript")
                }
            }
        }
    }

    @ViewBuilder private var bodyText: some View {
        switch item.kind {
        case .formula, .algorithmOrCode:
            // The stored body is already plain text (or a reconstructed
            // representation, see `fidelity`) — a monospaced treatment
            // improves readability without inventing syntax highlighting
            // or Markdown interpretation the model doesn't provide.
            Text(item.body)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        default:
            Text(item.body)
                .textSelection(.enabled)
        }
    }

    private var kindLabel: String {
        switch item.kind {
        case .keyConcept: return "Key Concept"
        case .definition: return "Definition"
        case .explanation: return "Explanation"
        case .example: return "Example"
        case .formula: return "Formula"
        case .algorithmOrCode: return "Algorithm / Code"
        case .warning: return "Warning"
        case .uncertainty: return "Uncertainty"
        case .other: return "Note"
        }
    }

    private var kindSystemImage: String {
        switch item.kind {
        case .keyConcept: return "lightbulb"
        case .definition: return "textformat.abc"
        case .explanation: return "text.alignleft"
        case .example: return "checkmark.seal"
        case .formula: return "function"
        case .algorithmOrCode: return "chevron.left.forwardslash.chevron.right"
        case .warning: return "exclamationmark.triangle"
        case .uncertainty: return "questionmark.circle"
        case .other: return "doc.text"
        }
    }

    private var fidelityLabel: String {
        switch item.fidelity {
        case .transcriptSupported: return "Transcript-supported"
        case .reconstructed: return "Reconstructed"
        case .uncertain: return "Uncertain"
        }
    }

    private var fidelityColor: Color {
        switch item.fidelity {
        case .transcriptSupported: return .secondary
        case .reconstructed: return .blue
        case .uncertain: return .orange
        }
    }
}

#if DEBUG
/// In-memory, synthetic preview fixture for manual visual checks of section
/// titles and topics — never read from disk or from a real session.
private enum NotesDocumentPreviewFixture {
    static let document: LectureNotesDocument = {
        let sessionID = UUID()
        func item(_ kind: LectureNoteItemKind, _ body: String, sequence: Int,
                  fidelity: LectureNoteContentFidelity = .transcriptSupported, uncertaintyNote: String? = nil) -> LectureNoteItem {
            LectureNoteItem(kind: kind, body: body, fidelity: fidelity,
                            sourceReferences: [NotesSourceReference(sessionID: sessionID, sequenceNumber: sequence)],
                            uncertaintyNote: uncertaintyNote)
        }
        return LectureNotesDocument(
            generationID: UUID(),
            sessionID: sessionID,
            transcriptFingerprint: TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "0", count: 64)),
            provenance: LectureNotesGenerationProvenance(recipeVersion: "preview"),
            overview: "A synthetic overview sentence for the first section. A second sentence covers the next topic. A third sentence closes the sample.",
            sections: [
                LectureNoteSection(
                    heading: "Sorting Algorithms",
                    items: [
                        item(.definition, "A stable sort keeps equal keys in their original relative order.", sequence: 0),
                        item(.example, "Merging two sorted halves of size n/2 takes linear time.", sequence: 1),
                    ],
                    topics: ["Stable sorting", "Merge sort", "Divide and conquer"]
                ),
                LectureNoteSection(
                    heading: "Amortized Analysis of Dynamic Arrays and Resizable Hash Tables",
                    items: [
                        item(.formula, "Total cost of n appends ≤ 3n", sequence: 2),
                        item(.explanation, "Doubling the capacity spreads the copying cost over many cheap appends.", sequence: 3,
                             fidelity: .reconstructed, uncertaintyNote: "Recovered 'doubling' from a garbled phrase in the transcript."),
                        item(.warning, "Shrinking at one quarter full, not one half, avoids thrashing.", sequence: 4),
                    ],
                    topics: [
                        "Aggregate method", "Accounting method with prepaid credits", "Potential function Φ",
                        "Dynamic array doubling", "Load factor thresholds", "Rehashing cost",
                        "Table shrinking and thrashing", "Amortized O(1) insertion",
                    ]
                ),
                LectureNoteSection(
                    heading: "Course Logistics",
                    items: [item(.other, "Problem sets are due at the start of each week's first lecture.", sequence: 5)]
                ),
            ]
        )
    }()
}

#Preview("Notes – title and topics") {
    ScrollView {
        NotesDocumentView(document: NotesDocumentPreviewFixture.document, onSourceActivated: { _, _ in })
            .padding()
    }
    .frame(width: 720, height: 800)
}

#Preview("Notes – no study notes") {
    NotesDocumentView(document: LectureNotesDocument(
        generationID: UUID(),
        sessionID: UUID(),
        transcriptFingerprint: TranscriptSourceFingerprint(algorithmVersion: 1, digestHex: String(repeating: "0", count: 64)),
        provenance: LectureNotesGenerationProvenance(recipeVersion: "preview"),
        overview: "",
        sections: []
    ))
    .frame(width: 720, height: 400)
}

#Preview("Notes – narrow") {
    ScrollView {
        NotesDocumentView(document: NotesDocumentPreviewFixture.document)
            .padding()
    }
    .frame(width: 360, height: 800)
}
#endif
