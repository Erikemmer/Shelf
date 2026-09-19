import AppKit
import ShelfCore
import SlateKit
import SwiftUI
import UniformTypeIdentifiers

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
        ScrollViewReader { scroller in
            ScrollView {
                if let entry = model.selectedEntry {
                    VStack(alignment: .leading, spacing: 16) {
                        cover(for: entry)
                        selectionHeader
                        title(for: entry)
                        rating(for: entry)
                        duplicate(for: entry)
                        facts(for: entry)
                        identifiers(for: entry)
                        customColumns(for: entry)
                        tags(for: entry).id(Self.tagsAnchor)
                        shelves(for: entry)
                        description(for: entry)
                        formats(for: entry)
                        actions(for: entry)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A different book means different values in every field,
                    // and the half-typed scheme of an identifier is not one of
                    // them.
                    .onChange(of: entry.id) { _, _ in newIdentifierScheme = "" }
                } else {
                    Text(Loc.string("No book selected."))
                        .foregroundStyle(Slate.textSecondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // The right-hand column of the window. A reader arriving on an
            // unnamed scroll area has no way to tell it from the two beside it.
            .accessibilityLabel(Loc.string("Inspector"))
            // T focuses the tag field, and the tag field is usually below the
            // fold: in a 280-point column the cover, the title block, the
            // rating, five details and the identifiers come first. A field that
            // takes focus off screen is a field nobody can see they are typing
            // into — the first screenshot taken after T showed the inspector
            // exactly where it had been, with the keyboard somewhere below it.
            .onChange(of: model.focusTagFieldRequest) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    scroller.scrollTo(Self.tagsAnchor, anchor: .center)
                }
            }
        }
        .background(Slate.panelBackground)
    }

    private static let tagsAnchor = "tags"

    // MARK: A selection of several

    /// What the inspector is talking about, when it is not one book.
    ///
    /// Said out loud because every field below it changes meaning: the cover is
    /// one of twelve, a value may be one of twelve, and three of the fields
    /// stop being editable. An inspector that looked the same for one book and
    /// for twelve would invite exactly the edit that must not happen.
    @ViewBuilder
    private var selectionHeader: some View {
        if model.hasMultipleSelection {
            VStack(alignment: .leading, spacing: 2) {
                Text(Loc.count("%lld books selected", model.selection.count))
                    .font(.callout)
                    .foregroundStyle(Slate.accent)
                Text(Loc.string("Rating, read status, tags and shelves apply to all of them."))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// What one field shows: the value, or "Mixed" when the books disagree.
    ///
    /// "Mixed" and not an empty field. An empty field says "these books have no
    /// publisher", which is a different fact — and it is the one that would
    /// invite somebody to fill it in.
    private static let mixed = Loc.string("Mixed")

    // MARK: Cover

    private func cover(for entry: LibraryEntry) -> some View {
        InspectorCover(entry: entry, undoManager: undoManager)
            .frame(maxWidth: .infinity)
    }

    // MARK: Title, authors, series

    /// The title block — the book's identity in three type sizes.
    ///
    /// **Only for one book.** Headline, callout and caption are how a *name*
    /// is drawn; across a selection those three positions held three bare
    /// `Mixed` in three sizes, with nothing to say which was the title, which
    /// the author and which the series. The values are not dropped: for a
    /// selection they move into the Details block, where every row carries its
    /// label (`mixedIdentity`).
    @ViewBuilder
    private func title(for entry: LibraryEntry) -> some View {
        if !model.hasMultipleSelection {
            VStack(alignment: .leading, spacing: 6) {
                editableField(.title, of: entry, font: .headline)
                editableField(.authors, of: entry, font: .callout)
                editableSeries(for: entry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A field's value across the selection, drawn rather than edited.
    ///
    /// Used for every text field once more than one book is selected. A title,
    /// a series or a description typed once and written to twelve books is not
    /// an edit but a mistake with twelve copies; a publisher across a selection
    /// is a reasonable thing to want and is in the backlog, not in this sprint.
    /// The same, for the one field that has a section heading of its own and so
    /// needs no label beside it.
    private func lockedBlock(_ which: BookField) -> some View {
        let shared = model.sharedValue(which)
        return Text(Self.text(of: shared))
            .font(.caption)
            .foregroundStyle(shared.isAValue ? Slate.textPrimary : Slate.textSecondary)
            .lineLimit(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .accessibilityLabel(Loc.core(which.label))
            .accessibilityValue(Self.text(of: shared))
            .help(Loc.string("%@ — edited one book at a time", Loc.core(which.label)))
    }

    private func lockedRow(_ which: BookField) -> some View {
        SlateValueRow(name: Loc.core(which.label), value: Self.text(of: model.sharedValue(which)))
            .help(Loc.string("%@ — edited one book at a time", Loc.core(which.label)))
    }

    /// What a read-only row writes for a field across a selection.
    ///
    /// Three answers, because two were not enough: a field none of the books
    /// fills in used to draw a **blank**, which says neither "they differ" nor
    /// "none of them has one". `Published` was blank while `Publisher` beside
    /// it read "Mixed", and the two rows meant different things and looked
    /// like the same kind of nothing (`docs/BACKLOG.md`, Sprint 3).
    private static func text(of shared: SharedValue) -> String {
        switch shared {
        case .same(let value): return value
        case .noneHasOne: return Loc.string("None of them")
        case .mixed: return mixed
        }
    }

    /// The series name, its index beside it, and where the book sits in it.
    ///
    /// "Book 3 of 7" is counted from the index's own facets, which the sidebar
    /// has already loaded — so it is the number of books *in this library*, and
    /// says so in the help rather than pretending to know how long the series
    /// really is.
    private func editableSeries(for entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SlateEditableBlock(
                    value: BookField.seriesName.text(of: entry.book),
                    placeholder: Loc.core(BookField.seriesName.placeholder), font: .caption
                ) { model.commit(.seriesName, $0, undoManager: undoManager) }
                // Named for the accessibility tree as well as for the
                // pointer: a field whose only label is its placeholder has
                // no label at all once something is typed into it, and the
                // tree showed exactly that — a bare `AXTextField`.
                .accessibilityLabel(Loc.string("Series"))
                .help(Loc.string("Series — empty removes the book from its series"))
                if entry.book.series != nil {
                    SlateEditableBlock(
                        value: BookField.seriesIndex.text(of: entry.book),
                        placeholder: Loc.core(BookField.seriesIndex.placeholder), font: .caption
                    ) { model.commit(.seriesIndex, $0, undoManager: undoManager) }
                    .frame(width: 44)
                    .accessibilityLabel(Loc.string("Series index"))
                    .help(Loc.string("Which book of the series — %@", Loc.core(BookField.seriesIndex.hint)))
                }
            }
            if let position = seriesPosition(for: entry) {
                Text(position)
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                    .help(Loc.string("Counted from the books in this library, not from the series itself"))
            }
            note(for: BookField.seriesName.rawValue)
            note(for: BookField.seriesIndex.rawValue)
        }
    }

    private func seriesPosition(for entry: LibraryEntry) -> String? {
        guard let series = entry.book.series, let index = series.index,
            let total = model.seriesCount(named: series.name)
        else { return nil }
        // The wording is `SeriesPosition`'s, in the core, because it is a rule
        // and not a format: a library that holds one book of a series a book
        // claims to be the third of said "Book 3 of 1" here until Sprint 5.
        // The index is passed as the file spells it, so a novella reads
        // "Book 3.5" rather than "Book 3" or "Book 3.5000".
        let place = SeriesPosition.place(
            printedIndex: BookField.seriesIndex.text(of: entry.book), index: index,
            countInLibrary: total)
        switch place {
        case .none: return nil
        case .book(let printed): return Loc.string("Book %@", printed)
        case .bookOf(let printed, let count): return Loc.string("Book %1$@ of %2$lld", printed, count)
        }
    }

    private func rating(for entry: LibraryEntry) -> some View {
        SlateInspectorSection(Loc.string("Rating")) {
            // `stars`, not `rating`: the control counts to five and the model
            // keeps Calibre's ten. Sprint 1 handed it `rating` unconverted, so
            // anything rated 5 or more drew five full stars.
            // The *shared* rating across the selection, and no stars at all
            // when they differ: five hollow stars would say "none of these is
            // rated", which is a different thing from "they are not all the
            // same". Clicking still sets all of them.
            // `.unratedOnly` because SlateKit 0.3.1 writes "3/5" beside the
            // stars again by default — the reading Selector has had since 0.1.0
            // and keeps. Five drawn stars are the statement here; the word at
            // zero stays either way.
            SlateStarRating(rating: model.sharedStars ?? 0, label: .unratedOnly) { star in
                model.setStars(star, undoManager: undoManager)
            }
            .help(
                model.hasMultipleSelection
                    ? Loc.string("1–5 rates all %lld books, 0 clears them", model.selection.count)
                    : Loc.string("1–5 sets the rating, 0 clears it; the same star again clears it")
            )
            // SlateKit labels the control but publishes no value, so the stars
            // come out of the accessibility tree as an element with a name and
            // nothing in it. Said here until SlateKit says it itself.
            .accessibilityValue(
                Text(model.sharedStars.map { Loc.string("%lld of 5", $0) } ?? Self.mixed))

            Toggle(
                Loc.string("Read"),
                isOn: Binding(
                    get: { model.sharedReadStatus ?? false },
                    set: { _ in model.toggleRead(undoManager: undoManager) })
            )
            .toggleStyle(.checkbox)
            .foregroundStyle(Slate.textSecondary)
            .font(.callout)
            // A mixed selection shows the box unticked and ticking it marks
            // them all read, which is the useful half of the gesture: toggling
            // each book on its own would leave the selection exactly as mixed
            // as before.
            .help(
                model.sharedReadStatus == nil
                    ? Loc.string(
                        "Some of these are read — this marks all %lld read (R)",
                        model.selection.count)
                    : Loc.string("Whether the book has been read (R)")
            )
            .accessibilityValue(
                Text(model.sharedReadStatus.map { $0 ? Loc.string("Read") : Loc.string("Unread") } ?? Self.mixed))
        }
    }

    /// Why the book is in *Duplicates* or in *Possible Duplicates*, when it is.
    ///
    /// Drawn where it can be seen rather than only as a filter, and it names
    /// every rule that matched: "same file" is a fact, "same title and author"
    /// is a guess that fits two editions and a translation as well as a real
    /// copy. Somebody acting on this line might delete a book, so the heading
    /// says which of the two it is and the lines say how sure each one is.
    @ViewBuilder
    private func duplicate(for entry: LibraryEntry) -> some View {
        let reasons = model.duplicateReasons(for: entry.id)
        if let strongest = reasons.first {
            SlateInspectorSection(strongest.isCertain ? Loc.string("Duplicate") : Loc.string("Possible Duplicate")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(reasons, id: \.self) { reason in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Loc.core(reason.label))
                                .font(.callout)
                                .foregroundStyle(Slate.textPrimary)
                            Text(Loc.core(reason.detail))
                                .font(.caption2)
                                .foregroundStyle(Slate.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .help(Loc.string("Nothing has been done about it – Shelf never removes a book"))
            }
        }
    }

    // MARK: Details

    private func facts(for entry: LibraryEntry) -> some View {
        SlateInspectorSection(Loc.string("Details")) {
            VStack(alignment: .leading, spacing: 4) {
                mixedIdentity
                row(.publisher, of: entry)
                row(.published, of: entry)
                row(.language, of: entry)
                // Not editable, and not a field: both are facts about the disk
                // rather than claims about the book.
                SlateValueRow(name: Loc.string("Added"), value: added)
                SlateValueRow(name: Loc.string("Size"), value: ByteCount.format(totalBytes))
                    .help(
                        model.hasMultipleSelection
                            ? Loc.string("Every file of all %lld books together", model.selection.count)
                            : Loc.string("Every file of this book together"))
            }
        }
    }

    /// Title, authors and series for a selection of several — with their names
    /// beside them.
    ///
    /// These three are the ones the title block draws for one book, where the
    /// type size *is* the label. Across a selection there is nothing to name
    /// them, so they come down here and are drawn like every other detail. They
    /// are read-only for the same reason they were before: a title typed once
    /// into twelve books is a mistake with twelve copies.
    @ViewBuilder
    private var mixedIdentity: some View {
        if model.hasMultipleSelection {
            lockedRow(.title)
            lockedRow(.authors)
            lockedRow(.seriesName)
        }
    }

    /// When the book was added, or the day they were all added.
    ///
    /// `Mixed` rather than the anchor book's date: with twelve books selected
    /// the anchor's date is a fact about one of them dressed up as a fact about
    /// all of them.
    private var added: String {
        let days = Set(model.selectedEntries.map { Self.day($0.book.addedAt) })
        return days.count == 1 ? (days.first ?? "") : Self.mixed
    }

    /// The bytes of every file of every selected book. A sum, not the anchor's
    /// size — "how much is this going to cost me on the card" is the question
    /// this row is asked with a selection in hand.
    private var totalBytes: Int64 {
        model.selectedEntries.reduce(0) { $0 + $1.totalBytes }
    }

    /// Calibre's own columns, shown and not editable (CONCEPT §4, "Should").
    ///
    /// **Read-only on purpose, and the reason is not laziness.** Shelf knows
    /// what these columns are *called* and what kind Calibre said they were,
    /// and nothing at all about what belongs in one. A field Shelf cannot
    /// validate is a field Shelf should not let anybody type into — and a
    /// library that goes back to Calibre must find them as it left them.
    ///
    /// The heading is the library's own word for them. Ordered by the column's
    /// Calibre number, so the inspector lists them in the order Calibre does
    /// rather than alphabetically, which is the order the person arranged.
    @ViewBuilder
    private func customColumns(for entry: LibraryEntry) -> some View {
        let columns = model.descriptor?.customColumns ?? []
        let shown = columns.filter { entry.book.customValues[$0.label] != nil }
        if !shown.isEmpty, !model.hasMultipleSelection {
            SlateInspectorSection(Loc.string("From Calibre")) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown.sorted { $0.number < $1.number }, id: \.label) { column in
                        SlateValueRow(
                            name: column.name,
                            value: Self.shown(entry.book.customValues[column.label] ?? "", as: column.kind)
                        )
                        .help(
                            Loc.string(
                                "%1$@ · %2$@ · imported from Calibre, not editable", column.hashLabel,
                                Loc.core(column.kind.label)))
                    }
                }
            }
        }
    }

    /// The identifiers, and one empty pair for adding another.
    ///
    /// An ISBN is checked against its check digit here and nowhere else: a
    /// wrong one is a duplicate key that matches the wrong book, and two
    /// digits swapped while typing thirteen of them is the usual mistake.
    private func identifiers(for entry: LibraryEntry) -> some View {
        SlateInspectorSection(Loc.string("Identifiers")) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entry.book.identifiers.sorted(by: { $0.key < $1.key }), id: \.key) { scheme, value in
                    SlateEditableRow(
                        name: scheme.uppercased(), value: value,
                        help: Loc.string("Empty removes the %@", scheme.uppercased())
                    ) {
                        model.commitIdentifier(scheme: scheme, value: $0, undoManager: undoManager)
                    }
                    note(for: "identifier:\(scheme.lowercased())")
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SlateEditableBlock(value: newIdentifierScheme, placeholder: Loc.string("ISBN")) {
                        newIdentifierScheme = $0
                    }
                    .frame(width: 70)
                    .accessibilityLabel(Loc.string("New identifier name"))
                    .help(Loc.string("The name of the identifier – ISBN, ASIN, DOI, Goodreads"))
                    // Prompts for whatever is being added rather than for
                    // "new value": half of an empty pair is a scheme, and a
                    // field that says "Add ASIN…" once ASIN is typed beside it
                    // is a field that has understood the question.
                    SlateEditableBlock(value: "", placeholder: Self.identifierPlaceholder(newIdentifierScheme)) {
                        typed in
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
                    .accessibilityLabel(Loc.string("New identifier value"))
                    .help(Loc.string("An ISBN is checked against its check digit; the others are not"))
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
        SlateInspectorSection(Loc.string("Tags")) {
            VStack(alignment: .leading, spacing: 6) {
                tagField(for: entry)
                // Tags only *some* of the selected books carry, drawn apart
                // from the ones they all share. Removing one of these would
                // quietly do nothing to most of the books if they were in the
                // same row; adding it finishes the job, which is what clicking
                // one does.
                if model.hasMultipleSelection, !model.mixedTags.isEmpty {
                    Text(Loc.string("On some of them"))
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                    SlateFlowLayout(spacing: 6) {
                        ForEach(model.mixedTags, id: \.self) { tag in
                            SlateSuggestionChip(tag) { model.addTag(tag, undoManager: undoManager) }
                                .help(Loc.string("Add “%1$@” to all %2$lld books", tag, model.selection.count))
                        }
                    }
                }
            }
        }
    }

    private func tagField(for entry: LibraryEntry) -> some View {
        SlateTokenField(
            tokens: model.hasMultipleSelection ? model.sharedTags : entry.book.tags,
            placeholder: model.hasMultipleSelection
                ? Loc.string("Add tag to %lld books… (T)", model.selection.count)
                : Loc.string("Add tag… (T)"),
            completions: model.tagCompletions,
            focusRequest: model.focusTagFieldRequest,
            // The help belongs to the entry field, not to the whole control:
            // handed in with `.help()` it reached every chip and replaced each
            // one's own "Remove science fiction".
            help: Loc.string("⏎ adds, ⌫ removes the last one, click the ✕ to remove one"),
            // Grey, with the ✕ under the pointer. SlateKit 0.3.1 defaults both
            // back to the accent-filled chip Selector draws, so Shelf asks for
            // the look it has had since 2c rather than inheriting it.
            chipStyle: .neutral,
            chipRemoveButton: .onHover,
            onDraftChange: { model.updateTagDraft($0) },
            onAdd: { model.addTag($0, undoManager: undoManager) },
            onRemove: { model.removeTag($0, undoManager: undoManager) }
        )
    }

    // MARK: Shelves

    /// Where the book stands, and the two ways to change it.
    ///
    /// Chips rather than a list, and the same chips the tags use, because they
    /// are the same kind of thing: a handful of short names, each removable on
    /// its own. The full path is shown — `Fiction/Sci-Fi`, not `Sci-Fi` — since
    /// two shelves may share a name under different parents and a chip reading
    /// only "Sci-Fi" would not say which one.
    private func shelves(for entry: LibraryEntry) -> some View {
        SlateInspectorSection(Loc.string("Shelves")) {
            VStack(alignment: .leading, spacing: 6) {
                let shelves = model.hasMultipleSelection ? model.sharedShelves : entry.book.shelves
                if shelves.isEmpty {
                    Text(
                        model.hasMultipleSelection
                            ? Loc.string("No shelf they all stand on") : Loc.string("Not on any shelf")
                    )
                    .font(.caption)
                    .foregroundStyle(Slate.textSecondary)
                } else {
                    SlateWrappingChips(items: shelves) { path in
                        SlateChip(path, style: .neutral, removeButton: .onHover) {
                            model.removeFromShelf(path, books: model.selectedEntries, undoManager: undoManager)
                        }
                        .help(
                            model.hasMultipleSelection
                                ? Loc.string(
                                    "Take all %1$lld books off %2$@", model.selection.count, path)
                                : Loc.string("Remove this book from %@", path))
                    }
                }
                if model.hasMultipleSelection, !model.mixedShelves.isEmpty {
                    Text(Loc.string("Some of them stand on"))
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                    SlateFlowLayout(spacing: 6) {
                        ForEach(model.mixedShelves, id: \.self) { path in
                            SlateSuggestionChip(path) {
                                guard let shelf = model.shelfTree.shelf(atPath: path) else { return }
                                model.addToShelf(shelf.id, books: model.selectedEntries, undoManager: undoManager)
                            }
                            .help(Loc.string("Put all %1$lld books on %2$@", model.selection.count, path))
                        }
                    }
                }
                addToShelfMenu(for: entry)
            }
        }
    }

    @ViewBuilder
    private func addToShelfMenu(for entry: LibraryEntry) -> some View {
        let already = model.hasMultipleSelection ? model.sharedShelves : entry.book.shelves
        let available = model.shelfTree.inDrawnOrder().filter {
            guard let path = model.shelfTree.storedPath(of: $0.shelf.id) else { return false }
            return !already.contains(path)
        }
        if available.isEmpty {
            Text(
                model.shelfTree.isEmpty
                    ? Loc.string("Make one with + in the sidebar") : Loc.string("On every shelf there is")
            )
            .font(.caption2)
            .foregroundStyle(Slate.textSecondary)
        } else {
            Menu(Loc.string("Add to Shelf…")) {
                ForEach(available, id: \.shelf.id) { row in
                    Button(String(repeating: "    ", count: row.depth) + row.shelf.name) {
                        model.addToShelf(
                            row.shelf.id, books: model.selectedEntries, undoManager: undoManager)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            .frame(maxWidth: 140, alignment: .leading)
            .help(Loc.string("Put this book on a shelf — or drag it onto one in the sidebar"))
        }
    }

    @ViewBuilder
    private func description(for entry: LibraryEntry) -> some View {
        if model.hasMultipleSelection {
            SlateInspectorSection(Loc.string("Description")) { lockedBlock(.description) }
        } else {
            editableDescription(for: entry)
        }
    }

    private func editableDescription(for entry: LibraryEntry) -> some View {
        SlateInspectorSection(Loc.string("Description")) {
            VStack(alignment: .leading, spacing: 4) {
                SlateEditableBlock(
                    value: BookField.description.text(of: entry.book),
                    placeholder: Loc.core(BookField.description.placeholder), isMultiline: true, lineLimit: 10,
                    font: .caption
                ) { model.commit(.description, $0, undoManager: undoManager) }
                .accessibilityLabel(Loc.string("Description"))
                // ⏎ is a line break in here, so losing focus is what
                // finishes the field. Said out loud, because the other
                // fields behave differently.
                .help(Loc.string("Several lines. Finished when the field loses focus; Escape discards"))
                note(for: BookField.description.rawValue)
            }
        }
    }

    /// The book's files: one row each, with its size, what protects it, and a
    /// way to the file itself.
    ///
    /// Per *file* and not per book, which is the Sprint 4 change: a book can
    /// hold an EPUB and an AZW3 and only one of them be protected, and a single
    /// badge on the book would have said nothing about which. `Add Format…`
    /// puts another file beside the ones already there — the same operation a
    /// drag of a second file performs, through the same planner, so the two
    /// cannot disagree.
    private func formats(for entry: LibraryEntry) -> some View {
        SlateInspectorSection(Loc.string("Formats")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entry.formats.sorted { $0.format < $1.format }, id: \.id) { format in
                    formatRow(format, in: entry)
                }

                SlateSecondaryButton(Loc.string("Add Format…")) { model.presentAddFormatPanel() }
                    .help(Loc.string("Adds another file to this book – it is never written over one that is there"))
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func formatRow(_ format: BookFormat, in entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(format.format.label)
                    .font(.callout)
                    .foregroundStyle(Slate.textPrimary)
                // Recognised, named, and otherwise left entirely alone
                // (CONCEPT §12, ADR 0012). On the *file*, because that is what
                // carries the protection.
                if let drm = format.drm {
                    DRMBadge(drm)
                }
                Spacer(minLength: 4)
                Text(ByteCount.format(format.byteSize))
                    .font(.caption)
                    .foregroundStyle(Slate.textSecondary)
                    .monospacedDigit()
            }

            Text(format.fileName)
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let note = format.format.unreadableNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
            // A CBR says what this Mac can actually do with it, always and not
            // only when something has gone wrong (CONCEPT §13). Whether RAR5 can
            // be read is a property of the libarchive this Mac happens to ship,
            // so it is a different answer on a different Mac — and a person
            // looking at a comic whose metadata came from its file name deserves
            // to be told why rather than left to wonder.
            if format.format == .cbr, let note = LibArchive.shared?.capabilities.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            } else if format.format == .cbr {
                Text(Loc.string("libarchive is not available on this Mac, so this CBR is listed by name only."))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
            if let drm = format.drm {
                Text(Loc.string("%@. Shelf shows it and does not touch it.", Loc.core(drm.label)))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
        .contentShape(Rectangle())
        // One file is one fact. Read separately, the four lines came out as
        // four stops — "EPUB", "1,2 MB", "Dune - Frank Herbert.epub", "Adobe
        // DRM" — each one carrying the same help string and none of them
        // saying which file the one before it belonged to.
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button(Loc.string("Show in Finder")) { model.revealInFinder(format, of: entry) }
            Button(Loc.string("Open in Default App")) { model.open(format, of: entry) }
        }
        .help(Loc.string("%@ · right-click to show it in the Finder", format.fileName))
    }

    private func actions(for entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SlateSecondaryButton(Loc.string("Open in Default App")) { model.openSelectedInDefaultApp() }
                .help(Loc.string("Hands the file to Books, Preview or whatever reads it (↩)"))
            SlateSecondaryButton(Loc.string("Show in Finder")) { model.revealSelectedInFinder() }
                .help(Loc.string("Reveals %@ (⇧⌘R)", entry.folder))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: One field

    private func editableField(
        _ which: BookField, of entry: LibraryEntry, font: Font
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SlateEditableBlock(
                value: which.text(of: entry.book), placeholder: Loc.core(which.placeholder),
                isMultiline: which.isMultiline, font: font
            ) { model.commit(which, $0, undoManager: undoManager) }
            // Named for the accessibility tree as well as for the pointer. A
            // field whose only label is its placeholder has no label at all
            // once something is typed into it, and the tree showed exactly
            // that: a bare `AXTextField` with a value and nothing else.
            .accessibilityLabel(Loc.core(which.label))
            .help(Self.help(for: which, ending: Loc.string("⏎ or clicking away saves, Escape discards")))
            note(for: which.rawValue)
        }
    }

    /// A named row in the Details block.
    @ViewBuilder
    private func row(_ which: BookField, of entry: LibraryEntry) -> some View {
        if model.hasMultipleSelection {
            lockedRow(which)
        } else {
            editableRow(which, of: entry)
        }
    }

    private func editableRow(_ which: BookField, of entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SlateEditableRow(
                name: Loc.core(which.label), value: which.text(of: entry.book),
                placeholder: Loc.core(which.placeholder),
                help: Self.help(for: which, ending: Loc.string("empty removes it from metadata.opf"))
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

    /// A field's help: what the field is, its own hint where it has one, and
    /// what finishes it. Built in one place so nine fields cannot describe the
    /// same gesture in nine ways.
    private static func help(for field: BookField, ending: String) -> String {
        [Loc.core(field.label), Loc.core(field.hint), ending]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    private static func identifierPlaceholder(_ scheme: String) -> String {
        let trimmed = scheme.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            ? Loc.string("Add ISBN…") : Loc.string("Add %@…", trimmed.uppercased())
    }

    // MARK: Formatting

    /// A custom value as a person reads it.
    ///
    /// What is *stored* is the canonical form — a date as a full ISO-8601
    /// stamp — because that is what goes into `metadata.opf` and has to come
    /// back out of it unchanged. What is *shown* is the same date in the
    /// reader's own region. The first screenshot of this section had
    /// `2023-11-01T00:00:00+00:00` in it, which is a value a machine is
    /// pleased with.
    private static func shown(_ value: String, as kind: CalibreCustomColumn.Kind) -> String {
        guard kind == .datetime, let date = OPFDate.parse(value) else { return value }
        return day(date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// The cover at the inspector's size, and the three ways to change it.
///
/// Its own view with its own task, so selecting a book does not make the whole
/// inspector wait for a decode.
///
/// **Why the actions are here and not in a menu bar menu.** A cover belongs to
/// one book, and the one place in this window that is unambiguously about one
/// book is the inspector. Putting `Set Cover…` in the Library menu would make
/// it look as though it applied to the selection, which is the mistake the
/// inspector's own text fields are locked against across a multiple selection
/// (`lockedBlock`): a cover typed once into twelve books is not an edit but a
/// mistake with twelve copies.
struct InspectorCover: View {
    @Environment(LibraryModel.self) private var model
    let entry: LibraryEntry
    /// The window's, handed in rather than read from the environment: this
    /// view is built by `InspectorView`, which already has it, and ⌘Z has to
    /// undo the change in the window it was made in.
    let undoManager: UndoManager?

    @State private var cover: NSImage?
    @State private var isTargeted = false
    @State private var isChoosingFile = false

    var body: some View {
        VStack(spacing: 6) {
            picture
                .contextMenu { actions }
                .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
                    drop(providers)
                }
                .overlay {
                    // The whole point of a drop target is that it says so
                    // before the mouse button comes up.
                    if isTargeted {
                        RoundedRectangle(cornerRadius: Slate.cornerRadius)
                            .strokeBorder(Slate.accent, lineWidth: 2)
                    }
                }
                .accessibilityAction(named: Loc.string("Set Cover…")) { isChoosingFile = true }

            Menu(Loc.string("Cover")) { actions }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(Loc.string("Change the cover of %@", entry.book.title))

            if let refusal = model.coverRefusal {
                VStack(spacing: 2) {
                    Text(Loc.core(refusal.message))
                    if let detail = refusal.detail {
                        Text(detail).foregroundStyle(Slate.textSecondary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Slate.accent)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fileImporter(
            isPresented: $isChoosingFile, allowedContentTypes: CoverImage.accepted
        ) { result in
            guard case .success(let url) = result else { return }
            Task { await model.setCover(of: entry, fromFileAt: url, undoManager: undoManager) }
        }
    }

    // MARK: The three ways in

    @ViewBuilder
    private var actions: some View {
        Button(Loc.string("Set Cover…")) { isChoosingFile = true }

        // One book, one format: a plain item. Several formats: one item each,
        // because an EPUB and a PDF of the same book carry two different
        // pictures and Shelf must not pick for the reader. The same reasoning
        // as `SendToDeviceSheet`'s format choice.
        if entry.formats.count == 1, let only = entry.formats.first {
            Button(Loc.string("Take Cover from Book File")) { take(only) }
        } else if !entry.formats.isEmpty {
            Menu(Loc.string("Take Cover from Book File")) {
                ForEach(entry.formats.sorted { $0.format < $1.format }, id: \.fileName) { format in
                    Button(format.format.label) { take(format) }
                }
            }
        }

        Divider()
        Button(Loc.string("Download Cover…")) { model.presentFetchMetadata() }
    }

    private func take(_ format: BookFormat) {
        Task { await model.takeCoverFromBookFile(of: entry, format: format, undoManager: undoManager) }
    }

    /// An image dragged onto the picture.
    ///
    /// Two shapes, because the Finder and a browser offer different things: a
    /// file on disk arrives as a URL, and a picture dragged out of a web page
    /// or Preview arrives as bytes. `.fileURL` first, so a file keeps its own
    /// bytes rather than whatever the drag happened to render.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    await model.setCover(of: entry, fromFileAt: url, undoManager: undoManager)
                }
            }
            return true
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                await model.setCover(of: entry, fromImageData: data, undoManager: undoManager)
            }
        }
        return true
    }

    // MARK: The picture

    private var picture: some View {
        Group {
            if let cover {
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Slate.cornerRadius))
                    .accessibilityLabel(Loc.string("Cover of %@", entry.book.title))
            } else {
                RoundedRectangle(cornerRadius: Slate.cornerRadius)
                    .fill(Slate.contentBackground)
                    .aspectRatio(Theme.coverAspectRatio, contentMode: .fit)
                    .overlay {
                        Image(systemName: "book.closed")
                            .font(.system(size: 32))
                            .foregroundStyle(Slate.textSecondary.opacity(0.35))
                    }
                    // Announced as "book.closed" until Sprint 7, which is the
                    // symbol's name and not a fact about the book.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Loc.string("No cover"))
            }
        }
        // Keyed on the generation and on the refresh counter as well as on the
        // book, so a replaced cover is redrawn rather than waited out. The
        // counter existed for this since Sprint 6 and **nothing had ever read
        // it**: a cover fetched from the net changed the folder and the
        // inspector went on drawing what it had, until the selection moved.
        .task(id: [entry.id.uuidString, "\(entry.book.coverGeneration)", "\(model.coverRefreshRequest)"]) {
            guard let loader = model.loader else { return }
            // The grid tier first, blown up, so something appears at once; then
            // the sharp one.
            cover = await loader.cached(for: entry.id, size: .grid)?.image
            cover = await loader.cover(for: entry, size: .large, priority: .interactive)?.image
            // Only the selection is worth holding at the large size.
            await loader.limitLargeCovers(to: [entry.id])
        }
    }
}
