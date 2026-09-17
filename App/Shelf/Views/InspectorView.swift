import AppKit
import ShelfCore
import SlateKit
import SwiftUI

/// The right column: everything about the selected book, and since Sprint 2b
/// every metadata field of it is editable.
///
/// The layout is Sprint 1's, unchanged: the same column in the same order, with
/// values that happen to have become fields (`SlateEditableRow` is sized like
/// the `SlateValueRow` it replaces). That is deliberate — an inspector whose
/// shape changes between versions is harder to learn than one that grows
/// controls where it already had values.
///
/// What this file does *not* decide: what an empty field means, how several
/// authors are separated, whether "2,5" is a number, whether an ISBN can be
/// that number. Those are rules, they can be wrong, and they live in the core
/// (`BookField`, `IdentifierEdit`, `TagEdit`, `ISBN`) where a test can reach
/// them. Every edit goes through `LibraryModel.commit`, which puts the previous
/// value on the window's undo stack before anything is written, and writes
/// `metadata.opf` and nothing else: a book file is never written (CONCEPT §4).
struct InspectorView: View {
    @Environment(LibraryModel.self) private var model
    /// The window's undo manager, not one of the inspector's own: ⌘Z has to
    /// undo the change in the window it was made in.
    @Environment(\.undoManager) private var undoManager

    /// The scheme of the identifier being added. Local because a half-typed
    /// "goodr" is not something the library needs to know about.
    @State private var newIdentifierScheme = ""
    /// Raised after each identifier added, to give the value field a fresh
    /// draft. See where it is used.
    @State private var identifierAdds = 0

    var body: some View {
        ScrollView {
            if let entry = model.selectedEntry {
                VStack(alignment: .leading, spacing: 16) {
                    cover(for: entry)
                    title(for: entry)
                    rating(for: entry)
                    facts(for: entry)
                    identifiers(for: entry)
                    tags(for: entry)
                    description(for: entry)
                    formats(for: entry)
                    actions(for: entry)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A different book means different values in every field, and
                // the half-typed scheme of an identifier is not one of them.
                .onChange(of: entry.id) { _, _ in newIdentifierScheme = "" }
            } else {
                Text("No book selected.")
                    .foregroundStyle(Slate.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Slate.panelBackground)
    }

    // MARK: Cover

    private func cover(for entry: LibraryEntry) -> some View {
        InspectorCover(entry: entry)
            .frame(maxWidth: .infinity)
    }

    // MARK: Title, authors, series

    private func title(for entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            field(.title, of: entry, font: .headline, placeholder: "Title")
            field(.authors, of: entry, font: .callout, placeholder: "Author & Second Author")
            series(for: entry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The series name, its index beside it, and where the book sits in it.
    ///
    /// "Book 3 of 7" is counted from the index's own facets, which the sidebar
    /// has already loaded — so it is the number of books *in this library*, and
    /// says so in the help rather than pretending to know how long the series
    /// really is.
    private func series(for entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SlateEditableBlock(
                    value: BookField.seriesName.text(of: entry.book), placeholder: "Series",
                    font: .caption
                ) { model.commit(.seriesName, $0, undoManager: undoManager) }
                // Named for the accessibility tree as well as for the
                // pointer: a field whose only label is its placeholder has
                // no label at all once something is typed into it, and the
                // tree showed exactly that — a bare `AXTextField`.
                .accessibilityLabel("Series")
                .help("Series — empty removes the book from its series")
                if entry.book.series != nil {
                    SlateEditableBlock(
                        value: BookField.seriesIndex.text(of: entry.book), placeholder: "#",
                        font: .caption
                    ) { model.commit(.seriesIndex, $0, undoManager: undoManager) }
                    .frame(width: 44)
                    .accessibilityLabel("Series index")
                    .help("Which book of the series – 3, or 2.5 for a novella")
                }
            }
            if let position = seriesPosition(for: entry) {
                Text(position)
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                    .help("Counted from the books in this library, not from the series itself")
            }
            note(for: BookField.seriesName.rawValue)
            note(for: BookField.seriesIndex.rawValue)
        }
    }

    private func seriesPosition(for entry: LibraryEntry) -> String? {
        guard let series = entry.book.series, series.index != nil,
            let total = model.seriesCount(named: series.name)
        else { return nil }
        // The index as the file spells it, so a novella reads "Book 3.5 of 7"
        // rather than "Book 3 of 7" or "Book 3.5000 of 7".
        return "Book \(BookField.seriesIndex.text(of: entry.book)) of \(total)"
    }

    private func rating(for entry: LibraryEntry) -> some View {
        SlateInspectorSection("Rating") {
            // `stars`, not `rating`: the control counts to five and the model
            // keeps Calibre's ten. Sprint 1 handed it `rating` unconverted, so
            // anything rated 5 or more drew five full stars.
            SlateStarRating(rating: entry.book.stars) { star in
                model.setStars(star, undoManager: undoManager)
            }
            .help("1–5 sets the rating, 0 clears it; the same star again clears it")
            // SlateKit labels the control but publishes no value, so the stars
            // come out of the accessibility tree as an element with a name and
            // nothing in it. Said here until SlateKit says it itself.
            .accessibilityValue(Text("\(entry.book.stars) of 5"))

            Toggle(
                "Read",
                isOn: Binding(
                    get: { entry.book.isRead },
                    set: { _ in model.toggleRead(undoManager: undoManager) })
            )
            .toggleStyle(.checkbox)
            .foregroundStyle(Slate.textSecondary)
            .font(.callout)
            .help("Whether the book has been read (R)")
        }
    }

    // MARK: Details

    private func facts(for entry: LibraryEntry) -> some View {
        SlateInspectorSection("Details") {
            VStack(alignment: .leading, spacing: 4) {
                row(.publisher, of: entry)
                row(.published, of: entry, placeholder: "yyyy-mm-dd")
                row(.language, of: entry, placeholder: "en")
                // Not editable, and not a field: both are facts about the disk
                // rather than claims about the book.
                SlateValueRow(name: "Added", value: Self.day(entry.book.addedAt))
                SlateValueRow(name: "Size", value: ByteCount.format(entry.totalBytes))
            }
        }
    }

    /// The identifiers, and one empty pair for adding another.
    ///
    /// An ISBN is checked against its check digit here and nowhere else: a
    /// wrong one is a duplicate key that matches the wrong book, and two
    /// digits swapped while typing thirteen of them is the usual mistake.
    private func identifiers(for entry: LibraryEntry) -> some View {
        SlateInspectorSection("Identifiers") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entry.book.identifiers.sorted(by: { $0.key < $1.key }), id: \.key) { scheme, value in
                    SlateEditableRow(
                        name: scheme.uppercased(), value: value,
                        help: "Empty removes the \(scheme.uppercased())"
                    ) {
                        model.commitIdentifier(scheme: scheme, value: $0, undoManager: undoManager)
                    }
                    note(for: "identifier:\(scheme.lowercased())")
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SlateEditableBlock(value: newIdentifierScheme, placeholder: "ISBN") {
                        newIdentifierScheme = $0
                    }
                    .frame(width: 70)
                    .accessibilityLabel("New identifier name")
                    .help("The name of the identifier – ISBN, ASIN, DOI, Goodreads")
                    SlateEditableBlock(value: "", placeholder: "new value") { typed in
                        guard !typed.isEmpty else { return }
                        model.commitIdentifier(
                            scheme: newIdentifierScheme, value: typed, undoManager: undoManager)
                        newIdentifierScheme = ""
                        identifierAdds += 1
                    }
                    // Rebuilt after each add, which is how the field comes back
                    // empty: its draft is its own `@State` and the value it is
                    // handed is always "".
                    .id(identifierAdds)
                    .accessibilityLabel("New identifier value")
                    .help("An ISBN is checked against its check digit; the others are not")
                }
                .font(.callout)
                note(for: "identifier:\(newIdentifierScheme.lowercased())")
                note(for: "identifier:")
            }
        }
    }

    // MARK: Tags

    /// The tag field, in Selector's shape: a line to type in, what the text
    /// could mean under it, the tags themselves as chips below that.
    ///
    /// The placeholder names the key that focuses it, because a control whose
    /// key is written on it is a control people find (CONCEPT §3.3).
    private func tags(for entry: LibraryEntry) -> some View {
        SlateInspectorSection("Tags") {
            SlateTokenField(
                tokens: entry.book.tags,
                placeholder: "Add tag… (T)",
                completions: model.tagCompletions,
                focusRequest: model.focusTagFieldRequest,
                onDraftChange: { model.updateTagDraft($0) },
                onAdd: { model.addTag($0, undoManager: undoManager) },
                onRemove: { model.removeTag($0, undoManager: undoManager) }
            )
            .help("⏎ adds, ⌫ removes the last one, click the ✕ to remove one")
        }
    }

    private func description(for entry: LibraryEntry) -> some View {
        SlateInspectorSection("Description") {
            VStack(alignment: .leading, spacing: 4) {
                SlateEditableBlock(
                    value: BookField.description.text(of: entry.book),
                    placeholder: "Add a description…", isMultiline: true, lineLimit: 10, font: .caption
                ) { model.commit(.description, $0, undoManager: undoManager) }
                .accessibilityLabel("Description")
                // ⏎ is a line break in here, so losing focus is what
                // finishes the field. Said out loud, because the other
                // fields behave differently.
                .help("Several lines. Finished when the field loses focus; Escape discards")
                note(for: BookField.description.rawValue)
            }
        }
    }

    private func formats(for entry: LibraryEntry) -> some View {
        SlateInspectorSection("Formats") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entry.formats.sorted { $0.format < $1.format }, id: \.id) { format in
                    SlateValueRow(
                        name: format.format.label,
                        value: ByteCount.format(format.byteSize))
                }
                // Recognised, named, and otherwise left entirely alone
                // (CONCEPT §12).
                if let drm = entry.drm {
                    SlateValueRow(name: drm.label, value: "not touched")
                }
            }
        }
    }

    private func actions(for entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SlateSecondaryButton("Open in Default App") { model.openSelectedInDefaultApp() }
                .help("Hands the file to Books, Preview or whatever reads it (↩)")
            SlateSecondaryButton("Show in Finder") { model.revealSelectedInFinder() }
                .help("Reveals \(entry.folder) (⇧⌘R)")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: One field

    /// A field with no name beside it, for the title block.
    private func field(
        _ which: BookField, of entry: LibraryEntry, font: Font, placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SlateEditableBlock(
                value: which.text(of: entry.book), placeholder: placeholder,
                isMultiline: which.isMultiline, font: font
            ) { model.commit(which, $0, undoManager: undoManager) }
            // Named for the accessibility tree as well as for the pointer. A
            // field whose only label is its placeholder has no label at all
            // once something is typed into it, and the tree showed exactly
            // that: a bare `AXTextField` with a value and nothing else.
            .accessibilityLabel(which.label)
            .help("\(which.label) — ⏎ or clicking away saves, Escape discards")
            note(for: which.rawValue)
        }
    }

    /// A named row in the Details block.
    private func row(
        _ which: BookField, of entry: LibraryEntry, placeholder: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SlateEditableRow(
                name: which.label, value: which.text(of: entry.book), placeholder: placeholder,
                help: "\(which.label) — empty removes it from metadata.opf"
            ) { model.commit(which, $0, undoManager: undoManager) }
            note(for: which.rawValue)
        }
    }

    /// The line under a field that says why the last value was refused.
    @ViewBuilder
    private func note(for key: String) -> some View {
        if let message = model.rejection(for: key) {
            SlateFieldNote(message)
        }
    }

    // MARK: Formatting

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// The cover at the inspector's size.
///
/// Its own view with its own task, so selecting a book does not make the whole
/// inspector wait for a decode.
struct InspectorCover: View {
    @Environment(LibraryModel.self) private var model
    let entry: LibraryEntry

    @State private var cover: NSImage?

    var body: some View {
        Group {
            if let cover {
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Slate.cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: Slate.cornerRadius)
                    .fill(Slate.contentBackground)
                    .aspectRatio(Theme.coverAspectRatio, contentMode: .fit)
                    .overlay {
                        Image(systemName: "book.closed")
                            .font(.system(size: 32))
                            .foregroundStyle(Slate.textSecondary.opacity(0.35))
                    }
            }
        }
        .task(id: entry.id) {
            guard let loader = model.loader else { return }
            // The grid tier first, blown up, so something appears at once; then
            // the sharp one.
            cover = await loader.cached(for: entry.id, size: .grid)
            cover = await loader.cover(for: entry, size: .large, priority: .interactive)
            // Only the selection is worth holding at the large size.
            await loader.limitLargeCovers(to: [entry.id])
        }
    }
}
