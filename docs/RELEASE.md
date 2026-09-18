# Releasing Shelf

How a build on this Mac becomes a file somebody else can double-click.

Everything below is `Scripts/release.sh`, which `make release` runs. This
document is what the script cannot say: what the two credentials are, why they
are needed, and what to do when a step refuses.

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

Seven steps. Each one prints what it did.

| | Step | What it is for |
|---|---|---|
| 1 | `make test && make lint` | A release is not a way round the checks. `RELEASE_SKIP_CHECKS=1` exists and the script says so in its output when it is used |
| 2 | The identity | Reads `Developer ID Application: …` out of the keychain. Never creates one |
| 3 | Archive | `xcodebuild archive`, Release configuration, hardened runtime from `project.yml` |
| 4 | Verify | `codesign --verify --deep --strict`, then the code-directory flags must contain `runtime`, then the entitlements are written out to be read |
| 5 | Zip | `ditto -c -k --keepParent` — not `zip`, which loses the bundle's symlinks, and notarisation refuses an archive that has |
| 6 | Notarise | `notarytool submit --wait`. Minutes, not seconds. The log is kept |
| 7 | Staple and assess | `stapler staple` puts the ticket **inside** the bundle so a Mac with no network can still check it; then `spctl -a -vvv -t install`, which is what the other person's Mac runs; then the zip is made again, because the first one has no ticket in it |

Everything lands in `~/Library/Caches/Shelf/release/` — outside `~/Documents`,
which is synced (CLAUDE.md). `Shelf-<version>.zip` is the download.

---

## When a step refuses

**"no Developer ID Application certificate in the keychain"** — see above. The
dry run is what to do meanwhile.

**"no notarytool keychain profile called shelf-notarytool"** — the
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
- **No Sparkle, no update feed.** v1.0 is a file on a page.
- **Nothing is uploaded anywhere.** Where the zip is put — a web page, a
  release on GitHub — is a decision, not a step, and it is Erik's.
- **Nothing here has ever been notarised.** The dry run proves every step up to
  it. Steps 6 and 7 have never run, because there is no certificate on this Mac,
  and nothing in this document should be read as saying they have.
