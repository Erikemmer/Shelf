# Pins the language Shelf starts in, for one script, and puts it back.
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
# ## How
#
# `AppleLanguages` in **Shelf's own defaults domain**, which macOS reads for that
# one application. The Mac's own language is never touched: a script that
# changed the login session's language to take a screenshot would be doing
# something nobody asked for.
#
# ## Use
#
#     . "$HERE/app-language.sh"
#     pin_app_language en          # sets a trap that puts it back, whatever happens
#
# `restore_app_language` runs on EXIT, so it happens on a failure and on a ⌃C as
# well as on a clean finish.

SHELF_APP_DOMAIN="${SHELF_APP_DOMAIN:-de.erikemmer.shelf}"

restore_app_language() {
    defaults delete "$SHELF_APP_DOMAIN" AppleLanguages 2>/dev/null
}

pin_app_language() { # language code, e.g. en
    local language="${1:?pin_app_language needs a language code}"
    # A trap rather than a line at the end: this has to happen when the script
    # fails too, or the next person's Shelf opens in a language they did not
    # choose and nothing says why.
    trap restore_app_language EXIT
    defaults write "$SHELF_APP_DOMAIN" AppleLanguages -array "$language"
    echo "language: Shelf pinned to '$language' for this run (its own defaults domain)"
}
