#!/usr/bin/env python3
"""Adds entries to App/Shelf/Resources/Localizable.xcstrings.

One entry per line on stdin, tab-separated:

    <english key>\t<german>                      a plain sentence
    <english key>\t<de one>|<de other>\t<en one>|<en other>   a counted one

The English value is the key itself for a plain sentence; a counted one
needs both forms in both languages, because German pluralises differently.
Existing keys are left exactly as they are — this never overwrites a
translation somebody has already read.
"""
import json
import sys

PATH = "App/Shelf/Resources/Localizable.xcstrings"


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(one, other):
    return {"variations": {"plural": {"one": unit(one), "other": unit(other)}}}


def main():
    catalogue = json.load(open(PATH))
    strings = catalogue["strings"]
    added = 0
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = line.split("\t")
        key = parts[0]
        if key in strings:
            continue
        if len(parts) == 3:
            de_one, de_other = parts[1].split("|")
            en_one, en_other = parts[2].split("|")
            entry = {"de": plural(de_one, de_other), "en": plural(en_one, en_other)}
        else:
            entry = {"de": unit(parts[1]), "en": unit(key)}
        strings[key] = {"extractionState": "manual", "localizations": entry}
        added += 1
    catalogue["strings"] = dict(sorted(strings.items()))
    with open(PATH, "w") as out:
        json.dump(catalogue, out, ensure_ascii=False, indent=2, sort_keys=False)
        out.write("\n")
    print(f"added {added}")


if __name__ == "__main__":
    main()
