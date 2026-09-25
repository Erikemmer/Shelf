# Release notes

What each release means for someone *using* Shelf — three to six sentences,
in German and English, not `CHANGELOG.md`'s own developer log (Sprint,
Teil, root cause, test count). `Scripts/changelog-notes.py` renders the
section below matching the version being released; `make release` refuses
to run, rather than fall back to the technical changelog, when that
version has no section here.

A separate file from `CHANGELOG.md` on purpose: the changelog's sections
are bounded by extraction position (newest-first, down to the last
`<!-- shelf-release: ... -->` marker), not keyed by version, and one
version's technical log usually spans several Sprints — nothing there is a
natural "the text for 1.1.0". This file is keyed by version explicitly,
one `## <version>` heading each, so looking one up is a lookup, not an
extraction rule.

Both languages live under the same heading, `### Deutsch` first. Sparkle
shows the one matching the person's system language where that is
possible (a `sparkle:releaseNotesLink` per language, `xml:lang`-tagged,
which is Sparkle's own mechanism for this — `SUAppcast.m`'s
`bestNodeInNodes:name:`, picked via `NSBundle
preferredLocalizationsFromArray:`); the combined, both-languages text
below is what a GitHub release page shows (no per-viewer language there)
and what any system language Sparkle cannot match falls back to.

## 1.2.0

### Deutsch

Shelf trägt ein neues Symbol. Bücher, die doppelt in der Bibliothek stehen,
lassen sich jetzt zusammenführen — einzeln geprüft oder auf einen Schlag
für alle sicheren Gruppen — und ein einzelnes Format oder ein ganzes Buch
wandert auf Wunsch in den Papierkorb, nie ins Nichts. „Ähnliche
Schreibweisen…" schlägt vor, wenn derselbe Autor oder Verlag unter
mehreren Namen auftaucht, ohne je selbst etwas zusammenzuführen; „Felder
vereinheitlichen…" bringt Titel, Sprache, ISBN und Tags auf eine einzige,
richtige Schreibweise. „Fehlende Felder ergänzen…" fragt Open Library und
Google Books nach fehlenden Angaben — streng nur über die ISBN, mit einer
engen Ausnahme für die Beschreibung über Titel und Autor — und zeigt eine
gemeinsame Vorschau für die ganze Bibliothek, bevor irgendetwas
geschrieben wird. „Bibliothek ordnen…" bringt die Ordnerstruktur der
ganzen Sammlung in eine einheitliche Form. KFX-Dateien werden jetzt auf
ihre eigene Container-Kennung hin auf DRM geprüft.

### English

Shelf has a new icon. Books that show up twice in the library can now be
merged — checked one at a time or all at once for every safe group — and
a single format or a whole book can go to the Trash, never into the
void. "Similar Spellings…" proposes it when the same author or publisher
appears under more than one name, without ever merging anything itself;
"Standardize Fields…" brings title, language, ISBN and tags to one
correct spelling. "Fill Missing Fields…" asks Open Library and Google
Books for whatever is missing — strictly by ISBN, with a narrow
exception for the description via title and author — and shows one
combined preview for the whole library before anything is written.
"Organize Library…" brings the whole collection's folder structure into
one consistent shape. KFX files are now checked for DRM by their own
container marker.

## 1.1.0

### Deutsch

Ein Buchcover lässt sich jetzt auf vier Wegen ändern, und auch wieder
entfernen — das alte Bild landet im Papierkorb, nie im digitalen Nichts,
und ⌘Z macht eine Änderung rückgängig. Für EPUBs gibt es einen expliziten,
eigens bestätigten Weg, Metadaten und ein Cover direkt in die Buchdatei
selbst zu schreiben, statt nur in Shelfs eigene Ablage daneben — mit einer
Bestätigung, die jedes Buch und jedes geänderte Feld einzeln nennt, und
die ursprüngliche Datei geht dabei in den Papierkorb, niemals verloren.
Ein Import lässt sich jetzt sauber unterbrechen: Shelf beendet sich
mittendrin ohne Datenverlust und ohne die falsche Fehlermeldung, die
vorher manchmal danach erschien. Und Shelf hält sich ab jetzt selbst auf
dem Laufenden — „Shelf ▸ Nach Updates suchen …" zeigt, ob es etwas Neues
gibt, und nichts wird ohne einen eigenen Klick auf „Installieren"
heruntergeladen oder eingespielt.

### English

A book's cover can now be changed four different ways, and removed
again — the old picture goes to the Trash, never into the void, and ⌘Z
undoes a change. EPUBs have an explicit, separately confirmed way to write
metadata and a cover straight into the book file itself, instead of only
into Shelf's own file beside it — the confirmation names every book and
every changed field, and the original file goes to the Trash, never lost.
An import can now be interrupted cleanly: quitting mid-import loses
nothing and no longer leaves behind the false error banner it sometimes
did before. And Shelf now keeps itself up to date — "Shelf ▸ Check for
Updates…" says whether something new exists, and nothing downloads or
installs without a click of your own on "Install".
