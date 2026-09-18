import Foundation

/// Google Books' one answer, turned into candidates.
///
/// One shape for both questions — `items` of `volumeInfo` — which is the whole
/// of the difference from Open Library. Read as tolerantly: a volume with no
/// title is dropped, a volume missing anything else is kept with that field
/// empty.
public enum GoogleBooksReader {
    public static func candidates(from data: Data) throws -> [MetadataCandidate] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataReadFailure.notAnObject(.googleBooks)
        }
        // `totalItems: 0` comes back without an `items` key at all. That is an
        // answer — "nobody has this" — and not a failure.
        guard let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap(candidate)
    }

    static func candidate(_ item: [String: Any]) -> MetadataCandidate? {
        guard let id = item["id"] as? String,
            let info = item["volumeInfo"] as? [String: Any],
            let title = OpenLibraryReader.string(info["title"])
        else { return nil }

        let publishedText = OpenLibraryReader.string(info["publishedDate"])
        var identifiers = self.identifiers(info["industryIdentifiers"])
        identifiers["google"] = id

        return MetadataCandidate(
            id: "googlebooks:" + id,
            source: .googleBooks,
            title: OpenLibraryReader.string(info["subtitle"]).map { "\(title): \($0)" } ?? title,
            authors: (info["authors"] as? [String]) ?? [],
            series: series(info["seriesInfo"]),
            publisher: OpenLibraryReader.string(info["publisher"]),
            published: publishedText.flatMap(OnlineDate.parse),
            publishedText: publishedText,
            language: OpenLibraryReader.string(info["language"]).map(LanguageCode.normalised),
            subjects: (info["categories"] as? [String]) ?? [],
            summary: OpenLibraryReader.string(info["description"]),
            identifiers: identifiers,
            coverURL: coverURL(info["imageLinks"]),
            pageCount: info["pageCount"] as? Int
        )
    }

    /// `[{"type":"ISBN_13","identifier":"978…"}, …]`.
    ///
    /// 13 wins over 10 for the same reason it does in Open Library: one book,
    /// and the 13 is the one every other part of Shelf compares.
    static func identifiers(_ value: Any?) -> [String: String] {
        guard let list = value as? [[String: Any]] else { return [:] }
        var found: [String: String] = [:]
        for entry in list {
            guard let kind = entry["type"] as? String,
                let number = OpenLibraryReader.string(entry["identifier"])
            else { continue }
            switch kind {
            case "ISBN_13": found["isbn"] = number
            case "ISBN_10": if found["isbn"] == nil { found["isbn"] = number }
            default: break
            }
        }
        return found
    }

    /// Google Books answers `seriesInfo` for a few books and for most of them
    /// does not. Read where it is there, because a series is the field a person
    /// most often has to type by hand, and left alone where it is not.
    static func series(_ value: Any?) -> SeriesRef? {
        guard let info = value as? [String: Any],
            let volumes = info["volumeSeries"] as? [[String: Any]],
            let first = volumes.first
        else { return nil }
        // The API gives the series by id, not by name, in `volumeSeries`; the
        // human name is in `bookDisplayNumber` only as a number. A series
        // without a name is not a series, so this is deliberately narrow.
        guard
            let name = OpenLibraryReader.string(info["title"] as Any?)
                ?? OpenLibraryReader.string(first["seriesId"])
        else { return nil }
        let index = (first["orderNumber"] as? Int).map(Double.init)
        return SeriesRef(name: name, index: index)
    }

    /// The thumbnail, over **https** and without Google's page-curl overlay.
    ///
    /// Both matter. The API answers `http://` even to an `https://` request, and
    /// a plain `http` URL is refused by App Transport Security, so the cover
    /// would silently never load. `&edge=curl` draws a folded page corner over
    /// the cover, which is a picture of a book rather than the book's cover.
    static func coverURL(_ value: Any?) -> URL? {
        guard let links = value as? [String: Any] else { return nil }
        let raw = OpenLibraryReader.string(links["thumbnail"]) ?? OpenLibraryReader.string(links["smallThumbnail"])
        guard var text = raw else { return nil }
        if text.hasPrefix("http://") { text = "https://" + text.dropFirst("http://".count) }
        text = text.replacingOccurrences(of: "&edge=curl", with: "")
        return URL(string: text)
    }
}
