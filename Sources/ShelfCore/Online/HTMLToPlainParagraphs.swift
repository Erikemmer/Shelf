import Foundation

/// Reduces the HTML Calibre's own `comments` field carries to plain
/// paragraphs — Teil B4's own field rule ("HTML auf einfache Absätze
/// reduziert").
///
/// **Not the same job as `DescriptionFill.isPlainEnough`.** That is a
/// *check* on an online match, refusing anything beyond a `<p>`/`<br>` —
/// deliberately conservative, because a Title+Author match is a guess. A
/// Calibre cross-reference is matched by UUID or ISBN, not a guess, and its
/// `comments` field is real, rich HTML almost every time (a `<div>`, a
/// `<ul>`, a stray `<b>`) — refusing all of that would refuse nearly every
/// real Calibre description. So this *transforms* instead: every block
/// boundary becomes a paragraph break, everything else is dropped, and the
/// five XML entities plus the handful an ordinary rich-text editor writes
/// are decoded. Not a general HTML renderer — a description field, never a
/// table or a list item's own structure preserved as one.
public enum HTMLToPlainParagraphs {
    /// Tags whose *closing* (or, for `<br>`, whose very presence) means "a
    /// paragraph ends here" — what Calibre's own rich text editor actually
    /// writes almost everything as.
    static let paragraphBreaks = [
        "</p>", "<br>", "<br/>", "<br />", "</div>", "</li>", "</h1>", "</h2>", "</h3>", "</h4>",
    ]

    public static func reduce(_ html: String) -> String {
        var text = html
        for tag in paragraphBreaks {
            text = text.replacingOccurrences(of: tag, with: "\n\n", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression, .caseInsensitive])
        text = decodeEntities(text)
        let paragraphs =
            text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n\n")
    }

    /// The five XML entities, plus `&nbsp;` — the one a rich-text editor
    /// writes constantly and an XML parser would otherwise choke on.
    static func decodeEntities(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
            ("&#39;", "'"),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return result
    }
}
