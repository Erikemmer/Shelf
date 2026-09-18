import AppKit
import ShelfCore
import SlateKit
import SwiftUI

/// ⌘E: what Open Library and Google Books say about this book, and what — if
/// anything — should be taken from it.
///
/// Two steps, in the shape every other "first show, then do" in Shelf has: the
/// counting protocol before an import, the transfer sheet before a device, the
/// named list before a deletion.
///
/// 1. **the candidates**, best first, with the score and the line that says
///    what each one is, so a weak best match looks weak rather than looking
///    like the answer;
/// 2. **the comparison**, field by field, old beside new, a box per field.
///
/// Nothing is ticked that would *replace* something the book already says
/// (ADR 0015). Nothing is applied until Apply, and Apply goes through the same
/// undo-then-write path an inspector edit goes through.
struct FetchMetadataSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The **window's** undo manager, handed in by `ContentView`.
    ///
    /// Not `@Environment(\.undoManager)`: a sheet is its own presentation and
    /// SwiftUI gives it no undo manager at all, so the environment value here is
    /// `nil`. The symptom is silent and complete — Apply writes the file, the
    /// Edit menu reads a bare "Undo", and ⌘Z does nothing. Found by
    /// `Scripts/online-apply-proof.sh`, which reads the Edit menu's own title
    /// and the file on disk; nothing in the window said anything was wrong.
    let undoManager: UndoManager?

    private var online: OnlineMetadataModel? { model.onlineMetadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let online {
                if online.isSearching {
                    SlateStatusBar("Asking Open Library and Google Books")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if online.chosen == nil {
                    candidates(online)
                } else {
                    comparison(online)
                }
                if let note = online.note {
                    // Quiet. A network that is not there is a line here and in
                    // the status bar, never a dialogue (CONCEPT §9).
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Slate.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Network note")
                }
            }
            Divider()
            buttons
        }
        .padding(16)
        .frame(width: 640, height: 560)
        .background(Slate.panelBackground)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fetch Metadata")
                    .font(.headline)
                    .foregroundStyle(Slate.textPrimary)
                Spacer()
                if let label = online?.progressLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(Slate.textSecondary)
                        .monospacedDigit()
                }
            }
            if let book = online?.currentBook?.book {
                Text(book.title)
                    .font(.callout)
                    .foregroundStyle(Slate.accent)
                    .lineLimit(1)
            }
            if let query = online?.query {
                Text("Looking for \(query.description)")
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: Step one — the candidates

    private func candidates(_ online: OnlineMetadataModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let result = online.result, result.isEmpty {
                    Text("Nothing came back. The book keeps everything it has.")
                        .font(.callout)
                        .foregroundStyle(Slate.textSecondary)
                }
                ForEach(online.result?.ranked ?? [], id: \.candidate.id) { ranked in
                    candidateRow(ranked.candidate, score: ranked.score, in: online)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func candidateRow(
        _ candidate: MetadataCandidate, score: Int, in online: OnlineMetadataModel
    ) -> some View {
        Button {
            online.choose(candidate)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // The score in figures, because "best first" alone hides how
                // good the best is. 48 at the top of the list is a different
                // thing from 100 at the top of the list.
                Text("\(score)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(score >= 80 ? Slate.accent : Slate.textSecondary)
                    .frame(width: 28, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .font(.callout)
                        .foregroundStyle(Slate.textPrimary)
                        .lineLimit(2)
                    Text(candidate.subtitle)
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                        .lineLimit(2)
                    Text(candidate.source.name)
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary.opacity(0.8))
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Compare this one with the book, field by field")
        // "Candidate:" first, so the row is recognisable as one in the
        // accessibility tree — where the title alone is also the grid's
        // caption, the inspector's heading and, often, the window's subject.
        .accessibilityLabel("Candidate: \(candidate.title), \(candidate.source.name), match \(score) of 100")
    }

    // MARK: Step two — old beside new

    private func comparison(_ online: OnlineMetadataModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            cover(online)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if online.proposals.isEmpty {
                        Text("This candidate says nothing the book does not already say.")
                            .font(.callout)
                            .foregroundStyle(Slate.textSecondary)
                    }
                    ForEach(online.proposals) { proposal in
                        proposalRow(proposal, in: online)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func proposalRow(_ proposal: FieldProposal, in online: OnlineMetadataModel) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { online.ticked.contains(proposal.id) },
                    set: { _ in online.toggle(proposal) })
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            // A field the two already agree about has nothing to take over.
            .disabled(proposal.kind == .same)
            .accessibilityLabel("Take over \(proposal.label)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(proposal.label)
                        .font(.caption)
                        .foregroundStyle(Slate.textSecondary)
                    Text(Self.kindLabel(proposal.kind))
                        .font(.caption2)
                        .foregroundStyle(proposal.kind == .replace ? Slate.accent : Slate.textSecondary)
                }
                // Old above new, and the old one struck through only when it
                // would actually go: a replacement that is not ticked is not a
                // replacement.
                if !proposal.current.isEmpty {
                    Text(proposal.current)
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                        .strikethrough(online.ticked.contains(proposal.id) && proposal.kind == .replace)
                        .lineLimit(3)
                }
                Text(proposal.proposed)
                    .font(.callout)
                    .foregroundStyle(proposal.kind == .same ? Slate.textSecondary : Slate.textPrimary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .help(Self.help(for: proposal))
    }

    private static func kindLabel(_ kind: FieldProposal.Kind) -> String {
        switch kind {
        case .add: return "not set"
        case .replace: return "would replace"
        case .append: return "would add"
        case .same: return "already the same"
        }
    }

    private static func help(for proposal: FieldProposal) -> String {
        switch proposal.kind {
        case .add: return "\(proposal.label) is empty on this book — ticked because it fills a gap"
        case .replace:
            return "\(proposal.label) would be replaced. Not ticked for you: that is your library's answer"
        case .append:
            return "These would be added to the tags the book has. Nothing is taken off it — "
                + "and nothing is ticked for you: a catalogue's subjects are not your vocabulary"
        case .same: return "\(proposal.label) already says this"
        }
    }

    // MARK: The cover

    @ViewBuilder
    private func cover(_ online: OnlineMetadataModel) -> some View {
        VStack(spacing: 6) {
            if let image = online.coverPreview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 140)
                    .clipShape(RoundedRectangle(cornerRadius: Slate.cornerRadius))
                    .accessibilityLabel("Cover from \(online.chosen?.source.name ?? "the service")")
            } else {
                RoundedRectangle(cornerRadius: Slate.cornerRadius)
                    .fill(Slate.contentBackground)
                    .frame(width: 140, height: 210)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                            .foregroundStyle(Slate.textSecondary.opacity(0.35))
                    }
                    .accessibilityLabel("No cover from the service")
            }

            if online.wantsCover, online.chosen?.coverURL != nil {
                SlateSecondaryButton(online.isFetchingCover ? "Saving…" : "Use This Cover") {
                    Task { await model.fetchCoverFromTheNet() }
                }
                .disabled(online.isFetchingCover)
                // The one thing here that writes a file without Apply, so it
                // says exactly what it writes and where.
                .help("Writes cover.jpg next to the book. The book file is not touched")
            } else if !online.wantsCover {
                Text("This book already has a cover file.")
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                    .frame(width: 140)
            }
            if let note = online.coverNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                    .frame(width: 140)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            if online?.chosen != nil {
                SlateSecondaryButton("Other Candidates") { online?.backToCandidates() }
                    .help("Back to the list")
            }
            Spacer()
            Button("Cancel") {
                online?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if let online, online.chosen != nil {
                Button(applyLabel) {
                    model.applyFetchedMetadata(undoManager: undoManager)
                    if online.hasMoreBooks {
                        online.next()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(online.chosenProposals.isEmpty)
            } else if let online, online.hasMoreBooks {
                // Nothing chosen for this book: skipping is the answer, and it
                // is not the same button as Apply.
                Button("Skip This Book") { online.next() }
            }
        }
    }

    /// "Apply 3 fields", or plain "Apply" while nothing is ticked — the button
    /// is disabled then, and "Apply nothing" is a sentence no button should
    /// have to say.
    private var applyLabel: String {
        guard let online = model.onlineMetadata else { return "Apply" }
        guard let fields = model.fetchedMetadataSummary() else {
            return online.hasMoreBooks ? "Apply and Continue" : "Apply"
        }
        return online.hasMoreBooks ? "Apply \(fields) and Continue" : "Apply \(fields)"
    }
}
