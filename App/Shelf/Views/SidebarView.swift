import ShelfCore
import SlateKit
import SwiftUI

/// The left column: what is open, the smart collections, and one section per
/// way of narrowing the library down (CONCEPT §3.2).
///
/// Every section is drawn even when it is empty – with a line saying why –
/// because a sidebar whose shape changes between versions is harder to learn
/// than one that is whole from the start.
struct SidebarView: View {
    @Environment(LibraryModel.self) private var model
    /// Which name the rename/merge sheet is open on, if any.
    @State private var merging: MergeTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let library = model.library {
                SlateSidebarHeaderRow(library.name, help: library.root.path)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    collections
                    ForEach(SidebarSection.allCases) { section in
                        // Shelves are the one section that can be changed from
                        // here – made, renamed, dropped on – so they have their
                        // own view rather than a fifth case in `rows(for:)`.
                        if section == .shelves {
                            ShelvesSection()
                        } else if section == .devices {
                            // Not a facet list and not a filter: a device row
                            // is a drop target and a thing to eject.
                            DevicesSection()
                        } else {
                            SlateSidebarSection(section.title)
                            rows(for: section)
                        }
                    }
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel(Loc.string("Library sidebar"))
            Rectangle().fill(Slate.separator).frame(height: 1)
            footer
        }
        .background(Slate.panelBackground)
        // A stray drag in the sidebar used to select the text of a row.
        .textSelection(.disabled)
        .sheet(item: $merging) { target in
            MergeNamesSheet(kind: target.kind, startingFrom: target.name)
        }
    }

    // MARK: Smart collections

    private var collections: some View {
        Group {
            SlateSidebarSection(Loc.string("Library"))
            ForEach(SmartCollection.allCases, id: \.self) { collection in
                let available = !Self.stillToCome.contains(collection)
                SlateSidebarRow(
                    Loc.core(collection.title),
                    icon: collection.icon,
                    count: count(of: collection),
                    isActive: model.filter.collection == collection && !isNarrowed,
                    help: available
                        ? Self.help(for: collection)
                        : Loc.string("%@ is not available yet", Loc.core(collection.title)),
                    titleColor: available ? Slate.textPrimary : Slate.textSecondary,
                    // Named, not a trailing closure: SlateKit 0.2.0 gained an
                    // `accessory` view builder before `action`, so a trailing
                    // closure now binds to the accessory instead.
                    action: { _ in
                        guard available else { return }
                        model.filter = LibraryFilter(collection: collection)
                    }
                )
            }
        }
    }

    /// What a collection row says when the pointer rests on it.
    ///
    /// The two duplicate rows name their rule rather than repeating their own
    /// title: side by side, "Duplicates" and "Possible Duplicates" are only
    /// distinguishable by what found them.
    private static func help(for collection: SmartCollection) -> String {
        switch collection {
        case .duplicates:
            return Loc.string("Books that share a file, byte for byte, or an ISBN with another book")
        case .possibleDuplicates:
            return Loc.string(
                "Books that share only a title and a first author — editions, translations and "
                    + "namesakes look like this too")
        default:
            // Not `.lowercased()`. It was, and on a German Mac "Alle Bücher"
            // came out as "alle bücher zeigen": German capitalises its nouns,
            // and a tooltip that lower-cases one is simply misspelt. English
            // reads perfectly well as "Show All Books".
            return Loc.string("Show %@", Loc.core(collection.title))
        }
    }

    /// Every collection can answer now. Kept as a named, empty set rather than
    /// deleted: the sidebar has drawn greyed rows for two sprints, and the next
    /// collection that arrives half-built belongs here rather than in a new
    /// mechanism invented for it.
    private static let stillToCome: Set<SmartCollection> = []

    /// Whether anything beyond the collection is narrowing the view, which is
    /// what decides whether a collection row is drawn as active.
    private var isNarrowed: Bool { model.filter.isNarrowed }

    private func count(of collection: SmartCollection) -> Int? {
        switch collection {
        case .all: return model.totals.all
        case .unread: return model.totals.unread
        case .recentlyAdded: return model.totals.recentlyAdded
        case .missingCover: return model.totals.missingCover
        case .notOnAnyShelf: return model.totals.notOnAnyShelf
        case .duplicates: return model.totals.duplicates
        case .possibleDuplicates: return model.totals.possibleDuplicates
        }
    }

    // MARK: One section

    @ViewBuilder
    private func rows(for section: SidebarSection) -> some View {
        let facets = self.facets(for: section)
        if facets.isEmpty {
            Text(section.emptyNote)
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        } else {
            // Capped, with a line saying how many more there are: a library
            // with 3 000 authors would otherwise make the sidebar a scroll
            // through nothing. The search field is the way to the rest.
            ForEach(facets.prefix(Self.maximumRowsPerSection), id: \.id) { facet in
                SlateSidebarRow(
                    displayName(facet, in: section),
                    icon: Theme.icon(for: section),
                    count: facet.count,
                    isActive: isActive(facet, in: section),
                    help: Loc.string("Show only %@", displayName(facet, in: section)),
                    action: { _ in apply(facet, from: section) }
                )
                .contextMenu { nameCommands(for: facet, in: section) }
            }
            if facets.count > Self.maximumRowsPerSection {
                Text(Loc.count("+ %lld more — use ⌘F", facets.count - Self.maximumRowsPerSection))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        }
    }

    /// How many rows one section may take.
    ///
    /// It was 200, and a screenshot showed what that means: a 120-book library
    /// already has 97 authors, so Series, Formats and Devices sat about a
    /// thousand points below the fold and nobody scrolling past ninety-seven
    /// names would have guessed they were there. A section that cannot be longer
    /// than a screenful keeps every *section* reachable, which is what the
    /// sidebar is for; the search field is the way to an individual name, and
    /// the "+ N more" line says so.
    private static let maximumRowsPerSection = 12

    private func facets(for section: SidebarSection) -> [LibraryIndex.Facet] {
        switch section {
        case .tags: return model.tagFacets
        case .authors: return model.authorFacets
        case .series: return model.seriesFacets
        case .publishers: return model.publisherFacets
        case .formats: return model.formatFacets
        // Drawn by `ShelvesSection`, which reads the tree rather than a facet
        // list: a shelf exists whether or not a book stands on it.
        case .shelves, .devices: return []
        }
    }

    /// `Rename…` and `Merge into…` on a name the library shares between books.
    ///
    /// Formats have neither: `EPUB` is not a spelling somebody chose, it is
    /// what the file is. Shelves have their own menu already, in
    /// `ShelvesSection` — a shelf is not metadata on a book in the same way.
    @ViewBuilder
    private func nameCommands(for facet: LibraryIndex.Facet, in section: SidebarSection) -> some View {
        if let kind = Self.kind(of: section) {
            Button(Loc.string("Rename “%@”…", facet.name)) {
                merging = MergeTarget(kind: kind, name: facet.name)
            }
            Button(Loc.string("Merge into…")) {
                merging = MergeTarget(kind: kind, name: facet.name)
            }
        }
    }

    /// Which sidebar sections list a name that can be renamed.
    static func kind(of section: SidebarSection) -> NameKind? {
        switch section {
        case .tags: return .tag
        case .authors: return .author
        case .series: return .series
        case .publishers: return .publisher
        case .formats, .shelves, .devices: return nil
        }
    }

    /// What the merge sheet is open on. One value, so the sheet cannot be half
    /// configured.
    struct MergeTarget: Identifiable {
        let kind: NameKind
        let name: String
        var id: String { "\(kind.rawValue)/\(name)" }
    }

    /// What the row reads. It is not always `facet.name`: a format's facet name
    /// is the value in the index (`epub`), which is an identifier and is what
    /// `apply` turns back into a `BookFileFormat` – but a person reads "EPUB",
    /// and the inspector two columns to the right has always written it that way.
    private func displayName(_ facet: LibraryIndex.Facet, in section: SidebarSection) -> String {
        switch section {
        case .formats: return BookFileFormat(rawValue: facet.name)?.label ?? facet.name.uppercased()
        case .tags, .authors, .series, .publishers, .shelves, .devices: return facet.name
        }
    }

    private func isActive(_ facet: LibraryIndex.Facet, in section: SidebarSection) -> Bool {
        switch section {
        case .tags: return model.filter.tag == facet.name
        case .authors: return model.filter.author == facet.name
        case .series: return model.filter.series == facet.name
        case .publishers: return model.filter.publisher == facet.name
        case .formats: return model.filter.format?.rawValue == facet.name
        case .shelves, .devices: return false
        }
    }

    /// Clicking a row shows that one thing. Combining several is what Sprint 2
    /// adds, so this replaces rather than narrows – and says so in the help.
    private func apply(_ facet: LibraryIndex.Facet, from section: SidebarSection) {
        var filter = LibraryFilter(collection: model.filter.collection, searchText: model.filter.searchText)
        switch section {
        case .tags: filter.tag = facet.name
        case .authors: filter.author = facet.name
        case .series: filter.series = facet.name
        case .publishers: filter.publisher = facet.name
        case .formats: filter.format = BookFileFormat(rawValue: facet.name)
        case .shelves, .devices: return
        }
        model.filter = filter
    }

    // MARK: Footer

    /// What the machine is busy with. It appears while there is work and
    /// disappears when there is none – it never says "done".
    @ViewBuilder
    private var footer: some View {
        if let progress = model.warmer.progress {
            SlateStatusBar(progress.label)
        } else if model.isLoading {
            SlateStatusBar(Loc.string("Reading the library"))
        } else if let note = model.onlineMetadata?.briefNote {
            // A service that did not answer is a line here and nowhere else:
            // never a dialogue, never a stop (CONCEPT §9). Click to dismiss.
            Text(note)
                .font(.caption2)
                .foregroundStyle(Slate.accent)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture { model.onlineMetadata?.clearNote() }
                .help(Loc.string("%@ Click to dismiss", model.onlineMetadata?.note ?? note))
                .accessibilityLabel(Loc.string("Network note: %@", note))
        } else {
            Text(model.statusLine)
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
