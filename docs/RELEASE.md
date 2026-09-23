# Releasing Shelf

How a build on this Mac becomes a file somebody else can double-click.

Everything below is `Scripts/release.sh`, which `make release` runs. This
document is what the script cannot say: what the two credentials are, why they
are needed, and what to do when a step refuses.

**`Erikemmer/Shelf` is public**, and so is the separate repository a real
release publishes to, `Erikemmer/shelf-releases` (source and delivery,
ADR 0022 — never the other way round). Nothing in the build itself needs a
login, and CI builds the app on every push. The two credentials below are
Apple's; publishing also needs `gh` to be authenticated as a user who can
push to `shelf-releases` (`gh auth status`) — nothing this script creates or
stores itself.

---

## What is needed, once

Two things, and **both are Erik's to make**. No script in this repository
creates either of them, and neither is ever written into a file here.

### 1. A Developer ID Application certificate

This is what lets a Mac other than this one open Shelf at all. Without it macOS
tells the person the app is damaged and should be moved to the Trash — which is
not a warning about signing, it is what an unsigned app looks like to somebody
who did not build it.

It comes with the Apple Developer Program, which costs money each year.

1. developer.apple.com ▸ Certificates, Identifiers & Profiles ▸ Certificates ▸ **+**
2. Choose **Developer ID Application**.
3. Upload a certificate signing request (Keychain Access ▸ Certificate
   Assistant ▸ Request a Certificate From a Certificate Authority, saved to
   disk).
4. Download the certificate and double-click it. It goes into the login
   keychain.
5. Check it is there:

   ```
   security find-identity -v -p codesigning
   ```

   One line should read `Developer ID Application: … (TEAMID)`. That is the
   line `release.sh` looks for.

### 2. A notarytool keychain profile

Notarisation is Apple looking at the binary and saying it has seen it. It needs
an Apple ID, the team id and an **app-specific password** — never the Apple ID
password itself.

1. appleid.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords ▸ **+**.
   Call it something like "Shelf notarisation".
2. Store all three in the keychain, once:

   ```
   xcrun notarytool store-credentials shelf-notarytool \
       --apple-id <apple id> --team-id <team id> --password <app-specific password>
   ```

`release.sh` then never sees a password: it passes
`--keychain-profile shelf-notarytool` and macOS hands `notarytool` the
credentials. Nothing goes on a command line, into an environment variable, or
into a file in this repository. A different profile name works with
`SHELF_NOTARY_PROFILE=…`.

---

## The dry run — what can be proved without either of them

```
make release-dry
```

Signs **ad hoc** (`-`), skips notarisation and stapling, and does everything
else for real: the four checks, the archive, the hardened runtime, the signature
verification, the entitlements, the zip. It proves the whole path as far as the
one step that needs Apple.

Measured on 18 September 2026, version 0.1.0, on Erik's Mac:

```
release: ── 4/7  the signature ──
    …/Shelf.app: valid on disk
    …/Shelf.app: satisfies its Designated Requirement
release: code directory flags: 0x10002(adhoc,runtime)
release: hardened runtime: on
release: entitlements written to …/release/entitlements.plist

release: ── 5/7  zip ──
release: Shelf-0.1.0.zip (5209 KB)
```

`runtime` in those flags is the hardened runtime, which notarisation refuses a
build without. The entitlements the signed build actually carries, read back out
of it rather than out of `project.yml`:

```
com.apple.security.app-sandbox                        true
com.apple.security.files.bookmarks.app-scope          true
com.apple.security.files.removable-volumes.read-write true
com.apple.security.files.user-selected.read-write     true
com.apple.security.network.client                     true
```

Five, and no more. There is **no** server entitlement: Shelf listens for nothing
(CONCEPT §12).

Measured again on 21 September 2026, version 1.0.0, on Erik's Mac — the numbers
that can change between releases, quoted so the next run can be checked
against them:

```
release: ── 3/7  archive ──
release: archived: …/release/Shelf-1.0.0.xcarchive

release: ── 4/7  the signature ──
    …/Shelf.app: valid on disk
    …/Shelf.app: satisfies its Designated Requirement
release: code directory flags: 0x10002(adhoc,runtime)
release: hardened runtime: on
release: entitlements written to …/release/entitlements.plist

release: ── 5/7  zip ──
release: Shelf-1.0.0.zip (5696 KB)
```

The five entitlements above, read back out of this build, are unchanged.
**Universal** (`lipo -info`: `x86_64 arm64`), app bundle **13 MB** on disk,
zip **5 832 984 bytes**. Steps 6 and 7 (notarise, staple) skipped and said so
— no Developer ID certificate on this Mac (`docs/HANDOFF.md` §1).

And with no certificate in the keychain, a real run stops at step 2 and says so:

```
release: ── 2/7  the signing identity ──
release: FAILED – no “Developer ID Application” certificate in the keychain.
       …
       Until then:  RELEASE_DRY_RUN=1 Scripts/release.sh
       proves every step up to notarisation.
```

---

## The real release

```
make release
```

Seven steps to a built, signed app, then publishing (below). Each one prints
what it did.

| | Step | What it is for |
|---|---|---|
| 1 | `make test && make lint` | A release is not a way round the checks. `RELEASE_SKIP_CHECKS=1` exists and the script says so in its output when it is used |
| 2 | The identity | Reads `Developer ID Application: …` out of the keychain – see below for what happens when there is none |
| 3 | Archive | `xcodebuild archive`, Release configuration. Hardened Runtime only when step 2 found a real identity (`docs/adr/0022-updates-separate-delivery-sparkle.md`) |
| 4 | Verify | `codesign --verify --deep --strict`, then the code-directory flags must (or must not) contain `runtime`, matching step 2, then the entitlements are written out to be read |
| 5 | Zip | `ditto -c -k --keepParent` — not `zip`, which loses the bundle's symlinks, and notarisation refuses an archive that has |
| 6 | Notarise | `notarytool submit --wait`, only with a real identity. Minutes, not seconds. The log is kept |
| 7 | Staple and assess | Only after a real notarisation: `stapler staple` puts the ticket **inside** the bundle so a Mac with no network can still check it; then `spctl -a -vvv -t install`, which is what the other person's Mac runs; then the zip is made again, because the first one has no ticket in it |

Everything lands in `~/Library/Caches/Shelf/release/` — outside `~/Documents`,
which is synced (CLAUDE.md). `Shelf-<version>.zip` (or `Shelf-<version>-unsigned.zip`,
see below) is the download.

**A missing Developer ID no longer stops a real release.** Until Erik enrols
in the Apple Developer Program, step 2 signs ad hoc instead, steps 6 and 7
are skipped and say so, and the download's filename ends in `-unsigned` —
but the run continues all the way through publishing (below), exactly the
way `v1.0.0` itself was handed out by hand once. `RELEASE_DRY_RUN=1` is the
one path that always stops before any of that and never publishes,
regardless of what is or is not in the keychain — the local proof this
repository can run on its own.

## Publishing (ADR 0022)

Once steps 1–7 above are done, a real (non-dry) run publishes to the
separate `Erikemmer/shelf-releases` repository, using Sparkle's own CLI
tools (`sign_update`, `generate_appcast`) taken from the same SPM artifact
the app target already resolved — no `brew`, no separate download:

1. `sign_update --account shelf` on the zip (`SHELF_SPARKLE_ACCOUNT`
   overrides the account).
2. Release notes rendered from `CHANGELOG.md` (`Scripts/changelog-notes.py`)
   — see below for how "the matching section" is found in a changelog that
   is not itself keyed by version.
3. `generate_appcast --account shelf` against a per-channel archive
   directory under `~/Library/Caches/Shelf/appcast-archives/` that
   accumulates across releases (unlike `$OUT`, which this script clears
   every run), so older entries are kept in the feed.
4. `gh release create v<version>` in `shelf-releases`, `--prerelease` for an
   `-rc` version, which also routes it to `appcast-beta.xml` instead of
   `appcast.xml` — a stable install is never offered a release candidate by
   accident.
5. The updated appcast file is committed and pushed in the
   `shelf-releases` checkout (`$HOME/Documents/shelf-releases` by default,
   `SHELF_RELEASES_REPO` to override) — an ordinary git repository, not a
   build product, so it is not under `~/Library/Caches/Shelf/`.
6. A new `<!-- shelf-release: v<version> · <date> -->` marker is inserted
   at the top of this repo's own `CHANGELOG.md`, right above the newest
   entry — **not committed by the script**. `git status --short` shows it
   afterwards; committing it is the next step, by hand, like any other
   change.

**Why the CHANGELOG.md marker exists at all.** Shelf's own `CHANGELOG.md` is
written "Sprint 14, Teil B", not "`[1.1.0-rc1]`" — a sprint's entries are
written before a version number for that work exists. So "the section for
this release" cannot be found by matching a version string the way
Selector's own changelog allows; it is everything newest-first down to the
last release's own marker. The first marker was backfilled by hand at the
`v1.0.0`/Sprint 9 boundary, in the same commit that added
`Scripts/changelog-notes.py`.

---

## When a step refuses

**"no Developer ID Application certificate in the keychain"** — no longer a
refusal for a real run (see above); it signs ad hoc and continues. The dry
run is what to run to prove the path without publishing anything, whether
or not a certificate exists.

**"no notarytool keychain profile called shelf-notarytool"** — only reached
with a real identity. The
`store-credentials` line above has not been run, or was run for a different user
or a different keychain.

**"hardened runtime is NOT on"** — `ENABLE_HARDENED_RUNTIME: YES` has come out
of `project.yml`, or the archive was built from a stale `.xcodeproj`. `make
project` regenerates it; `release.sh` does that itself.

**Notarisation was not accepted.** The submission id is in
`~/Library/Caches/Shelf/release/notarytool.log`, and Apple's own reasons come
back with:

```
xcrun notarytool log <submission id> --keychain-profile shelf-notarytool
```

The usual answers are a missing hardened runtime, a nested binary that was not
signed, or an entitlement that needs a provisioning profile.

**`spctl` refuses a stapled app.** Usually the ticket has not propagated yet;
`xcrun stapler validate` says whether the ticket is in the bundle, and that is
the one that matters for somebody offline.

---

## What this does not do yet

- **No DMG.** The download is a zip. A DMG is prettier and is another thing to
  sign, staple and test; the zip is what notarisation wants anyway, and it is
  what a browser unpacks on its own.
- **Nothing here has ever been notarised.** The dry run proves every step up to
  it. Steps 6 and 7 have never run for real, because there is no certificate
  on this Mac, and nothing in this document should be read as saying they
  have. A real, non-dry `make release` publishes an ad-hoc, `-unsigned` build
  in the meantime (see above) rather than refusing to run at all.
