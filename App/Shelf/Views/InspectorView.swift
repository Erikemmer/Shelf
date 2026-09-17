import AppKit
import ShelfCore
import SlateKit
import SwiftUI

/// The right column: everything about the selected book.
///
/// Sprint 2a made the first two fields editable – the rating and the read
/// status – and it was the change of controls Sprint 1 laid out for, not a
/// change of layout. Every edit goes through `LibraryModel.apply`, so it lands
/// on the window's undo stack before it reaches the disk, and it writes
/// `metadata.opf` and nothing else: a book file is never written (CONCEPT §4).
/// The remaining fields are still read-only and become editable in 2b.
struct InspectorView: View {
    @Environment(LibraryModel.self) private var model
    /// The window's undo manager, not one of the inspector's own: ⌘Z has to
    /// undo the change in the window it was made in.
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ScrollView {
            if let entry = model.selectedEntry {
                VStack(alignment: .leading, spacing: 16) {
                    cover(for: entry)
                    title(for: entry)
                    rating(for: entry)
                    facts(for: entry)
                    tags(for: entry)
                    description(for: entry)
                    formats(for: entry)
                    actions(for: entry)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Fields

    private func title(for entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.book.title)
                .font(.headline)
                .foregroundStyle(Slate.textPrimary)
                .textSelection(.enabled)
            Text(entry.book.authorLine)
                .font(.callout)
                .foregroundStyle(Slate.textSecondary)
                .textSelection(.enabled)
            if let series = entry.book.series {
                Text(series.display)
                    .font(.caption)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func facts(for entry: LibraryEntry) -> some View {
        SlateInspectorSection("Details") {
            VStack(alignment: .leading, spacing: 4) {
                if let publisher = entry.book.publisher {
                    SlateValueRow(name: "Publisher", value: publisher)
                }
                if let published = entry.book.published {
                    SlateValueRow(name: "Published", value: Self.year(published))
                }
                if let language = entry.book.language {
                    SlateValueRow(name: "Language", value: language)
                }
                SlateValueRow(name: "Added", value: Self.day(entry.book.addedAt))
                SlateValueRow(name: "Size", value: ByteCount.format(entry.totalBytes))
                ForEach(entry.book.identifiers.sorted(by: { $0.key < $1.key }), id: \.key) { scheme, value in
                    SlateValueRow(name: scheme.uppercased(), value: value)
                }
            }
        }
    }

    @ViewBuilder
    private func tags(for entry: LibraryEntry) -> some View {
        if !entry.book.tags.isEmpty {
            SlateInspectorSection("Tags") {
                SlateWrappingChips(items: entry.book.tags) { tag in
                    SlateChip(tag)
                }
            }
        }
    }

    @ViewBuilder
    private func description(for entry: LibraryEntry) -> some View {
        if let text = entry.book.description, !text.isEmpty {
            SlateInspectorSection("Description") {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Slate.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Formatting

    private static func year(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy"
        return formatter.string(from: date)
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
