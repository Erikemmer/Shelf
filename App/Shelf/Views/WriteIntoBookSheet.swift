import ShelfCore
import SlateKit
import SwiftUI

/// `Write into the Book File…` — the one place the rule that a book file is
/// never written gives way, and only after this sheet
/// (`docs/adr/0021-metadata-and-a-cover-may-be-written-into-an-epub.md`).
///
/// The same two-step shape `OrganizeSheet` has, for the same reason: nothing
/// changes until the plan somebody has read is handed back to `run`
/// unchanged, so the list agreed to and the work that happens cannot differ
/// (ADR 0002, decision 6). Three things this sheet is not allowed to do
/// quietly: it never summarises the list of fields, it never invents a
/// title or an author, and it never lets PDF, MOBI or AZW3 anywhere near a
/// write.
struct WriteIntoBookSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Ticked by hand before the button does anything — the same second
    /// deliberate act `DeleteFromDeviceSheet` asks for its one irreversible
    /// thing. This is Shelf's other one: no ⌘Z, the Trash is the way back.
    @State private var hasUnderstood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Loc.string("Write into the Book File"))
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            switch model.epubWritePhase {
            case .planning, .none:
                planning
            case .ready(let plan):
                preview(plan)
            case .running(let progress):
                running(progress)
            case .done(let report):
                finished(report)
            }

            buttons
        }
        .padding(20)
        .frame(width: 640)
        .background(Slate.windowBackground)
    }

    // MARK: States

    private var planning: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView().progressViewStyle(.linear)
            Text(Loc.string("Working out what would change in each book's own file. Nothing is written yet."))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    @ViewBuilder
    private func preview(_ plan: EPUBWrite.Plan) -> some View {
        if plan.books.isEmpty && plan.skipped.isEmpty {
            Text(Loc.string("Nothing is selected.")).foregroundStyle(Slate.textSecondary)
        } else if plan.books.isEmpty {
            Text(Loc.string("None of this can be written into.")).foregroundStyle(Slate.textPrimary)
            skippedSection(plan.skipped)
        } else if Self.changingCount(plan) == 0 {
            summaryLine(plan)
            // Every book in the plan is eligible, but none of them would
            // actually change — every field is either already the same or
            // one `EPUBOPFPatch` cannot place. Offering the write anyway
            // would still move a hashed, verified original to the Trash and
            // rewrite it for no difference at all: the one accidental write
            // ADR 0021 exists to prevent, so this state says so instead of
            // pretending there is something to confirm.
            Text(Loc.string("Nothing to write")).foregroundStyle(Slate.textPrimary)
            Text(Self.nothingToWriteSentence(bookCount: plan.books.count))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            bookList(plan)
        } else {
            summaryLine(plan)
            Text(Loc.count("%lld books will have their EPUB file replaced.", Self.changingCount(plan)))
                .foregroundStyle(Slate.textPrimary)
            Text(
                Loc.string(
                    "Only the EPUB file is written to. PDF, MOBI and AZW3 stay exactly as they are. "
                        + "Each book's current EPUB file moves to the Trash — not gone for good, but "
                        + "⌘Z will not bring it back. Anyone who needs it can get it back from the "
                        + "Trash themselves.")
            )
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            bookList(plan)

            Toggle(Loc.string("I have read the list above"), isOn: $hasUnderstood)
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    /// The three numbers Sprint 23 added at the top of the sheet: how many
    /// of this selection would actually get a new file, how many are
    /// already exactly what Shelf would write, and how many cannot be
    /// written at all — each read back from the very plan the list below
    /// shows, never a separate count that could disagree with it.
    private func summaryLine(_ plan: EPUBWrite.Plan) -> some View {
        let toWrite = Self.changingCount(plan)
        let alreadySame = plan.books.count - toWrite
        let cannotWrite = plan.skipped.count
        return HStack(spacing: 4) {
            Text(Loc.count("%lld to write", toWrite))
            Text("·").foregroundStyle(Slate.textSecondary)
            Text(Loc.count("%lld already the same", alreadySame))
            Text("·").foregroundStyle(Slate.textSecondary)
            Text(Loc.count("%lld cannot be written", cannotWrite))
        }
        .font(.caption)
        .foregroundStyle(Slate.textSecondary)
        .accessibilityElement(children: .combine)
    }

    /// Every book, in full — a list that only shows the first few is a list
    /// somebody agrees to without having read.
    private func bookList(_ plan: EPUBWrite.Plan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(plan.books) { bookSection($0) }
                if !plan.skipped.isEmpty { skippedSection(plan.skipped) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
        .accessibilityLabel(Loc.string("Books that will be written into"))
    }

    /// How many of `plan.books` would actually be written — the sheet's own
    /// "already the same" / "cannot be written" tags, read back, never a
    /// separate count that could disagree with what the list shows.
    private static func changingCount(_ plan: EPUBWrite.Plan) -> Int {
        plan.books.filter(\.hasChange).count
    }

    /// One sentence, singular for the common case (one book selected, one
    /// book that would not change) and counted otherwise — the same "%lld"
    /// shape every other counted sentence in this sheet uses.
    private static func nothingToWriteSentence(bookCount: Int) -> String {
        bookCount == 1
            ? Loc.string("This EPUB file would not change.")
            : Loc.count("%lld books would not get a new EPUB file.", bookCount)
    }

    private func running(_ progress: EPUBWrite.Progress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(
                value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
            )
            .progressViewStyle(.linear)
            Text(Loc.string("%1$@ of %2$@ · %3$@", "\(progress.done)", "\(progress.total)", progress.currentTitle))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(1)
            HStack {
                Spacer()
                if model.epubWriteStopRequested {
                    Text(Loc.string("Stopping after this book…"))
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                } else {
                    Button(Loc.string("Stop After This Book")) { model.stopEPUBWrite() }
                        .font(.caption)
                }
            }
        }
    }

    private func finished(_ report: EPUBWrite.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Loc.count("%lld books were written into.", report.succeeded))
                .foregroundStyle(Slate.textPrimary)
            HStack(spacing: 4) {
                Text(Loc.count("%lld already the same", report.noChange))
                if report.failed > 0 {
                    Text("·").foregroundStyle(Slate.textSecondary)
                    Text(Loc.count("%lld failed", report.failed))
                }
                if report.notAttempted > 0 {
                    Text("·").foregroundStyle(Slate.textSecondary)
                    Text(Loc.count("%lld not attempted", report.notAttempted))
                }
            }
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)
            if !report.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                            Text(verbatim: "\(failure.title): \(failure.reason)")
                                .font(.caption2)
                                .foregroundStyle(Slate.accent)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            if report.notAttempted > 0 {
                Text(
                    report.failed > 0
                        ? Loc.string("Stopped after a failure — the books after it were left untouched.")
                        : Loc.string("Stopped at your own request — the books after it were left untouched.")
                )
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
            }
            if report.succeeded > 0 {
                Text(Loc.string("No ⌘Z for this. Each original is in the Trash and can be dragged back from there."))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                if let library = model.library {
                    Text(Loc.string("A record of every change is in “%@”.", EPUBWriteManifest.url(in: library).path))
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: One book, one field

    private func bookSection(_ plan: EPUBWrite.BookPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(plan.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Slate.textPrimary)
                // Shown in the same list rather than moved to "Left alone":
                // this book has a plan, and every field in it is readable —
                // it is only that none of them would actually change
                // anything, so `run` never touches it either.
                if !plan.hasChange {
                    Text(Loc.string("Left alone — nothing would change"))
                        .font(.caption2)
                        .foregroundStyle(Slate.accent)
                }
            }
            Text(plan.fileName)
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ForEach(plan.changes, id: \.field) { fieldRow($0) }
            coverRow(plan.cover)
        }
        .textSelection(.enabled)
    }

    /// The cover, in the same "label, then old → new" shape every field row
    /// has — described in words rather than shown as a picture, since a
    /// sheet comparing two images without showing either one is what
    /// `docs/adr/0021-…` asks for. No row at all when Shelf has no cover of
    /// its own to offer (`plan.cover.afterBytes == nil`): there is nothing
    /// to compare and nothing that could be written, the same way a field
    /// this book's format cannot hold is simply not on the list.
    @ViewBuilder
    private func coverRow(_ cover: EPUBWrite.CoverPlan) -> some View {
        if let afterBytes = cover.afterBytes {
            HStack(alignment: .top, spacing: 6) {
                Text(Loc.string("Cover"))
                    .font(.caption)
                    .foregroundStyle(Slate.textSecondary)
                    .frame(width: 78, alignment: .leading)
                Self.coverValueText(before: cover.beforeBytes, after: afterBytes, changed: cover.changed)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if !cover.changed {
                    Text(Loc.string("already the same"))
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.coverAccessibilityLabel(cover))
        }
    }

    /// The cover's own "old value → new value" text: a description of what
    /// is already in the book (`"Kein Cover im Buch"` when it has none) and,
    /// when it would change, an arrow to a description of what would be
    /// written — the same shape `valueText(for:)` gives a text field, with
    /// image bytes described in words (`CoverImage.describe`) rather than
    /// shown, since the core never decodes a pixel and this sheet does not
    /// either.
    private static func coverValueText(before: Data?, after: Data, changed: Bool) -> Text {
        let afterText = CoverImage.describe(after)
        guard changed else {
            return Text(afterText).foregroundStyle(Slate.textSecondary)
        }
        let beforeText = before.map(CoverImage.describe) ?? Loc.string("No cover in the book")
        return Text(beforeText).foregroundStyle(Slate.textSecondary)
            + Text(Self.arrowToNewValue).foregroundStyle(Slate.textSecondary)
            + Text(afterText).foregroundStyle(Slate.textPrimary)
    }

    private static func coverAccessibilityLabel(_ cover: EPUBWrite.CoverPlan) -> String {
        let field = Loc.string("Cover")
        guard let afterBytes = cover.afterBytes else { return "" }
        if !cover.changed {
            return Loc.string("%@ is already the same", field)
        }
        let before = cover.beforeBytes.map(CoverImage.describe) ?? Loc.string("No cover in the book")
        return Loc.string("%1$@ changes from %2$@ to %3$@", field, before, CoverImage.describe(afterBytes))
    }

    private func fieldRow(_ change: EPUBWrite.FieldChange) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(Loc.label(for: change.field))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
                .frame(width: 78, alignment: .leading)
            Self.valueText(for: change)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            // Marked here, never dropped: a field Shelf cannot place still
            // belongs on this list (Sprint 10 part 2's own lesson).
            if !change.willBeWritten {
                Text(Loc.string("cannot be written"))
                    .font(.caption2)
                    .foregroundStyle(Slate.accent)
            } else if !change.changed {
                Text(Loc.string("already the same"))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: change))
    }

    /// One field, one line: `old → new` when it would actually be written,
    /// a single value when it would not — "already the same" and "cannot be
    /// written" never show two lines with nothing to tell them apart, which
    /// is what a field the file has no element for used to look like: its
    /// "old" value came from the same file-name guess Shelf's own import
    /// uses, so it read back identical to Shelf's value with nothing to
    /// explain why the row was marked unwritable at all.
    private static func valueText(for change: EPUBWrite.FieldChange) -> Text {
        guard change.willBeWritten, change.changed else {
            let value = change.after.isEmpty ? Loc.string("Not set") : change.after
            return Text(value).foregroundStyle(Slate.textSecondary)
        }
        let before = change.before.isEmpty ? Loc.string("Not set") : change.before
        return Text(before).foregroundStyle(Slate.textSecondary)
            + Text(Self.arrowToNewValue).foregroundStyle(Slate.textSecondary)
            + Text(change.after).foregroundStyle(Slate.textPrimary)
    }

    /// The arrow between an old value and a new one, with a non-breaking
    /// space glued to the new value so a wrap only ever falls inside the old
    /// value or the new one — never between the arrow and what it points
    /// at. Built from `Unicode.Scalar` rather than a `"→\u{00A0}"` literal:
    /// `LocalisationTests` reads an escape's own hex digits as English
    /// prose (they are letters), and this is punctuation, not a sentence.
    private static let arrowToNewValue =
        " " + String(Unicode.Scalar(0x2192)!) + String(Unicode.Scalar(0x00A0)!)

    private static func accessibilityLabel(for change: EPUBWrite.FieldChange) -> String {
        let field = Loc.label(for: change.field)
        if !change.willBeWritten {
            return Loc.string("%@ cannot be written", field)
        }
        if !change.changed {
            return Loc.string("%@ is already the same", field)
        }
        let before = change.before.isEmpty ? Loc.string("nothing") : change.before
        return Loc.string("%1$@ changes from %2$@ to %3$@", field, before, change.after)
    }

    /// What it cannot touch, by book and by reason. Never folded into a
    /// count: "3 skipped" is exactly the three titles somebody wants named.
    private func skippedSection(_ skipped: [EPUBWrite.Plan.Skipped]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Loc.string("Left alone"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Slate.accent)
                .padding(.bottom, 2)
            ForEach(Array(skipped.enumerated()), id: \.offset) { _, item in
                Text(verbatim: "\(item.title): \(Loc.message(for: item.failure))")
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            Button(isFinished ? Loc.string("Close") : Loc.string("Cancel")) {
                model.epubWritePhase = nil
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if case .ready(let plan) = model.epubWritePhase, !plan.books.isEmpty {
                let cannotWriteYet = !hasUnderstood || Self.changingCount(plan) == 0
                Button(Loc.string("Write into the Book File")) { model.runEPUBWrite(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cannotWriteYet)
                    // `.disabled` alone does not visibly dim this button
                    // against Slate's own colours — checked against a
                    // screenshot, not assumed: side by side with the
                    // enabled state, the two were the same blue. The
                    // opacity drop is what actually tells a reader the
                    // button does nothing right now.
                    .opacity(cannotWriteYet ? 0.4 : 1)
            }
        }
    }

    private var isFinished: Bool {
        if case .done = model.epubWritePhase { return true }
        return false
    }
}
