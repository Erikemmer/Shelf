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
                    Text("No book selected.")
                        .foregroundStyle(Slate.textSecondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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
                Text("\(model.selection.count) books selected")
                    .font(.callout)
                    .foregroundStyle(Slate.accent)
                Text("Rating, read status, tags and shelves apply to all of them.")
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
    private static let mixed = "Mixed"

    // MARK: Cover

    private func cover(for entry: LibraryEntry) -> some View {
        InspectorCover(entry: entry)
            .frame(maxWidth: .infinity)
    }

    // MARK: Title, authors, series

    private func title(for entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            field(.title, of: entry, font: .headline)
            field(.authors, of: entry, font: .callout)
            series(for: entry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A field's value across the selection, drawn rather than edited.
    ///
    /// Used for every text field once more than one book is selected. A title,
    /// a series or a description typed once and written to twelve books is not
    /// an edit but a mistake with twelve copies; a publisher across a selection
    /// is a reasonable thing to want and is in the backlog, not in this sprint.
    private func locked(_ which: BookField, font: Font = .callout) -> some View {
        Text(model.sharedText(which) ?? Self.mixed)
            .font(font)
            .foregroundStyle(
                model.sharedText(which) == nil ? Slate.textSecondary : Slate.textPrimary
            )
            .lineLimit(which.isMultiline ? 6 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .accessibilityLabel(which.label)
            .accessibilityValue(model.sharedText(which) ?? Self.mixed)
            .help("\(which.label) — edited one book at a time")
    }

    private func lockedRow(_ which: BookField) -> some View {
        SlateValueRow(name: which.label, value: model.sharedText(which) ?? Self.mixed)
            .help("\(which.label) — edited one book at a time")
    }

    /// The series name, its index beside it, and where the book sits in it.
    ///
    /// "Book 3 of 7" is counted from the index's own facets, which the sidebar
    /// has already loaded — so it is the number of books *in this library*, and
    /// says so in the help rather than pretending to know how long the series
    /// really is.
    @ViewBuilder
    private func series(for entry: LibraryEntry) -> some View {
        if model.hasMultipleSelection {
            locked(.seriesName, font: .caption)
        } else {
            editableSeries(for: entry)
        }
    }

    private func editableSeries(for entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SlateEditableBlock(
                    value: BookField.seriesName.text(of: entry.book),
                    placeholder: BookField.seriesName.placeholder, font: .caption
                ) { model.commit(.seriesName, $0, undoManager: undoManager) }
                // Named for the accessibility tree as well as for the
                // pointer: a field whose only label is its placeholder has
                // no label at all once something is typed into it, and the
                // tree showed exactly that — a bare `AXTextField`.
                .accessibilityLabel("Series")
                .help("Series — empty removes the book from its series")
                if entry.book.series != nil {
                    SlateEditableBlock(
                        value: BookField.seriesIndex.text(of: entry.book),
                        placeholder: BookField.seriesIndex.placeholder, font: .caption
                    ) { model.commit(.seriesIndex, $0, undoManager: undoManager) }
                    .frame(width: 44)
                    .accessibilityLabel("Series index")
                    .help("Which book of the series — \(BookField.seriesIndex.hint)")
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
                    ? "1–5 rates all \(model.selection.count) books, 0 clears them"
                    : "1–5 sets the rating, 0 clears it; the same star again clears it"
            )
            // SlateKit labels the control but publishes no value, so the stars
            // come out of the accessibility tree as an element with a name and
            // nothing in it. Said here until SlateKit says it itself.
            .accessibilityValue(
                Text(model.sharedStars.map { "\($0) of 5" } ?? Self.mixed))

            Toggle(
                "Read",
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
                    ? "Some of these are read — this marks all \(model.selection.count) read (R)"
                    : "Whether the book has been read (R)"
            )
            .accessibilityValue(
                Text(model.sharedReadStatus.map { $0 ? "Read" : "Unread" } ?? Self.mixed))
        }
    }

    /// Why the book is in *Duplicates*, when it is.
    ///
    /// Drawn where it can be seen rather than only as a filter, and it names
    /// the rule: "same file" is a fact, "same title and author" is a guess that
    /// fits two editions and a translation as well as a real copy. Somebody
    /// acting on this line might delete a book, so the line has to say how
    /// sure it is.
    @ViewBuilder
    private func duplicate(for entry: LibraryEntry) -> some View {
        if let reason = model.duplicateReason(for: entry.id) {
            SlateInspectorSection("Duplicate") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reason.label)
                        .font(.callout)
                        .foregroundStyle(Slate.textPrimary)
                    Text(reason.detail)
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .help("Nothing has been done about it – Shelf never removes a book")
            }
        }
    }

    // MARK: Details

    private func facts(for entry: LibraryEntry) -> some View {
        SlateInspectorSection("Details") {
            VStack(alignment: .leading, spacing: 4) {
                row(.publisher, of: entry)
                row(.published, of: entry)
                row(.language, of: entry)
                // Not editable, and not a field: both are facts about the disk
                // rather than claims about the book.
                SlateValueRow(name: "Added", value: Self.day(entry.book.addedAt))
                SlateValueRow(name: "Size", value: ByteCount.format(entry.totalBytes))
            }
        }
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
            SlateInspectorSection("From Calibre") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown.sorted { $0.number < $1.number }, id: \.label) { column in
                        SlateValueRow(
                            name: column.name,
                            value: Self.shown(entry.book.customValues[column.label] ?? "", as: column.kind)
                        )
                        .help("\(column.hashLabel) · \(column.kind.label) · imported from Calibre, not editable")
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
            VStack(alignment: .leading, spacing: 6) {
                tagField(for: entry)
                // Tags only *some* of the selected books carry, drawn apart
                // from the ones they all share. Removing one of these would
                // quietly do nothing to most of the books if they were in the
                // same row; adding it finishes the job, which is what clicking
                // one does.
                if model.hasMultipleSelection, !model.mixedTags.isEmpty {
                    Text("On some of them")
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                    SlateFlowLayout(spacing: 6) {
                        ForEach(model.mixedTags, id: \.self) { tag in
                            SlateSuggestionChip(tag) { model.addTag(tag, undoManager: undoManager) }
                                .help("Add “\(tag)” to all \(model.selection.count) books")
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
                ? "Add tag to \(model.selection.count) books… (T)" : "Add tag… (T)",
            completions: model.tagCompletions,
            focusRequest: model.focusTagFieldRequest,
            // The help belongs to the entry field, not to the whole control:
            // handed in with `.help()` it reached every chip and replaced each
            // one's own "Remove science fiction".
            help: "⏎ adds, ⌫ removes the last one, click the ✕ to remove one",
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
        SlateInspectorSection("Shelves") {
            VStack(alignment: .leading, spacing: 6) {
                let shelves = model.hasMultipleSelection ? model.sharedShelves : entry.book.shelves
                if shelves.isEmpty {
                    Text(model.hasMultipleSelection ? "No shelf they all stand on" : "Not on any shelf")
                        .font(.caption)
                        .foregroundStyle(Slate.textSecondary)
                } else {
                    SlateWrappingChips(items: shelves) { path in
                        SlateChip(path, style: .neutral, removeButton: .onHover) {
                            model.removeFromShelf(path, books: model.selectedEntries, undoManager: undoManager)
                        }
                        .help(
                            model.hasMultipleSelection
                                ? "Take all \(model.selection.count) books off \(path)"
                                : "Remove this book from \(path)")
                    }
                }
                if model.hasMultipleSelection, !model.mixedShelves.isEmpty {
                    Text("Some of them stand on")
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                    SlateFlowLayout(spacing: 6) {
                        ForEach(model.mixedShelves, id: \.self) { path in
                            SlateSuggestionChip(path) {
                                guard let shelf = model.shelfTree.shelf(atPath: path) else { return }
                                model.addToShelf(shelf.id, books: model.selectedEntries, undoManager: undoManager)
                            }
                            .help("Put all \(model.selection.count) books on \(path)")
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
            Text(model.shelfTree.isEmpty ? "Make one with + in the sidebar" : "On every shelf there is")
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
        } else {
            Menu("Add to Shelf…") {
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
            .help("Put this book on a shelf — or drag it onto one in the sidebar")
        }
    }

    @ViewBuilder
    private func description(for entry: LibraryEntry) -> some View {
        if model.hasMultipleSelection {
            SlateInspectorSection("Description") { locked(.description, font: .caption) }
        } else {
            editableDescription(for: entry)
        }
    }

    private func editableDescription(for entry: LibraryEntry) -> some View {
        SlateInspectorSection("Description") {
            VStack(alignment: .leading, spacing: 4) {
                SlateEditableBlock(
                    value: BookField.description.text(of: entry.book),
                    placeholder: BookField.description.placeholder, isMultiline: true, lineLimit: 10,
                    font: .caption
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
    @ViewBuilder
    private func field(
        _ which: BookField, of entry: LibraryEntry, font: Font
    ) -> some View {
        if model.hasMultipleSelection {
            locked(which, font: font)
        } else {
            editableField(which, of: entry, font: font)
        }
    }

    private func editableField(
        _ which: BookField, of entry: LibraryEntry, font: Font
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SlateEditableBlock(
                value: which.text(of: entry.book), placeholder: which.placeholder,
                isMultiline: which.isMultiline, font: font
            ) { model.commit(which, $0, undoManager: undoManager) }
            // Named for the accessibility tree as well as for the pointer. A
            // field whose only label is its placeholder has no label at all
            // once something is typed into it, and the tree showed exactly
            // that: a bare `AXTextField` with a value and nothing else.
            .accessibilityLabel(which.label)
            .help(Self.help(for: which, ending: "⏎ or clicking away saves, Escape discards"))
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
                name: which.label, value: which.text(of: entry.book),
                placeholder: which.placeholder,
                help: Self.help(for: which, ending: "empty removes it from metadata.opf")
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
        [field.label, field.hint, ending]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    private static func identifierPlaceholder(_ scheme: String) -> String {
        let trimmed = scheme.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Add ISBN…" : "Add \(trimmed.uppercased())…"
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
