# Pins the language Shelf starts in, for one script.
#
# Sourced, not run.
#
# ## Why this exists
#
# Shelf declares English **and German** since Sprint 7. macOS then gives it the
# reader's preferred language — and on the Mac this project is built on, that is
# German. So Shelf's menu bar reads "Ablage" and "Bibliothek", and every script
# here that drives the window by clicking `menu bar item "File"` stops working
# with a message that blames System Events:
#
#     "menu bar item \"Library\" of menu bar 1 … kann nicht gelesen werden. (-1728)"
#
# Nothing is wrong with the app. The script is asking for a menu by a name the
# app no longer uses. It cost a run of `online-shot.sh` twice before the reason
# was found, and the reason is invisible: the window looks perfectly normal, and
# the same script works on an English Mac.
#
# So a script that drives menus says which language it is written for.
#
# ## How — and how it used to be, which did not work
#
# **The language goes on the command line**, in the argument domain:
#
#     open -a Shelf <library> --args -AppleLanguages '(en)'
#
# `NSUserDefaults`' argument domain outranks every other, is read by the process
# itself at launch, and touches no preferences at all — so there is nothing to
# put back afterwards and nothing that can be lost.
#
# Until Sprint 7 this wrote `AppleLanguages` into **Shelf's own defaults
# domain** and removed it again in a trap. That is the documented way and it
# does not work reliably for a sandboxed app: `defaults write` hands the value
# to `cfprefsd`, `defaults read` gets it back from the same daemon, and the
# container's plist on disk **never receives it**. Measured on 19 September
# 2026, three times in a row:
#
#     $ defaults write de.erikemmer.shelf AppleLanguages -array en
#     $ defaults read de.erikemmer.shelf AppleLanguages
#     ( en )
#     $ plutil -extract AppleLanguages xml1 -o - ~/Library/Containers/…/de.erikemmer.shelf.plist
#     Could not extract value … No value at that key path
#     → the window comes up in German
#
# It worked often enough to be believed — the scripts that spend a second
# looking for the app bundle between the write and the launch usually won the
# race — and failed silently when it did not, which is the worst way for a
# guard to behave.
#
# ## Use
#
#     . "$HERE/app-language.sh"
#     pin_app_language en
#     open -a "$APP" "$LIBRARY" ${SHELF_LANGUAGE_ARGS:-}
#
# The variable is **unquoted** on purpose: it is three words and has to split
# into three. Bash does not re-parse the brackets that come out of an expansion,
# so `(en)` arrives as one literal word.

SHELF_APP_DOMAIN="${SHELF_APP_DOMAIN:-de.erikemmer.shelf}"

# Left behind by the versions of these scripts that wrote the defaults domain.
# A key nobody put back would start the next person's Shelf in a language they
# did not choose, so it is removed on the way out however this run ends.
restore_app_language() {
    defaults delete "$SHELF_APP_DOMAIN" AppleLanguages 2>/dev/null
}

pin_app_language() { # language code, e.g. en
    local language="${1:?pin_app_language needs a language code}"
    trap restore_app_language EXIT
    # Anything an older run of these scripts left in the defaults domain would
    # outrank nothing — the argument domain wins — but it would still be a
    # setting nobody asked for.
    restore_app_language
    SHELF_LANGUAGE_ARGS="--args -AppleLanguages ($language)"
    export SHELF_LANGUAGE_ARGS
    echo "language: Shelf pinned to '$language' for this run (on the command line)"
}
