# Verifies that a Shelf.app a script found is actually built from this
# repository's current HEAD — not merely the newest by a bundle folder's own
# mtime, which lies.
#
# Sourced, not run — the same shape Scripts/no-foreign-shelf.sh has.
#
# ## Why this exists
#
# Every script under Scripts/ that drives the window finds "the newest
# Shelf.app" the same way: list every built bundle under DerivedData, sort by
# the bundle *directory's* own modification time, take the first one whose
# executable exists. That directory's mtime does not always change when an
# incremental Xcode build only rewrites files nested inside it — a
# recompiled string catalogue, a relinked binary — so a build from five days
# earlier was once picked over one finished a minute before, and the symptom
# looked exactly like a missing German translation rather than a stale
# build (docs/BACKLOG.md, Sprint 11).
#
# ## Which of the two fixes Erik asked for, and why
#
# Hashing the bundle's own executable against "the one that would be built
# right now" needs something fresh on the other side of that comparison,
# which means building — and a check must never quietly build anything of
# its own. Stamping the commit costs nothing but a string read back:
# `SHELF_BUILD_COMMIT`, a build setting `project.yml` substitutes into the
# built `Info.plist` exactly the way `CFBundleShortVersionString` already
# gets `MARKETING_VERSION` — set from the Makefile's own `xcodebuild …
# SHELF_BUILD_COMMIT="$(git rev-parse HEAD)"` on every `make app` and `make
# app-debug`. **Not** a build phase script editing the bundle after the
# fact: the first version of this fix did exactly that, and it silently
# broke the app's own code signature (`codesign --verify` started failing
# with "invalid Info.plist (plist or signature have been modified)"),
# because Xcode had already signed the bundle by the time a custom
# `postbuildScripts` phase ran. A build setting is substituted into
# `Info.plist` before signing ever happens, the same way every other
# `$(…)`-templated key in this project's `Info.plist` already is — nothing
# is ever touched afterward. This file only ever reads the resulting string
# back out of the built bundle and compares it with a fresh `git rev-parse
# HEAD`, run now, in the caller's own repository.
#
# **What this does not catch**: an edit made *after* the last build, with
# `HEAD` itself unmoved — that is still on whoever drives a script to have
# actually run `make app` since editing, exactly as it always was. What this
# fixes is the bug that was actually found: a build from a stale commit
# being mistaken for the current one.
#
# ## Use
#
#     . "$HERE/current-shelf-app.sh"
#     APP="…"  # however the caller already found its candidate
#     verify_shelf_app_is_current "$APP" || exit 1
#
# Prints nothing on success. On a mismatch, prints what commit the bundle
# was actually built from and what this repository's HEAD is now, and
# returns 1 — it never guesses which build was meant and never rebuilds
# anything to find out.
verify_shelf_app_is_current() {
    local app="${1:?verify_shelf_app_is_current needs a Shelf.app path}"
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local expected
    expected="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || {
        echo "current-shelf-app: could not read $repo_root's own HEAD" >&2
        return 1
    }
    local plist="$app/Contents/Info.plist"
    local stamped=""
    if [ -f "$plist" ]; then
        stamped="$(/usr/libexec/PlistBuddy -c "Print :ShelfBuildCommit" "$plist" 2>/dev/null || true)"
    fi
    if [ -z "$stamped" ]; then
        echo "current-shelf-app: FAILED – $app carries no build-commit stamp at all." >&2
        echo "  It predates this check, or was built before project.yml's stamping build" >&2
        echo "  phase existed. Expected HEAD $expected. Run 'make app' (or 'make app-debug')" >&2
        echo "  to rebuild — this never rebuilds it for you." >&2
        return 1
    fi
    if [ "$stamped" != "$expected" ]; then
        echo "current-shelf-app: FAILED – $app was built from commit $stamped," >&2
        echo "  but this repository's HEAD is now $expected. Run 'make app' (or" >&2
        echo "  'make app-debug') to rebuild before driving the window with it." >&2
        return 1
    fi
    return 0
}
