import Foundation

/// "Write into the Book File" — Schritt E2's core, no window in it.
///
/// Plan, then run, the same two-step shape `OrganizePlan`/`TransferRunner`
/// already use, for the same reason (ADR 0002, decision 6): the plan a
/// person reads in the confirmation sheet is the exact plan `run` carries
/// out, computed once, never recomputed between the two — a field could
/// otherwise change under the sheet's feet between "shown" and "written".
///
/// `docs/adr/0021-…` decided this may happen at all; `EPUBFileReplacement`
/// is the file-level mechanics (preflight, the swap, the Trash). This type
/// is what sits between a `LibraryEntry` and that: which fields differ,
/// which of them can actually be written, and the bytes to write if the
/// person says so.
public enum EPUBWrite {

    // MARK: The plan — nothing written yet

    /// One field `EPUBOPFPatch` can change, and what the book's own file
    /// currently holds beside what Shelf would write into it.
    public struct FieldChange: Equatable, Sendable {
        public enum Field: String, CaseIterable, Sendable {
            case title, authors, publisher, published, language, description
        }
        public var field: Field
        public var before: String
        public var after: String
        /// `false` when this field's name is in `BookPlan.unwritten` — the
        /// sheet marks it, rather than silently leaving it off the list the
        /// way the old "never invents structure" behaviour once did
        /// (`CHANGELOG.md`, Sprint 10 part 2).
        public var willBeWritten: Bool
        public var changed: Bool { before != after }

        public init(field: Field, before: String, after: String, willBeWritten: Bool) {
            self.field = field
            self.before = before
            self.after = after
            self.willBeWritten = willBeWritten
        }
    }

    /// What replacing one book's EPUB would do — computed once, from the
    /// file as it stands right now, and handed unchanged to `run`.
    public struct BookPlan: Identifiable, Equatable, Sendable {
        public var id: UUID { entryID }
        public var entryID: UUID
        public var title: String
        public var fileName: String
        public var changes: [FieldChange]
        /// Fields `EPUBOPFPatch` could not place, by name — `["title"]`
        /// when the book had none and none is ever invented, and so on.
        public var unwritten: [String]
        /// The finished bytes `run` writes if this plan is confirmed —
        /// computed here so what was shown and what gets written can never
        /// drift apart.
        let newContent: Data
    }

    /// Why a book has no plan at all — decided before a sheet is ever shown
    /// for it, the same preflight `EPUBFileReplacement.replace` itself
    /// would make.
    public enum PlanFailure: Error, Equatable, Sendable {
        /// No EPUB among this book's formats. Only EPUBs are ever written
        /// into (`docs/adr/0021-…`); PDF, MOBI and AZW3 are always left
        /// alone.
        case noEPUB
        case refused(EPUBFileReplacement.Refusal)
        /// Shelf's author list for this book does not have the same count
        /// as the `dc:creator` elements already in the file. Adding or
        /// removing an author is out of scope on purpose
        /// (`EPUBOPFPatch.Failure.authorCountMismatch`) — refused rather
        /// than guessed.
        case authorCountMismatch(existing: Int, new: Int)
        case cannotPrepare(String)
    }

    /// Computes what would change for one entry's EPUB. Reads the file,
    /// writes nothing. `EPUBFileReplacement.preflight` runs first, so a
    /// DRM-protected book or one on a read-only volume is refused here,
    /// before any sheet is shown for it.
    public static func plan(for entry: LibraryEntry, library: Library) -> Swift.Result<BookPlan, PlanFailure> {
        guard let epub = entry.formats.first(where: { $0.format == .epub }) else {
            return .failure(.noEPUB)
        }
        let folder = library.root.appendingPathComponent(entry.folder, isDirectory: true)
        let url = folder.appendingPathComponent(epub.fileName)

        do {
            try EPUBFileReplacement.preflight(url)
        } catch let refusal as EPUBFileReplacement.Refusal {
            return .failure(.refused(refusal))
        } catch {
            return .failure(.cannotPrepare(error.localizedDescription))
        }

        do {
            let data = try Data(contentsOf: url)
            let archive = try ZipReader(data: data)
            let before = EPUBMetadata.read(archive, fallbackTitle: epub.fileName).book
            let after = entry.book

            let fields = EPUBOPFPatch.Fields(
                title: after.title, authors: after.authors.isEmpty ? nil : after.authors,
                language: after.language, publisher: after.publisher, published: after.published,
                description: after.description)
            let patched = try EPUBOPFPatch.entries(patching: fields, in: archive, now: Date())
            let newContent = try EPUBArchiveWriter.archive(patched.entries)

            let plan = BookPlan(
                entryID: entry.book.id, title: after.title, fileName: epub.fileName,
                changes: Self.changes(before: before, after: after, unwritten: patched.unwritten),
                unwritten: patched.unwritten, newContent: newContent)
            return .success(plan)
        } catch EPUBOPFPatch.Failure.authorCountMismatch(let existing, let new) {
            return .failure(.authorCountMismatch(existing: existing, new: new))
        } catch {
            return .failure(.cannotPrepare(String(describing: error)))
        }
    }

    /// Every entry, planned — the books that can be written, and the ones
    /// that cannot, by name and by reason. Never a partial plan silently
    /// dropping a book: what cannot be prepared is named so the sheet can
    /// show it, the same way `OrganizePlan.blocked` names what an organise
    /// cannot move.
    public struct Plan: Equatable, Sendable {
        public struct Skipped: Equatable, Sendable {
            public var title: String
            public var failure: PlanFailure
        }
        public var books: [BookPlan]
        public var skipped: [Skipped]
    }

    public static func plan(for entries: [LibraryEntry], library: Library) -> Plan {
        var books: [BookPlan] = []
        var skipped: [Plan.Skipped] = []
        for entry in entries {
            switch Self.plan(for: entry, library: library) {
            case .success(let plan): books.append(plan)
            case .failure(let failure): skipped.append(.init(title: entry.book.title, failure: failure))
            }
        }
        return Plan(books: books, skipped: skipped)
    }

    /// Whether this book is even worth offering the command for — no disk
    /// access, just what the index already knows. The real, disk-backed
    /// refusal is `plan(for:library:)`'s preflight; this is only what gates
    /// a menu item from being shown for a book that plainly does not
    /// qualify.
    public static func isEligible(_ entry: LibraryEntry) -> Bool {
        entry.formats.contains { $0.format == .epub && $0.drm == nil }
    }

    private static func changes(before: Book, after: Book, unwritten: [String]) -> [FieldChange] {
        func text(_ date: Date?) -> String {
            guard let date else { return "" }
            return Self.dateFormatter.string(from: date)
        }
        func make(_ field: FieldChange.Field, _ before: String, _ after: String, key: String) -> FieldChange {
            FieldChange(field: field, before: before, after: after, willBeWritten: !unwritten.contains(key))
        }
        return [
            make(.title, before.title, after.title, key: "title"),
            make(
                .authors, before.authors.joined(separator: ", "), after.authors.joined(separator: ", "),
                key: "authors"),
            make(.publisher, before.publisher ?? "", after.publisher ?? "", key: "publisher"),
            make(.published, text(before.published), text(after.published), key: "published"),
            make(.language, before.language ?? "", after.language ?? "", key: "language"),
            make(.description, before.description ?? "", after.description ?? "", key: "description"),
        ]
    }

    /// A plain calendar day, the same shape `EPUBOPFPatch` writes into
    /// `dc:date` — no time, no zone drift between what the sheet shows and
    /// what lands in the file.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: Writing — sequential, never concurrent

    public struct Progress: Equatable, Sendable {
        public var done: Int
        public var total: Int
        public var currentTitle: String

        public init(done: Int, total: Int, currentTitle: String) {
            self.done = done
            self.total = total
            self.currentTitle = currentTitle
        }
    }

    public struct BookOutcome: Equatable, Sendable {
        public enum Result: Equatable, Sendable {
            case wrote
            case failed(String)
        }
        public var entryID: UUID
        public var title: String
        public var result: Result
    }

    public struct Report: Equatable, Sendable {
        public var outcomes: [BookOutcome]
        public var succeeded: Int {
            outcomes.filter {
                if case .wrote = $0.result { return true }
                return false
            }.count
        }
    }

    /// Writes every plan's already-computed bytes into its own book, one
    /// book at a time. Never a `TaskGroup`, never `async let` — the same
    /// rule `EPUBFileReplacement`'s own doc comment states for a caller
    /// replacing several books' files, restated here because this is that
    /// caller: at 24 MB and 187 entries for a real, illustrated EPUB, the
    /// peak memory a run of these costs is one book's, not the whole
    /// batch's.
    public static func run(
        _ plans: [BookPlan], entries: [UUID: LibraryEntry], library: Library, index: LibraryIndex,
        disposal: FolderDisposal = .trash, progress: @Sendable (Progress) -> Void = { _ in }
    ) async -> Report {
        var outcomes: [BookOutcome] = []
        for (offset, plan) in plans.enumerated() {
            progress(Progress(done: offset, total: plans.count, currentTitle: plan.title))
            guard let entry = entries[plan.entryID] else {
                outcomes.append(
                    BookOutcome(entryID: plan.entryID, title: plan.title, result: .failed("no longer in the library")))
                continue
            }
            do {
                let commit = try await EPUBFileReplacement.commit(
                    plan.newContent, to: entry, library: library, index: index, disposal: disposal)
                switch commit {
                case .wrote:
                    outcomes.append(BookOutcome(entryID: plan.entryID, title: plan.title, result: .wrote))
                case .refused(let refusal):
                    outcomes.append(
                        BookOutcome(entryID: plan.entryID, title: plan.title, result: .failed(refusal.message)))
                }
            } catch {
                outcomes.append(
                    BookOutcome(entryID: plan.entryID, title: plan.title, result: .failed(String(describing: error))))
            }
        }
        progress(Progress(done: plans.count, total: plans.count, currentTitle: ""))
        return Report(outcomes: outcomes)
    }
}
