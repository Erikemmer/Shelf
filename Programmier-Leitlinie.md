# Programmier-Leitlinie (Version 1.0, 02.09.2026)

Diese Leitlinie gilt für jede Programmieraufgabe, in jedem Projekt. Vollfassung: ClickUp-Handbuch „💻 Programmier-Leitlinie (projektübergreifend)". Projektspezifische Regeln (Stack, Namenskonventionen) stehen in der Projekt-`CLAUDE.md` und ergänzen diese Leitlinie, ersetzen sie aber nicht.

## Arbeitsweise bei jeder Programmieraufgabe

1. **Leitlinie zuerst.** Vor dem ersten Code die relevanten Abschnitte unten berücksichtigen und in der Umsetzung sichtbar anwenden.
2. **Plan vor Code.** Bei allem, was mehr als eine Datei berührt: Ziel in einem Satz, Schritte, betroffene Dateien und Risiken kurz nennen und bestätigen lassen.
3. **Erst lesen, dann schreiben.** Relevante Dateien, Tests und Doku lesen; aktuelles Verhalten verstehen; Tests laufen lassen, bevor etwas geändert wird.
4. **Kleine Schritte, jeder lauffähig.** Nach jedem Schritt Build/Tests ausführen und das Ergebnis zeigen.
5. **Nichts Unumkehrbares ohne ausdrückliche Zustimmung:** kein Löschen von Daten, Dateien, Branches, Tabellen; kein `force push`; kein Überschreiben fremder Änderungen; keine Änderungen an Produktionssystemen ohne Rückfrage. Vor destruktiven Datenoperationen: Backup, `--dry-run`, Bestätigung.
6. **Keine ungefragten Umbauten.** Bestehenden Code nur im Rahmen der Aufgabe ändern; Verbesserungsvorschläge getrennt nennen.
7. **Standard vor Eigenbau.** Wenn eine gepflegte Bibliothek oder ein Dienst die Aufgabe löst, das zuerst vorschlagen – mit Lizenz und Wartungsstand.
8. **Tests und Doku gehören zur Lieferung.** Jede Änderung mit automatischem Test (jede Fehlerkorrektur beginnt mit einem reproduzierenden Test) und aktualisierter Doku (README, CHANGELOG, ADR bei Entscheidungen).
9. **Geheimnisse nie anfassen.** Keine Passwörter, Keys, Tokens in Code, Chat oder Logs; Platzhalter und `.env.example` verwenden.
10. **In einfacher Sprache erklären.** Jede Lieferung endet mit einer kurzen, nicht-technischen Zusammenfassung: was geändert, warum, was zu prüfen ist.
11. **Unsicherheit benennen.** Was nicht verifiziert werden konnte, ausdrücklich sagen – nicht raten.
12. **Definition of Done prüfen**, bevor eine Aufgabe als erledigt gemeldet wird (siehe unten).

## Zehn Prinzipien

1. Daten sind wichtiger als Code – Datenmodell, Migrationen, Backups, Exportwege haben Vorrang.
2. Standard vor Eigenbau – nur das selbst bauen, was das Projekt einzigartig macht.
3. Kein Lock-in – offene Formate, dokumentierte Schnittstellen, jede Komponente ersetzbar, jede Datenbank vollständig exportierbar.
4. Klein und lesbar – kleine Funktionen (~40 Zeilen, max. 3 Einrückungsebenen), Dateien, Commits, PRs.
5. Getestet oder nicht fertig.
6. Dokumentiert oder nicht fertig.
7. Explizit statt magisch – keine versteckten Nebenwirkungen, Konfiguration sichtbar, Abhängigkeiten deklariert.
8. Sicher by default – minimale Rechte, keine Secrets im Code, jede Eingabe validiert, Abhängigkeiten aktuell, neue Objekte standardmäßig privat.
9. Automatisieren, was wiederkehrt – Build, Test, Lint, Deploy, Backup per Skript (`make dev/test/deploy/backup` o. ä.).
10. Erst verstehen, dann ändern – kein blindes Refactoring.

## Architektur & Code

- Trennung Daten / Logik / Oberfläche; jede Anwendung hat eine API (auch interne Werkzeuge).
- Konfiguration aus der Umgebung (`.env.example` im Repo, echte `.env` nie).
- Stabile, bedeutungsfreie Primärschlüssel (UUID o. ä.); fachliche Nummern als eigene Felder.
- Referenzdaten sind Daten (Tabellen/Konfig), kein Code.
- Sprechende Namen, englische Bezeichner, eine Aufgabe pro Funktion, keine Duplikate, keine toten Pfade, kein auskommentierter Code.
- Fehler behandeln, nicht verschlucken; Fehlermeldungen sagen, was passiert ist und was zu tun ist.
- Typen nutzen (strikte Modi); Formatter + Linter automatisch (Pre-Commit/CI).
- Kommentare erklären das Warum.

## Tests

Testpyramide (viele Unit-, einige Integrations-, wenige E2E-Tests); kritische Pfade (Import/Export, Auth/Rechte, Berechnungen, alles Destruktive) immer getestet; Tests laufen in CI und blockieren rote Merges; Testdaten reproduzierbar und ohne echte personenbezogene Daten.

## Dokumentation je Repository

README (was, für wen, lokal in 5 Minuten starten, testen, deployen) · ARCHITECTURE (Bausteine, Datenfluss, Diagramm) · Entscheidungsprotokoll/ADRs · CHANGELOG · Datenmodell · Runbook (Backup, Restore, Update, Störungen). Doku wird im selben Commit geändert wie der Code. Zusätzlich eine Kurzfassung in einfacher Sprache für Nicht-Techniker.

## Versionierung

Alles in Git außer Secrets/Massen-Binärdaten/Generiertem; Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`); Branch pro Aufgabe, PR mit Review; `main` immer lauffähig; SemVer-Tags; PR ↔ Aufgabe gegenseitig verlinkt.

## Daten

Schema-Änderungen nur per versionierter Migration; Importe/Skripte idempotent mit Zählprotokoll (gelesen/geschrieben/übersprungen/fehlerhaft); Soft-Delete bevorzugen; Backups täglich, zweiter Ort, Restore getestet; Export jederzeit in offenen Formaten inkl. Dateien; Historie/Audit und externe Referenzen mitführen; personenbezogene Daten minimieren (DSGVO), private Felder nie öffentlich ausliefern.

## Betrieb & Oberfläche

Infrastructure as Code; Logging ohne PII/Secrets; Health-Checks; geplante Updates mit Rollback-Weg. Oberflächen: Barrierefreiheit (Tastatur, Kontraste, Labels), Leistung messen, keine Tracker ohne Einwilligung.

## Definition of Done

- Ziel erreicht und mit Auftraggeber abgeglichen
- Code lesbar, formatiert, Linter ohne Fehler
- Automatische Tests vorhanden und grün (inkl. Test für behobene Fehler)
- Keine Geheimnisse im Code oder in der Versionsgeschichte
- Migrationen versioniert, Import/Export weiterhin möglich
- README / CHANGELOG / ADR aktualisiert
- Barrierefreiheit und Datenschutz geprüft (bei Oberflächen)
- PR mit Aufgaben-Verweis, Review erfolgt
- Deployment-Weg und Rollback bekannt
- Kurzfassung in einfacher Sprache geschrieben
