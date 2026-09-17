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
                        } else {
                            SlateSidebarSection(section.rawValue)
                            rows(for: section)
                        }
                    }
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Slate.separator).frame(height: 1)
            footer
        }
        .background(Slate.panelBackground)
        // A stray drag in the sidebar used to select the text of a row.
        .textSelection(.disabled)
    }

    // MARK: Smart collections

    private var collections: some View {
        Group {
            SlateSidebarSection("Library")
            ForEach(SmartCollection.allCases, id: \.self) { collection in
                let available = !Self.stillToCome.contains(collection)
                SlateSidebarRow(
                    collection.title,
                    icon: collection.icon,
                    count: count(of: collection),
                    isActive: model.filter.collection == collection && !isNarrowed,
                    help: available
                        ? "Show \(collection.title.lowercased())"
                        // Named by the sprint that brings it, and that sprint is
                        // no longer this one: "needs the metadata editor –
                        // Sprint 2" was written in Sprint 1 and read during
                        // Sprint 2, where it is not an answer. Duplicates needs
                        // the duplicate query and Not on any Shelf needs
                        // shelves; both are 2c.
                        : "\(collection.title) arrives later in Sprint 2c",
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

    /// The collections that cannot answer yet. Drawn and greyed rather than
    /// hidden: a sidebar whose shape changes between versions is harder to
    /// learn than one that is whole from the start.
    private static let stillToCome: Set<SmartCollection> = [.duplicates]

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
        // Needs the duplicate query Sprint 2 adds; a wrong number would be
        // worse than none.
        case .duplicates: return nil
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
                    help: "Show only \(displayName(facet, in: section))",
                    action: { _ in apply(facet, from: section) }
                )
            }
            if facets.count > Self.maximumRowsPerSection {
                Text("+ \(facets.count - Self.maximumRowsPerSection) more — use ⌘F")
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
        case .formats: return model.formatFacets
        // Drawn by `ShelvesSection`, which reads the tree rather than a facet
        // list: a shelf exists whether or not a book stands on it.
        case .shelves, .devices: return []
        }
    }

    /// What the row reads. It is not always `facet.name`: a format's facet name
    /// is the value in the index (`epub`), which is an identifier and is what
    /// `apply` turns back into a `BookFileFormat` – but a person reads "EPUB",
    /// and the inspector two columns to the right has always written it that way.
    private func displayName(_ facet: LibraryIndex.Facet, in section: SidebarSection) -> String {
        switch section {
        case .formats: return BookFileFormat(rawValue: facet.name)?.label ?? facet.name.uppercased()
        case .tags, .authors, .series, .shelves, .devices: return facet.name
        }
    }

    private func isActive(_ facet: LibraryIndex.Facet, in section: SidebarSection) -> Bool {
        switch section {
        case .tags: return model.filter.tag == facet.name
        case .authors: return model.filter.author == facet.name
        case .series: return model.filter.series == facet.name
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
            SlateStatusBar("Reading the library")
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
