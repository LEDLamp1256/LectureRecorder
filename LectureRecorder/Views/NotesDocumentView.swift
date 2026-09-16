import SwiftUI

/// Read-only, structured renderer for one `LectureNotesDocument` — never a
/// Markdown/plain-text blob (see the model's own contract). Each
/// `LectureNoteItem` is passed through unmodified, including its
/// `sourceReferences`: this view performs no flattening transformation, so
/// a future Note -> transcript-location feature has the same source
/// references available here that `LectureNotesGenerationService` already
/// validated when the item was committed.
struct NotesDocumentView: View {
    let document: LectureNotesDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            overviewSection
            ForEach(document.sections, id: \.id) { section in
                sectionView(section)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(section.heading)
                .font(.title3.bold())
            ForEach(section.items, id: \.id) { item in
                NotesItemView(item: item)
            }
        }
    }
}

/// One structured note item, preserving `sourceReferences` in memory (never
/// rendered as visible text here — see the type's own header comment) so a
/// future Note -> transcript jump/highlight feature can be added without
/// this view needing to change what it holds onto.
private struct NotesItemView: View {
    let item: LectureNoteItem

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
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
