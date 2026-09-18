import AppKit
import Foundation
import Quartz
import ShelfCore

/// Quick Look on the space bar (CONCEPT §3.3).
///
/// What it shows, and why it is not simply "hand the book file to Quick Look":
///
/// * A **PDF** and a **comic** are handed over as they are. Quick Look renders
///   a PDF properly, pages and all, and a CBZ it will at least show as an
///   archive — and for both of them the file *is* what the person wants to see.
/// * An **EPUB, MOBI or AZW3** is not. macOS has no Quick Look generator for
///   any of them, so handing one over draws a grey icon with a file name under
///   it, which is worse than nothing. For these Shelf previews **the cover it
///   already has on disk** (`cover.png` next to the book), which is the picture
///   the person is actually looking for.
///
/// Nothing is written and nothing is converted. The cover shown is the file
/// already sitting in the book's folder; no temporary copy of a book is ever
/// made.
@MainActor
final class QuickLookPreview: NSObject {

    /// The formats macOS itself previews usefully. Reference data: a row, not a
    /// branch, and the row is the claim being made about each format.
    static let previewedByTheSystem: Set<BookFileFormat> = [.pdf, .cbz, .cbr]

    /// What is currently being shown. One item, because the panel previews the
    /// selected book and the selection's *first* book when there are several —
    /// a space bar over twenty books is a question about one of them.
    private var url: URL?

    static let shared = QuickLookPreview()

    /// Shows, or hides if it is already showing this book.
    ///
    /// The space bar toggles, the way it does in the Finder and in Selector.
    func toggle(_ entry: LibraryEntry, in library: Library) {
        guard let panel = QLPreviewPanel.shared() else { return }
        let wanted = Self.previewURL(for: entry, in: library)

        if panel.isVisible, url == wanted {
            panel.orderOut(nil)
            return
        }
        guard let wanted else {
            NSSound.beep()
            return
        }
        url = wanted
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        url = nil
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    /// The file Quick Look is given: the book itself for the formats macOS
    /// previews, and otherwise the cover already extracted next to it.
    ///
    /// `nil` when there is neither — a book whose file is gone and which never
    /// had a cover. The space bar then beeps rather than opening an empty
    /// panel, because an empty panel looks like a bug.
    static func previewURL(for entry: LibraryEntry, in library: Library) -> URL? {
        let folder = library.root.appendingPathComponent(entry.folder, isDirectory: true)

        // The best format the system can show, by the same preference order
        // everything else uses.
        let showable = entry.formats
            .filter { previewedByTheSystem.contains($0.format) }
            .sorted { $0.format < $1.format }
            .first
        if let showable {
            let url = folder.appendingPathComponent(showable.fileName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return CoverFile.url(in: folder)
    }
}

/// `QLPreviewPanelDataSource` is not main-actor annotated, so a `@MainActor`
/// type cannot conform to it under strict concurrency without saying something
/// about where the calls arrive.
///
/// They arrive on the main thread: `QLPreviewPanel` is AppKit, and AppKit
/// dispatches to the main thread and nowhere else. `assumeIsolated` states that
/// rather than assuming it quietly — the same shape `EditingKeyMonitor` uses
/// for `NSEvent`'s monitor block, and for the same reason.
extension QuickLookPreview: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        // The `URL` comes out of the isolated block and the cast happens
        // outside it: `assumeIsolated` hands back only `Sendable` values, and
        // `any QLPreviewItem` is not one. A `URL` is.
        let item: URL? = MainActor.assumeIsolated { url }
        return item as (any QLPreviewItem)?
    }
}
