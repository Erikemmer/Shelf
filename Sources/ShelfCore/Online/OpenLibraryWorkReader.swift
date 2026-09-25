import Foundation

/// A work's own record, `/works/<key>.json` — the one place Open Library
/// carries a description at all (Teil B1). `/search.json` never does
/// (`OpenLibraryReader`'s own `summary: nil`, said out loud there); this is
/// the fetch that answers what a search alone cannot.
///
/// Found by asking, not assumed: two real work records, one with no
/// `description` key at all and one with `description` as **an object**,
/// `{"type": "/type/text", "value": "…"}`, never a plain string, on this
/// service's own real answers — `dc:description`'s own Text-or-`{value}`
/// shape the ADR names.
public enum OpenLibraryWorkReader {
    public static func description(from data: Data) throws -> String? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataReadFailure.notAnObject(.openLibrary)
        }
        if let text = OpenLibraryReader.string(root["description"]) { return text }
        if let object = root["description"] as? [String: Any] {
            return OpenLibraryReader.string(object["value"])
        }
        return nil
    }
}
