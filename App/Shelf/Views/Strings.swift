import Foundation
import ShelfCore

/// The one door every word in the window goes through.
///
/// Shelf ships English and German (CONCEPT §3.4). Both live in
/// `App/Shelf/Resources/Localizable.xcstrings`, keyed by the English sentence
/// itself — so the source still reads as the sentence a person sees, and a
/// missing translation falls back to that sentence rather than to a key.
///
/// **Everything drawn goes through here, including the plain literals.** SwiftUI
/// would have localised a bare `Text("Add Books…")` on its own, and relying on
/// that was the first plan. Two things killed it:
///
/// - `Text("one " + "two")` is a `String`, not a `LocalizedStringKey`, so it is
///   drawn **verbatim and never translated**. Shelf's help texts are whole
///   sentences and a dozen of them are written across two lines with a `+`.
///   They would have stayed English in a German window, silently, and no test
///   could have seen it: the source looks exactly like the ones that work.
/// - An interpolated key is built by the compiler out of the interpolation's
///   *types* — `Text("Book \(n) of \(m)")` has the key `%1$lld of %2$lld` —
///   which is a key nobody can read off the source, so no test can check that
///   the catalogue holds it.
///
/// Going through a function makes both impossible: the key is a plain literal
/// that `LocalisationTests` reads off the source and looks up, and a value is a
/// printf argument rather than part of the key.
///
/// ShelfCore is not part of this. It is UI-free and Linux-buildable — no
/// bundle, no catalogue, no locale ([ADR 0016](../../docs/adr/0016-the-core-answers-in-english-the-window-translates.md)).
/// It answers in English, the language every identifier in this project is in,
/// and `core` looks that English up here.
enum Loc {
    /// A sentence with nothing in it.
    static func string(_ english: String) -> String {
        Bundle.main.localizedString(forKey: english, value: english, table: nil)
    }

    /// A sentence with a value in it: `Loc.string("%@ free", size)`.
    ///
    /// `localizedStringWithFormat` rather than `String(format:)`, for two
    /// reasons. It formats in the reader's locale — the Selector lesson in the
    /// one place it can still bite, because a German Mac writes 64,4 and a
    /// program that formats without a locale writes 64.4 next to it. And it is
    /// the call that resolves a catalogue's **plural variations**, so
    /// `"%lld folders"` can be one word in English and two in German.
    ///
    /// Three overloads rather than one variadic function, because a variadic
    /// parameter arrives as an array and the only way to pass an array on is
    /// `String(format:locale:arguments:)`, which does not resolve a plural
    /// variation. Three is every arity the window uses.
    static func string(_ english: String, _ first: any CVarArg) -> String {
        String.localizedStringWithFormat(string(english), first)
    }

    static func string(_ english: String, _ first: any CVarArg, _ second: any CVarArg) -> String {
        String.localizedStringWithFormat(string(english), first, second)
    }

    static func string(
        _ english: String, _ first: any CVarArg, _ second: any CVarArg, _ third: any CVarArg
    ) -> String {
        String.localizedStringWithFormat(string(english), first, second, third)
    }

    /// A sentence whose wording depends on a count: "1 folder", "3 folders",
    /// and in other languages rather more cases than that.
    ///
    /// The same call as `string` above; named separately at the call site so
    /// that whoever edits the catalogue can see which entries need the plural
    /// variations filling in and which are plain.
    static func count(_ english: String, _ number: Int) -> String {
        String.localizedStringWithFormat(string(english), number)
    }

    /// A word that needs two German words in two places.
    ///
    /// English has one "Series" — for the row above a book's series name, and
    /// for a row counting how many series a Calibre library holds. German has
    /// "Serie" and "Serien", and one catalogue entry cannot be both. So the key
    /// carries the place in brackets and the English is passed in beside it.
    ///
    /// The **one** exception to "the key is the sentence", written as an
    /// exception so nobody has to wonder whether the brackets reach the window.
    /// They do not: an English run reads the catalogue's own `en` value.
    static func contextual(_ key: String, english: String) -> String {
        Bundle.main.localizedString(forKey: key, value: english, table: nil)
    }

    /// A sentence ShelfCore produced.
    ///
    /// Looked up by the English itself. `LocalisationTests` walks the core's own
    /// enumerations and fails if one of their words is not in the catalogue, so
    /// there is never a fallback to fall back to — but the fallback is the
    /// English rather than the key, because a window that has lost a
    /// translation should still be readable.
    static func core(_ english: String) -> String {
        Bundle.main.localizedString(forKey: english, value: english, table: nil)
    }

    // MARK: Numbers, dates and sizes

    /// A count as the reader's language writes it: 8.412 in German, 8,412 in
    /// English.
    static func number(_ value: Int) -> String { value.formatted(.number) }

    /// A file size in the reader's language: "134,5 kB" against "134.5 kB".
    ///
    /// Not `ByteCount.format`, which is the core's and formats in the C locale
    /// on purpose: it writes the reports, and a report is evidence that scripts
    /// read (`Scripts/proof-run.sh` greps it). The window is the other case.
    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// A date as the reader's language writes it, without a time.
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

extension Loc {
    /// Why an edit was refused, in the reader's language.
    ///
    /// The core's own `message` is not looked up, because it has the value
    /// already written into it — "“2,5x” is not a number" is a sentence no
    /// catalogue can hold a key for. So the core answers *which* refusal it is
    /// and with what, and the window says it in words. That is the same seam as
    /// everywhere else: the rule is in the core, the wording is here
    /// ([ADR 0016](../../docs/adr/0016-the-core-answers-in-english-the-window-translates.md)).
    ///
    /// `BookFieldRejection.message` stays where it is: `shelf-tool` and the
    /// reports use it, and those are English on purpose.
    static func message(for rejection: BookFieldRejection) -> String {
        switch rejection {
        case .titleMustNotBeEmpty:
            return string(
                "A book needs a title – it names the folder the book lives in. The old title has "
                    + "been kept.")
        case .notANumber(let typed):
            return string("“%@” is not a number. A series index looks like 3 or 2.5.", typed)
        case .notADate(let typed):
            return string(
                "“%@” is not a date. Write a year (2019), a month (2019-04) or a day (2019-04-01).",
                typed)
        case .isbnCheckDigit(let typed):
            return string(
                "“%@” is not a valid ISBN: the check digit does not match. Two digits swapped "
                    + "while typing is the usual reason.", typed)
        case .identifierNeedsAScheme:
            return string("An identifier needs a name as well as a value – ISBN, ASIN, DOI.")
        }
    }

    /// Why a change to the shelf tree was refused.
    static func message(for rejection: ShelfEdit.Rejection) -> String {
        switch rejection {
        case .nameMustNotBeEmpty:
            return string("A shelf needs a name.")
        case .nameMustNotContainSeparator:
            return string(
                "A shelf's name cannot contain “%@” — that is what separates a shelf from the one "
                    + "it stands in.", ShelfTree.pathSeparator)
        case .nameAlreadyUsed(let name, let parent):
            guard let parent else { return string("There is already a shelf called “%@”.", name) }
            return string("“%1$@” already holds a shelf called “%2$@”.", parent, name)
        case .wouldMakeALoop:
            return string(
                "A shelf cannot be put inside itself or inside one of its own shelves.")
        }
    }

    /// Why "Write into the Book File" refused a book's own file, before
    /// anything was written.
    ///
    /// `EPUBFileReplacement.Refusal.message` is not looked up through
    /// `Loc.core` here, the way `CoverReplacement.Refusal`'s is — one case,
    /// `readOnlyVolume`, has the volume's name already written into it, and
    /// a catalogue key cannot hold a different volume name every time
    /// (`CoverReplacement.Refusal`'s own doc comment states the rule this
    /// breaks). So the core answers which refusal it is and with what, and
    /// the window says it in words — the same seam `message(for
    /// rejection:)` above uses.
    static func message(for refusal: EPUBFileReplacement.Refusal) -> String {
        switch refusal {
        case .notAnEPUB:
            return string("That is not a readable EPUB, so nothing was written.")
        case .drmProtected:
            return string("This book is protected, so Shelf will not write into its file.")
        case .readOnlyVolume(let volume):
            return string("“%@” cannot be written to, so nothing was changed.", volume)
        case .cannotWrite:
            return string("The new file could not be written, so the book still has the one it had.")
        case .readBackFailed:
            return string("The new file did not read back correctly, so it was discarded and nothing changed.")
        }
    }

    /// Why a book has no plan at all in the "Write into the Book File"
    /// sheet — shown beside its title in the list of what will be skipped.
    static func message(for failure: EPUBWrite.PlanFailure) -> String {
        switch failure {
        case .noEPUB:
            return string("This book has no EPUB — only PDF, MOBI or AZW3, which are never written into.")
        case .refused(let refusal):
            return message(for: refusal)
        case .authorCountMismatch(let existing, let new):
            return string(
                "This book's file and Shelf disagree on how many authors it has (%1$lld against %2$lld) "
                    + "— Shelf does not add or remove authors, so it is left alone.", existing, new)
        case .cannotPrepare(let why):
            return string("This book could not be prepared: %@", why)
        }
    }

    /// A field's label in the "Write into the Book File" sheet's old→new
    /// list.
    static func label(for field: EPUBWrite.FieldChange.Field) -> String {
        switch field {
        case .title: return string("Title")
        case .authors: return string("Author")
        case .publisher: return string("Publisher")
        case .published: return string("Published")
        case .language: return string("Language")
        case .description: return string("Description")
        }
    }
}
