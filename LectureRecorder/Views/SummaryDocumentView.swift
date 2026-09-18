import SwiftUI

/// Read-only, structured renderer for one `LectureSummaryDocument` — never a
/// Markdown/plain-text blob, mirroring `NotesDocumentView`'s own contract.
/// `LectureSummaryDocument` has no Notes-style `overview` field; this view
/// does not invent one. Each `LectureSummaryPassage` is passed through
/// unmodified, including its `supportingNoteItemIDs`/`sourceReferences`:
/// this view performs no flattening transformation and renders no
/// transcript/Notes-item navigation from them yet — that remains a later
/// stage's work, same as `NotesDocumentView`'s own deferred source
/// references.
struct SummaryDocumentView: View {
    let document: LectureSummaryDocument

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
                SummaryPassageView(passage: passage)
            }
        }
    }
}

/// One structured Summary passage, preserving `supportingNoteItemIDs`/
/// `sourceReferences` in memory (never rendered as visible text or
/// navigation here — see the type's own header comment) so a future
/// Summary -> Notes/transcript jump feature can be added without this view
/// needing to change what it holds onto.
private struct SummaryPassageView: View {
    let passage: LectureSummaryPassage

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
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
