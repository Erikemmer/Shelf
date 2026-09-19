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
                    SlateStatusBar(Loc.string("Asking Open Library and Google Books"))
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
                        .accessibilityLabel(Loc.string("Network note"))
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
                Text(Loc.string("Fetch Metadata"))
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
                Text(Loc.string("Looking for %@", query.description))
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
                    Text(Loc.string("Nothing came back. The book keeps everything it has."))
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
                Text(Loc.number(score))
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
        .help(Loc.string("Compare this one with the book, field by field"))
        // "Candidate:" first, so the row is recognisable as one in the
        // accessibility tree — where the title alone is also the grid's
        // caption, the inspector's heading and, often, the window's subject.
        .accessibilityLabel(
            Loc.string(
                "Candidate: %1$@, %2$@, match %3$lld of 100", candidate.title, candidate.source.name,
                score))
    }

    // MARK: Step two — old beside new

    private func comparison(_ online: OnlineMetadataModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            cover(online)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if online.proposals.isEmpty {
                        Text(Loc.string("This candidate says nothing the book does not already say."))
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
            .accessibilityLabel(
                Loc.string("Take over %1$@ from %2$@", Loc.core(proposal.label), proposal.sourceLabel))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(proposal.label)
                        .font(.caption)
                        .foregroundStyle(Slate.textSecondary)
                    Text(Self.kindLabel(proposal.kind))
                        .font(.caption2)
                        .foregroundStyle(proposal.kind == .replace ? Slate.accent : Slate.textSecondary)
                    Spacer(minLength: 8)
                    // Who said it. With two services there is no such thing as
                    // "what the service says", and a person choosing between
                    // two answers has to be able to see whose each one is.
                    Text(proposal.sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary.opacity(0.8))
                        .lineLimit(1)
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
        .help(Self.help(for: proposal, contested: Self.isContested(proposal, in: online.proposals)))
    }

    /// Whether the other service answered this field differently, so this line
    /// and its neighbour are a choice between two rather than two decisions.
    private static func isContested(_ proposal: FieldProposal, in all: [FieldProposal]) -> Bool {
        proposal.target != .tags && all.contains { $0.targetID == proposal.targetID && $0.id != proposal.id }
    }

    private static func kindLabel(_ kind: FieldProposal.Kind) -> String {
        switch kind {
        case .add: return Loc.string("not set")
        case .replace: return Loc.string("would replace")
        case .append: return Loc.string("would add")
        case .same: return Loc.string("already the same")
        }
    }

    private static func help(for proposal: FieldProposal, contested: Bool) -> String {
        if contested {
            return Loc.string(
                "%@ says this; the other service says something else. Ticked neither, because "
                    + "that is a decision. Ticking one unticks the other", proposal.sourceLabel)
        }
        switch proposal.kind {
        case .add:
            return Loc.string(
                "%@ is empty on this book — ticked because it fills a gap", Loc.core(proposal.label))
        case .replace:
            return Loc.string(
                "%@ would be replaced. Not ticked for you: that is your library's answer",
                Loc.core(proposal.label))
        case .append:
            return Loc.string(
                "These would be added to the tags the book has. Nothing is taken off it — and "
                    + "nothing is ticked for you: a catalogue's subjects are not your vocabulary")
        case .same: return Loc.string("%@ already says this", Loc.core(proposal.label))
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
                    .accessibilityLabel(
                        Loc.string(
                            "Cover from %@", online.chosen?.source.name ?? Loc.string("the service")))
            } else {
                RoundedRectangle(cornerRadius: Slate.cornerRadius)
                    .fill(Slate.contentBackground)
                    .frame(width: 140, height: 210)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                            .foregroundStyle(Slate.textSecondary.opacity(0.35))
                    }
                    .accessibilityLabel(Loc.string("No cover from the service"))
            }

            if online.wantsCover, online.chosen?.coverURL != nil {
                // The wording carries the warning, because the picture above it
                // carries the evidence: a person replacing a cover has just
                // looked at what they are replacing it with. A button that said
                // "Use This Cover" over an existing one would be a silent
                // overwrite with a friendly label.
                SlateSecondaryButton(buttonLabel(online)) {
                    Task { await model.fetchCoverFromTheNet(undoManager: undoManager) }
                }
                .disabled(online.isFetchingCover)
                // The one thing here that writes a file without Apply, so it
                // says exactly what it writes and where.
                .help(
                    online.coverAlreadyThere
                        ? Loc.string(
                            "Puts this picture next to the book and the one that is there in the Trash. "
                                + "⌘Z puts it back. The book file is not touched")
                        : Loc.string("Writes cover.jpg next to the book. The book file is not touched"))
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

    /// Three states, because two would hide the one that matters: saving,
    /// replacing something, and putting the first one there.
    private func buttonLabel(_ online: OnlineMetadataModel) -> String {
        if online.isFetchingCover { return Loc.string("Saving…") }
        return online.coverAlreadyThere ? Loc.string("Replace Cover") : Loc.string("Use This Cover")
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack {
            if online?.chosen != nil {
                SlateSecondaryButton(Loc.string("Other Candidates")) { online?.backToCandidates() }
                    .help(Loc.string("Back to the list"))
            }
            Spacer()
            Button(Loc.string("Cancel")) {
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
                Button(Loc.string("Skip This Book")) { online.next() }
            }
        }
    }

    /// "Apply 3 fields", or plain "Apply" while nothing is ticked — the button
    /// is disabled then, and "Apply nothing" is a sentence no button should
    /// have to say.
    private var applyLabel: String {
        guard let online = model.onlineMetadata else { return Loc.string("Apply") }
        guard let fields = model.fetchedMetadataSummary() else {
            return online.hasMoreBooks ? Loc.string("Apply and Continue") : Loc.string("Apply")
        }
        return online.hasMoreBooks
            ? Loc.string("Apply %@ and Continue", fields) : Loc.string("Apply %@", fields)
    }
}
