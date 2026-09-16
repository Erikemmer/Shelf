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
                        SlateSidebarSection(section.rawValue)
                        rows(for: section)
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
                let available = SmartCollection.availableInSprintOne.contains(collection)
                SlateSidebarRow(
                    collection.title,
                    icon: collection.icon,
                    count: count(of: collection),
                    isActive: model.filter.collection == collection && !isNarrowed,
                    help: available
                        ? "Show \(collection.title.lowercased())"
                        : "\(collection.title) needs the metadata editor – Sprint 2",
                    titleColor: available ? Slate.textPrimary : Slate.textSecondary
                ) { _ in
                    guard available else { return }
                    model.filter = LibraryFilter(collection: collection)
                }
            }
        }
    }

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
            ForEach(facets.prefix(Self.maximumRows), id: \.id) { facet in
                SlateSidebarRow(
                    facet.name,
                    icon: Theme.icon(for: section),
                    count: facet.count,
                    isActive: isActive(facet, in: section),
                    help: "Show only \(facet.name)"
                ) { _ in
                    apply(facet, from: section)
                }
            }
            if facets.count > Self.maximumRows {
                Text("+ \(facets.count - Self.maximumRows) more — use ⌘F")
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
        }
    }

    private static let maximumRows = 200

    private func facets(for section: SidebarSection) -> [LibraryIndex.Facet] {
        switch section {
        case .tags: return model.tagFacets
        case .authors: return model.authorFacets
        case .series: return model.seriesFacets
        case .formats: return model.formatFacets
        case .shelves, .devices: return []
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
