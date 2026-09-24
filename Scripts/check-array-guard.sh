#!/bin/bash
# Checks that no script under Scripts/ that uses `set -u` can expand a
# possibly-empty array with the plain "${NAME[@]}" — which is an
# `unbound variable` error on a genuinely empty array in this Mac's
# `/bin/bash` (3.2.57, the last GPLv2 release Apple ships; fixed in 4.4+,
# which Apple never ships). Every executable script here uses `#!/bin/bash`
# on purpose, checked by hand in Sprint 16, Teil F (not a second lint
# guard — every one of them already did, nothing to keep enforcing): a
# newer Bash picked up via `#!/usr/bin/env bash` on someone else's machine
# could otherwise hide this class of bug again, silently.
#
# Found live, Sprint 16, Teil C: `Scripts/release.sh`'s own
# `GH_PRERELEASE_FLAG=()` on the stable channel crashed `gh release
# create` outright — every earlier real release had gone through the beta
# channel, where the array always held one element, so this had never
# fired before. Fixed there with the portable `${ARR[@]+"${ARR[@]}"}`
# idiom, which expands to nothing instead of erroring when the array is
# empty. Sprint 16, Teil F went through every other `set -u` script the
# same way — some arrays really can be empty at runtime (fixed with the
# same idiom), some are literal, reference-data arrays that cannot be
# (left as the plain form, with a comment at the declaration saying so).
#
# A grep, not a parser, in two passes over each in-scope script:
#
#   1. Which array names are ever declared safe? A comment block (run of
#      contiguous "#..." lines) that contains the fixed phrase "never
#      empty under set -u" declares safe every array name any line in
#      that same block also mentions as "${NAME[@]}" — wherever else in
#      the file that name is used, not only right there. The phrase is
#      fixed on purpose: this check and a human reader are looking for
#      the same words.
#   2. Every plain "${NAME[@]}" (or unquoted "${NAME[@]}") that is not
#      already guarded with "[@]+\"...\"" on its own line must name an
#      array pass 1 found safe. "${#NAME[@]}" (a length) never counts —
#      it cannot crash either way.
#
# Anything left over fails, and names the file and the line.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SAFE_MARKER="never empty under set -u"
FAILED=0

array_name_in() {
    # $1: a line (or a multi-line block); prints every array name it
    # mentions as "${NAME[@]}", one per line, in order, possibly repeated.
    printf '%s\n' "$1" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]' | sed -E 's/^\$\{//; s/\[@\]$//'
}

for script in "$HERE"/*.sh; do
    name="$(basename "$script")"
    [ "$name" = "check-array-guard.sh" ] && continue

    # In scope only if the script actually turns on -u – a script without
    # it cannot have this bug, whatever it expands.
    uses_set_u=0
    while IFS= read -r raw || [ -n "$raw" ]; do
        case "$raw" in
            set\ -*)
                flags="${raw#set -}"
                flags="${flags%% *}"
                case "$flags" in
                    *u*) uses_set_u=1 ;;
                esac
                ;;
        esac
    done <"$script"
    [ "$uses_set_u" -eq 1 ] || continue

    # ── pass 1: which array names does this file declare safe ───────────
    safe_names=""
    block=""
    block_has_marker=0
    while IFS= read -r raw || [ -n "$raw" ]; do
        lead="${raw%%[![:space:]]*}"
        trimmed="${raw#"$lead"}"
        case "$trimmed" in
            '#'*)
                block="$block
$trimmed"
                case "$trimmed" in
                    *"$SAFE_MARKER"*) block_has_marker=1 ;;
                esac
                continue
                ;;
        esac
        if [ "$block_has_marker" -eq 1 ]; then
            safe_names="$safe_names
$(array_name_in "$block")"
        fi
        block=""
        block_has_marker=0
    done <"$script"
    if [ "$block_has_marker" -eq 1 ]; then
        safe_names="$safe_names
$(array_name_in "$block")"
    fi

    # ── pass 2: every plain array-value expansion must name a safe array ─
    n=0
    while IFS= read -r raw || [ -n "$raw" ]; do
        n=$((n + 1))
        lead="${raw%%[![:space:]]*}"
        trimmed="${raw#"$lead"}"
        case "$trimmed" in '#'*) continue ;; esac
        # Already protected on this line: nothing to check on it.
        case "$trimmed" in *'[@]+"'*) continue ;; esac
        # A plain array-value expansion – "${#NAME[@]}" (a length) does
        # not match, since the character right after "${" must not be "#".
        case "$trimmed" in
            *'${'[A-Za-z_]*'[@]}'*) : ;;
            *) continue ;;
        esac

        for risky_name in $(array_name_in "$trimmed"); do
            if printf '%s\n' "$safe_names" | grep -qxF "$risky_name"; then
                continue
            fi
            echo "array-guard: Scripts/$name:$n expands \"\${$risky_name[@]}\" without the" >&2
            echo "  \${ARR[@]+\"\${ARR[@]}\"} guard, and no comment in the file says" >&2
            echo "  \"$SAFE_MARKER\" for $risky_name:" >&2
            echo "  $trimmed" >&2
            FAILED=1
        done
    done <"$script"
done

if [ "$FAILED" -eq 1 ]; then
    echo "array-guard: every array a set -u script expands as \"\${NAME[@]}\" must either" >&2
    echo "  use \${NAME[@]+\"\${NAME[@]}\"} (it can be empty at runtime) or have a comment" >&2
    echo "  saying \"$SAFE_MARKER\" (it provably cannot)." >&2
    exit 1
fi

echo "array-guard: every array expansion in a set -u script is either empty-safe or provably never empty."
