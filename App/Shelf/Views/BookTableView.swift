import AppKit
import ShelfCore
import SlateKit
import SwiftUI

/// The library as a table (⌘2): the same books, the same selection and the
/// same keys as the grid, drawn as rows.
///
/// It exists because a grid answers "which one looks right" and a table answers
/// "which of these is missing a publisher" (CONCEPT §3.2). Nothing about *what*
/// is shown differs — it reads `model.visible` like the grid does, so a filter,
/// a search and a sort order mean the same thing in both.
///
/// **The header sorts through the model, not in memory.** `BookSort` owns the
/// SQL order; a header that sorted the loaded rows itself would put the table in
/// one order and leave the grid and the sort menu in another, which is the one
/// thing this view must not do.
struct BookTableView: View {
    @Environment(LibraryModel.self) private var model
    @FocusState.Binding var focus: WindowFocus?

    /// Which columns are hidden and how wide they are. SwiftUI builds the
    /// header's context menu from this and writes the user's choices back into
    /// it; the model saves it into `library.json`.
    @State private var customization = TableColumnCustomization<LibraryEntry>()

    var body: some View {
        Table(
            of: LibraryEntry.self,
            selection: Binding(
                get: { model.selection }, set: { model.replaceSelection($0) }),
            sortOrder: Binding(get: { comparators }, set: { adopt($0) }),
            columnCustomization: $customization
        ) {
            TableColumn(Loc.string("Title"), value: \.book.titleSort) { entry in
                Text(entry.book.title).lineLimit(1)
            }
            .width(min: 140, ideal: 260)
            .customizationID(Column.title.rawValue)

            TableColumn(Loc.string("Author"), value: \.sortableAuthor) { entry in
                Text(entry.book.authorLine).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
            .customizationID(Column.author.rawValue)

            TableColumn(Loc.string("Series"), value: \.sortableSeries) { entry in
                Text(entry.book.series?.display ?? "").lineLimit(1)
            }
            .width(min: 80, ideal: 140)
            .customizationID(Column.series.rawValue)

            TableColumn(Loc.string("Rating"), value: \.book.rating) { entry in
                // Glyphs rather than the five-star control: a row 18 points
                // high has no room for a control, and a table is read down a
                // column — "★★★☆☆" lines up where five separate images do not.
                Text(Self.stars(entry.book.stars))
                    .foregroundStyle(entry.book.stars > 0 ? Slate.accent : Slate.textSecondary)
                    .accessibilityLabel(Loc.string("%lld of 5", entry.book.stars))
            }
            .width(min: 60, ideal: 70)
            .customizationID(Column.rating.rawValue)

            TableColumn(Loc.string("Tags"), value: \.sortableTags) { entry in
                Text(entry.book.tags.joined(separator: ", "))
                    .foregroundStyle(Slate.textSecondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 160)
            .customizationID(Column.tags.rawValue)

            TableColumn(Loc.string("Format"), value: \.formatLine) { entry in
                Text(entry.formatLine).foregroundStyle(Slate.textSecondary).lineLimit(1)
            }
            .width(min: 60, ideal: 80)
            .customizationID(Column.format.rawValue)

            TableColumn(Loc.string("Added"), value: \.book.addedAt) { entry in
                Text(Self.day(entry.book.addedAt)).foregroundStyle(Slate.textSecondary)
            }
            .width(min: 80, ideal: 100)
            .customizationID(Column.added.rawValue)

            TableColumn(Loc.string("Read"), value: \.sortableRead) { entry in
                Image(systemName: entry.book.isRead ? "checkmark" : "")
                    .foregroundStyle(Slate.textSecondary)
                    .accessibilityLabel(entry.book.isRead ? Loc.string("Read") : Loc.string("Unread"))
            }
            .width(min: 40, ideal: 50)
            .customizationID(Column.read.rawValue)

            TableColumn(Loc.string("Size"), value: \.totalBytes) { entry in
                Text(ByteCount.format(entry.totalBytes))
                    .foregroundStyle(Slate.textSecondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            .customizationID(Column.size.rawValue)

            // Hidden until somebody asks for it. It is not one of the nine
            // columns CONCEPT §3.2 lists, but *Last Changed* is one of the six
            // sort fields — and a sort with no column to point at is a table
            // whose header shows no arrow while the menu says it is sorted.
            TableColumn(Loc.string("Changed"), value: \.book.modifiedAt) { entry in
                Text(Self.day(entry.book.modifiedAt)).foregroundStyle(Slate.textSecondary)
            }
            .width(min: 80, ideal: 100)
            .customizationID(Column.changed.rawValue)
            .defaultVisibility(.hidden)
        } rows: {
            ForEach(model.visible) { entry in
                TableRow(entry)
                    .contextMenu { BookMenu(entry: entry) }
                    .draggable(entry.id.uuidString)
            }
        }
        .tableStyle(.inset)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .grid)
        .background(Slate.contentBackground)
        .onAppear { customization = Self.decode(model.tableColumns) }
        // Saved through the model, which writes `library.json`. SwiftUI mutates
        // the value in place as the user drags a column edge, so this is the
        // only place that can notice.
        .onChange(of: customization) { _, new in model.tableColumns = Self.encode(new) }
    }

    // MARK: Which columns there are

    /// The names SwiftUI stores a column's state under. An enum, because a
    /// typo in one of these strings is a column that silently forgets its width
    /// and its visibility, and nothing else goes wrong.
    private enum Column: String {
        case title, author, series, rating, tags, format, added, read, size, changed
    }

    // MARK: Sorting

    /// The sort the header draws its arrow from: the model's order, translated.
    private var comparators: [KeyPathComparator<LibraryEntry>] {
        let direction: SortOrder = model.order.ascending ? .forward : .reverse
        switch model.order.field {
        case .title: return [KeyPathComparator(\LibraryEntry.book.titleSort, order: direction)]
        case .author: return [KeyPathComparator(\LibraryEntry.sortableAuthor, order: direction)]
        case .series: return [KeyPathComparator(\LibraryEntry.sortableSeries, order: direction)]
        case .rating: return [KeyPathComparator(\LibraryEntry.book.rating, order: direction)]
        case .added: return [KeyPathComparator(\LibraryEntry.book.addedAt, order: direction)]
        case .modified: return [KeyPathComparator(\LibraryEntry.book.modifiedAt, order: direction)]
        case .tags: return [KeyPathComparator(\LibraryEntry.sortableTags, order: direction)]
        case .format: return [KeyPathComparator(\LibraryEntry.formatLine, order: direction)]
        case .read: return [KeyPathComparator(\LibraryEntry.sortableRead, order: direction)]
        case .size: return [KeyPathComparator(\LibraryEntry.totalBytes, order: direction)]
        }
    }

    /// A click on a header, translated back into a `BookOrder` the model can
    /// act on — which re-queries the index.
    ///
    /// A column this table cannot name a `BookSort` for is ignored rather than
    /// sorted in memory — a column that sorted the loaded rows itself would put
    /// the table in one order and leave the grid and the sort menu in another,
    /// and then the window would be claiming two things at once.
    ///
    /// **There are none left.** `Tags`, `Format`, `Read` and `Size` carried no
    /// arrow from Sprint 2c until Sprint 7, because `BookSort` had no case for
    /// them; it has four now and the order comes out of the index like every
    /// other.
    private func adopt(_ wanted: [KeyPathComparator<LibraryEntry>]) {
        guard let first = wanted.first,
            let field = Self.fields.first(where: { $0.path == first.keyPath })?.field
        else { return }
        model.order = BookOrder(field: field, ascending: first.order == .forward)
    }

    /// The one place a column's key path and a `BookSort` are tied together, so
    /// the arrow the header draws and the order the index returns cannot drift
    /// apart. `comparators` reads it one way and `adopt` the other.
    private static let fields: [(path: PartialKeyPath<LibraryEntry>, field: BookSort)] = [
        (\LibraryEntry.book.titleSort, .title),
        (\LibraryEntry.sortableAuthor, .author),
        (\LibraryEntry.sortableSeries, .series),
        (\LibraryEntry.book.rating, .rating),
        (\LibraryEntry.book.addedAt, .added),
        (\LibraryEntry.book.modifiedAt, .modified),
        (\LibraryEntry.sortableTags, .tags),
        (\LibraryEntry.formatLine, .format),
        (\LibraryEntry.sortableRead, .read),
        (\LibraryEntry.totalBytes, .size),
    ]

    // MARK: Formatting

    private static func stars(_ count: Int) -> String {
        String(repeating: "★", count: count) + String(repeating: "☆", count: 5 - count)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: Remembering the columns

    /// SwiftUI's own format, carried through `library.json` as a string.
    ///
    /// Opaque on purpose: it is the framework's structure, and a second
    /// interpretation of it here would be a second thing to keep in step with
    /// something that owns it. A value that cannot be decoded — written by a
    /// newer macOS, or corrupted — gives the default layout rather than an
    /// error, because a forgotten column width is not worth a message.
    private static func decode(_ text: String?) -> TableColumnCustomization<LibraryEntry> {
        guard let text, let data = text.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(TableColumnCustomization<LibraryEntry>.self, from: data)
        else { return TableColumnCustomization<LibraryEntry>() }
        return decoded
    }

    private static func encode(_ value: TableColumnCustomization<LibraryEntry>) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension LibraryEntry {
    /// The surname first, which is what "by author" means in a library.
    /// `authorLine` is what the column *shows*; this is what it sorts by, and
    /// they are different strings on purpose.
    var sortableAuthor: String { AuthorSort.of(book.primaryAuthor) }

    /// Books without a series go last whichever way round the column is
    /// sorted, the same rule the SQL order has — otherwise the table's own
    /// arrow and the index's answer would differ on exactly those rows.
    var sortableSeries: String { book.series?.name ?? "\u{10FFFF}" }

    /// The same string the Tags column draws. The key path is what ties a
    /// column to a `BookSort`; the order itself comes out of the index.
    var sortableTags: String { book.tags.joined(separator: ", ") }

    /// `Bool` is not `Comparable`, and a column needs something that is.
    var sortableRead: Int { book.isRead ? 1 : 0 }
}
