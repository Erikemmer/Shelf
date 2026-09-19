import Foundation

/// One editable field of a book, and the rules for turning what a person typed
/// into a change.
///
/// It is in the core, UI-free and tested on Linux, because every one of these
/// rules is a rule that can be wrong, and none of them is about SwiftUI: what an
/// empty field means, how several authors are separated, what "2,5" is as a
/// series index, whether a title may be blank, whether an ISBN can be that
/// number at all. A `TextField` binding that decided those itself would put six
/// small decisions in a view where nothing can reach them.
///
/// The inspector's job is reduced to three lines per field: show `text(of:)`,
/// hand what was typed to `apply(_:to:)`, and act on the outcome.
public enum BookField: String, CaseIterable, Sendable {
    case title
    case authors
    case seriesName
    case seriesIndex
    case publisher
    case published
    case language
    case description

    /// What the inspector calls the field.
    public var label: String {
        switch self {
        case .title: return "Title"
        case .authors: return "Authors"
        case .seriesName: return "Series"
        case .seriesIndex: return "Series Index"
        case .publisher: return "Publisher"
        case .published: return "Published"
        case .language: return "Language"
        case .description: return "Description"
        }
    }

    /// What an empty field invites, in the shape Selector uses: a verb, the
    /// thing, an ellipsis.
    ///
    /// Beside `label` rather than in the inspector because the two belong
    /// together — a field is named once and prompted once, and six placeholder
    /// strings spread through a view are six strings that drift apart. It is
    /// text a person reads, which is the same reason `label` is here.
    ///
    /// It never states a format. "yyyy-mm-dd" sat in the date field and read as
    /// a value the book already had; the format belongs in the help text, which
    /// is there when it is wanted and invisible when it is not.
    public var placeholder: String {
        switch self {
        case .title: return "Add title…"
        case .authors: return "Add authors…"
        case .seriesName: return "Add series…"
        // Never on its own — the index only appears once there is a series to
        // count within, and beside a name a single "#" is clearer than a
        // sentence.
        case .seriesIndex: return "#"
        case .publisher: return "Add publisher…"
        case .published: return "Add date…"
        case .language: return "Add language…"
        case .description: return "Add description…"
        }
    }

    /// The part of the help text that is about *this* field rather than about
    /// editing in general — the format a date is read in, what separates two
    /// authors. Empty where a field needs no explaining.
    public var hint: String {
        switch self {
        case .authors: return "Several authors are separated by “ & ”"
        case .seriesIndex: return "3, or 2.5 for a novella"
        case .published: return "A year, a month or a day: 2019, 2019-04, 2019-04-23"
        case .language: return "A language code: en, de, fr"
        case .title, .seriesName, .publisher, .description: return ""
        }
    }

    /// Whether the field holds more than one line. The description does; a title
    /// with a line break in it is a title somebody pasted by accident.
    public var isMultiline: Bool { self == .description }

    /// What the field shows for a book.
    ///
    /// The *same* function the editor parses back, so the two cannot drift: what
    /// a field displays is by construction something `apply` accepts. Sprint 2a
    /// had the inspector format a value one way and would have parsed it
    /// another, which is how a field that shows "2019" comes to store 1 January
    /// of the year 2019 on every visit.
    public func text(of book: Book) -> String {
        switch self {
        case .title: return book.title
        // " & " is Calibre's own separator and what `authorLine` already prints
        // for two authors. A comma is *not* usable here: `AuthorSort` reads a
        // comma as "this name is already in sort form", so "Austen, Jane" is one
        // author and splitting on commas would make it two.
        case .authors: return book.authors.joined(separator: " & ")
        case .seriesName: return book.series?.name ?? ""
        case .seriesIndex: return book.series?.index.map(Self.number) ?? ""
        case .publisher: return book.publisher ?? ""
        case .published: return book.published.map(Self.day) ?? ""
        case .language: return book.language ?? ""
        case .description: return book.description ?? ""
        }
    }

    /// Applies what was typed. See `BookFieldOutcome`.
    ///
    /// Everything is trimmed at both ends first. Not a nicety: the XML parser
    /// trims an element's text on the way back in, so a value stored with a
    /// leading space would come back without one and the folder and the index
    /// would disagree about a book nobody had touched. Trimming here makes
    /// "what was stored" and "what comes back" the same string.
    public func apply(_ typed: String, to book: Book) -> BookFieldOutcome {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)

        // Nothing was typed: the field still holds what it was handed. This is
        // the guard that makes a field safe to commit on focus loss, which is
        // when it *is* committed – opening the inspector and clicking away
        // would otherwise write a file for every field the pointer crossed.
        //
        // It is also the only honest answer for a field that shows less than it
        // stores. `published` holds a moment and shows a day: a book imported
        // with `2001-09-09T01:46:40Z` shows "2001-09-09", and parsing that back
        // gives midnight — a different `Date`. Comparing the *text* says what
        // is true, that the day was not edited, where comparing the values
        // would report a change nobody made and lose the time to it.
        guard value != text(of: book) else { return .unchanged }

        var edited = book

        switch self {
        case .title:
            // dc:title is the one field a book cannot do without: it names the
            // folder, it is the fallback for everything else, and a library of
            // books called "" cannot be navigated. The field snaps back.
            guard !value.isEmpty else { return .rejected(.titleMustNotBeEmpty) }
            edited.title = value
            edited.titleSort = Self.titleSort(for: value, wasDerivedIn: book)
        case .authors:
            edited.authors = Self.authors(from: value)
        case .seriesName:
            // An empty series name removes the series *and* its index: a book
            // that is "number 3 of nothing" is not a state worth being able to
            // reach.
            edited.series = value.isEmpty ? nil : SeriesRef(name: value, index: book.series?.index)
        case .seriesIndex:
            guard let series = book.series else { return .unchanged }
            if value.isEmpty {
                edited.series = SeriesRef(name: series.name, index: nil)
            } else {
                guard let index = Self.decimal(value) else {
                    return .rejected(.notANumber(value))
                }
                edited.series = SeriesRef(name: series.name, index: index)
            }
        case .publisher:
            edited.publisher = value.isEmpty ? nil : value
        case .published:
            if value.isEmpty {
                edited.published = nil
            } else {
                guard let date = OPFDate.parse(value) else {
                    return .rejected(.notADate(value))
                }
                edited.published = date
            }
        case .language:
            edited.language = value.isEmpty ? nil : value
        case .description:
            edited.description = value.isEmpty ? nil : value
        }

        return edited == book ? .unchanged : .changed(edited)
    }

    // MARK: The rules, one function each

    /// Authors from one line, order kept, empties dropped.
    static func authors(from value: String) -> [String] {
        value
            .components(separatedBy: "&")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// How the sort title follows a new title.
    ///
    /// Only when nobody had set it by hand. `titleSort` is its own field and a
    /// person may well have written "Dispossessed, The" deliberately; silently
    /// overwriting that on the next typo fix would be the app changing data
    /// nobody asked it to change. "Nobody set it" is recognisable: the stored
    /// sort title is exactly what the rule would have produced.
    static func titleSort(for newTitle: String, wasDerivedIn book: Book) -> String {
        book.titleSort == TitleSort.of(book.title) ? TitleSort.of(newTitle) : book.titleSort
    }

    /// A series index as a person types it: "3", "2.5", and "2,5" on a German
    /// keyboard, where the comma is where the decimal point lives. Parsed by
    /// rule rather than by locale, because the file is not written in a locale
    /// either – `calibre:series_index` is always a point.
    static func decimal(_ value: String) -> Double? {
        let normalised = value.replacingOccurrences(of: ",", with: ".")
        guard let number = Double(normalised), number.isFinite else { return nil }
        // A negative volume number is not a typo worth storing.
        return number < 0 ? nil : number
    }

    /// `3` rather than `3.0`, `2.5` as itself – the same spelling the OPF uses,
    /// so the field shows what the file says.
    static func number(_ value: Double) -> String {
        let rounded = value.rounded()
        return abs(value - rounded) < 0.001 ? String(Int(rounded)) : String(format: "%g", value)
    }

    /// A publication date as `yyyy-MM-dd`.
    ///
    /// The day and not the year, although the inspector showed only the year
    /// until now: a field has to show something that can be typed back. "2019"
    /// is accepted on the way in (`OPFDate.parse` takes it) and comes back as
    /// "2019-01-01", which is what was actually stored — the field says what the
    /// file holds rather than hiding two thirds of it.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// What came of an edit.
///
/// Three outcomes and not a `Book?`, because "nothing changed" and "that cannot
/// be a title" are different things to a window: one is silent, the other puts
/// the field back and says why.
public enum BookFieldOutcome: Equatable, Sendable {
    case changed(Book)
    /// The value parsed and means what the book already says. Nothing is
    /// written and nothing goes on the undo stack.
    case unchanged
    case rejected(BookFieldRejection)
}

/// Why an edit was refused, in words a person can act on.
public enum BookFieldRejection: Equatable, Sendable {
    case titleMustNotBeEmpty
    case notANumber(String)
    case notADate(String)
    case isbnCheckDigit(String)
    case identifierNeedsAScheme

    /// Says what happened and what to do, never only that something failed
    /// (Leitlinie: "Fehlermeldungen sagen, was passiert ist und was zu tun ist").
    public var message: String {
        switch self {
        case .titleMustNotBeEmpty:
            return "A book needs a title – it names the folder the book lives in. "
                + "The old title has been kept."
        case .notANumber(let typed):
            return "“\(typed)” is not a number. A series index looks like 3 or 2.5."
        case .notADate(let typed):
            return "“\(typed)” is not a date. Write a year (2019), a month (2019-04) "
                + "or a day (2019-04-01)."
        case .isbnCheckDigit(let typed):
            return "“\(typed)” is not a valid ISBN: the check digit does not match. "
                + "Two digits swapped while typing is the usual reason."
        case .identifierNeedsAScheme:
            return "An identifier needs a name as well as a value – ISBN, ASIN, DOI."
        }
    }
}

/// The identifiers, which are keyed and therefore not a `BookField`.
///
/// Its own type because the operations are different: a scheme can be added and
/// removed, where a title can only be changed. The ISBN is the one that is
/// validated, and only here – see `ISBN`.
public enum IdentifierEdit {
    /// Sets one identifier. An empty value removes the scheme rather than
    /// storing an empty one, which is the same rule the other fields follow:
    /// nothing written is better than something meaningless written.
    public static func set(
        scheme rawScheme: String, value rawValue: String, in book: Book
    ) -> BookFieldOutcome {
        let scheme = rawScheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scheme.isEmpty else {
            return value.isEmpty ? .unchanged : .rejected(.identifierNeedsAScheme)
        }
        // `isbn_normalised` is the duplicate check's own derived row and never
        // something a book claims about itself.
        guard scheme != "isbn_normalised" else { return .unchanged }

        var edited = book
        if value.isEmpty {
            edited.identifiers.removeValue(forKey: scheme)
        } else {
            if scheme == "isbn", !ISBN.isValid(value) {
                return .rejected(.isbnCheckDigit(value))
            }
            edited.identifiers[scheme] = value
        }
        return edited == book ? .unchanged : .changed(edited)
    }

    public static func remove(scheme: String, from book: Book) -> BookFieldOutcome {
        set(scheme: scheme, value: "", in: book)
    }
}

/// Adding and removing tags.
///
/// Tags are a set with a stable order on the way out: the OPF writes one
/// `dc:subject` per tag, sorted, and the index reads them back sorted, so a tag
/// list is compared and stored sorted here too. Without that, adding a tag and
/// reading the book back would be a "change" every time.
public enum TagEdit {
    /// Adds one tag, case-insensitively de-duplicated.
    ///
    /// Case-insensitively because "Science Fiction" and "science fiction" are
    /// one keyword to everyone except a string comparison, and a sidebar that
    /// lists both is a sidebar that has lost the point of tags. The spelling
    /// that is already in the library wins, so the library stays consistent with
    /// itself rather than with whatever was typed last.
    public static func add(_ raw: String, to book: Book, knownTags: [String] = []) -> BookFieldOutcome {
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return .unchanged }
        let name = canonical(typed, among: book.tags + knownTags)
        guard !book.tags.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            return .unchanged
        }
        var edited = book
        edited.tags = (book.tags + [name]).sorted()
        return .changed(edited)
    }

    public static func remove(_ name: String, from book: Book) -> BookFieldOutcome {
        var edited = book
        edited.tags = book.tags.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        return edited == book ? .unchanged : .changed(edited)
    }

    /// The spelling the library already uses for this tag, or the typed one.
    static func canonical(_ typed: String, among known: [String]) -> String {
        known.first { $0.caseInsensitiveCompare(typed) == .orderedSame } ?? typed
    }

    /// What the tag field offers while somebody types.
    ///
    /// Prefix matches first and then the ones that merely contain the text,
    /// because a person typing "sci" is looking for "science fiction" and not
    /// for "classics". Tags the book already carries are left out – offering to
    /// add what is already there wastes the only row a person reads.
    public static func completions(
        for typed: String, among known: [String], excluding existing: [String], limit: Int = 6
    ) -> [String] {
        let needle = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let taken = Set(existing.map { $0.lowercased() })
        let candidates = known.filter { !taken.contains($0.lowercased()) }
        guard !needle.isEmpty else { return Array(candidates.prefix(limit)) }

        let prefixed = candidates.filter { $0.lowercased().hasPrefix(needle) }
        let contained = candidates.filter {
            let lower = $0.lowercased()
            return !lower.hasPrefix(needle) && lower.contains(needle)
        }
        return Array((prefixed + contained).prefix(limit))
    }
}

/// What one field says across a selection of books.
///
/// Three answers and not two, which is the whole of the fix. `sharedText`
/// returns `String?` — a value, or `nil` for "they differ" — and a field none
/// of the books fills in is a *shared empty string*, which is correct and
/// unreadable: `Published` drew a blank row while `Publisher` next to it drew
/// "Mixed", and a blank says neither "they differ" nor "none of them has one".
/// It was in `docs/BACKLOG.md` from Sprint 3.
public enum SharedValue: Equatable, Sendable {
    /// Every one of them shows this, and it is not empty.
    case same(String)
    /// Every one of them shows nothing at all.
    case noneHasOne
    /// They do not agree.
    case mixed

    /// Whether this is a value a person typed, as against one of the two
    /// answers about the *absence* of one. The inspector draws a value in the
    /// primary colour and both of the others in the secondary one, which is the
    /// same distinction a label and a value already carry.
    public var isAValue: Bool {
        if case .same = self { return true }
        return false
    }
}

extension BookField {
    /// The value every one of these books shows, or `nil` when they disagree.
    ///
    /// The whole of what an inspector needs in order to show a selection
    /// honestly: a value, or "Mixed". In the core because it is a rule about
    /// what a field *means* across several books, and because it has to use
    /// `text(of:)` — the same function a single book's field shows — or a
    /// selection of one would read differently from that book on its own.
    ///
    /// Kept beside `sharedValue`, and not replaced by it: an **editable** field
    /// wants exactly this, a string to put in the box and an empty one to leave
    /// the placeholder showing. `sharedValue` is for the rows that are only
    /// read.
    public func sharedText(across books: [Book]) -> String? {
        guard let first = books.first else { return nil }
        let text = self.text(of: first)
        return books.dropFirst().allSatisfy { self.text(of: $0) == text } ? text : nil
    }

    /// The same question, answered so that "none of them has one" can be said
    /// out loud.
    public func sharedValue(across books: [Book]) -> SharedValue {
        guard !books.isEmpty else { return .noneHasOne }
        guard let text = sharedText(across: books) else { return .mixed }
        return text.isEmpty ? .noneHasOne : .same(text)
    }
}

/// What a handful of books have in common, for an inspector showing several at
/// once.
///
/// Set arithmetic, in the core, because the answers are not obvious and each of
/// them is a decision: a tag on *every* book is part of the selection's own
/// state, a tag on *some* of them is not, and the two have to be drawn
/// differently or removing one would quietly do nothing to most of the books.
public enum AcrossBooks {
    /// Tags every book carries. Removing one of these acts on all of them.
    public static func sharedTags(_ books: [Book]) -> [String] {
        shared(books.map { Set($0.tags) })
    }

    /// Tags some books carry and others do not.
    public static func mixedTags(_ books: [Book]) -> [String] {
        mixed(books.map { Set($0.tags) })
    }

    public static func sharedShelves(_ books: [Book]) -> [String] {
        shared(books.map { Set($0.shelves) })
    }

    public static func mixedShelves(_ books: [Book]) -> [String] {
        mixed(books.map { Set($0.shelves) })
    }

    /// The rating every book has, or `nil` when they differ.
    public static func sharedStars(_ books: [Book]) -> Int? {
        guard let first = books.first?.stars else { return nil }
        return books.allSatisfy { $0.stars == first } ? first : nil
    }

    /// Whether every book is read, every book is unread, or they differ.
    public static func sharedReadStatus(_ books: [Book]) -> Bool? {
        guard let first = books.first?.isRead else { return nil }
        return books.allSatisfy { $0.isRead == first } ? first : nil
    }

    /// What R does to a mixed selection: **read**, because the useful half of
    /// "mark these as read" is finishing the job. Toggling each book on its own
    /// would leave the selection exactly as mixed as before, one book at a
    /// time, which is not a thing anybody wants from one key.
    public static func readStatusAfterToggle(_ books: [Book]) -> Bool {
        sharedReadStatus(books).map { !$0 } ?? true
    }

    private static func shared(_ sets: [Set<String>]) -> [String] {
        guard let first = sets.first else { return [] }
        return sets.dropFirst().reduce(first) { $0.intersection($1) }.sorted()
    }

    private static func mixed(_ sets: [Set<String>]) -> [String] {
        guard let first = sets.first else { return [] }
        let all = sets.reduce(first) { $0.union($1) }
        let every = sets.dropFirst().reduce(first) { $0.intersection($1) }
        return all.subtracting(every).sorted()
    }
}
