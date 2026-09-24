# ADR 0022 – Updates: separate delivery through a second repository, Sparkle 2

Date: 2026-09-23 · Status: accepted

## Context

Shelf has no way to tell someone a new version exists, short of them
checking back by hand — and `v1.0.0` itself, once notarised, still would
not have one. An update mechanism needs an appcast feed and downloadable
builds, and a decision about where those live.

**Shelf's own source repository is already public** (since 19 September
2026, so GitHub Actions would run) — unlike Selector, whose own ADR 0007
made the same call for a *private* source repository. That difference
matters: this ADR is not about keeping source hidden, only about keeping
delivery — builds and the appcast, which change on a different rhythm and
for a different reason than source does — in a place of its own.

Selector went through this exact problem first, in its own ADR 0007, and
this decision follows it closely: same second-repository shape, same
Sparkle version, the same key-account trap found and avoided, the same
Hardened-Runtime fix. What differs is called out below, each time it does.

## Decision

**A second, public repository, `Erikemmer/shelf-releases`, holds only
builds and the two appcast feeds — never source.** Shelf's own repository
is unaffected: it was already public and stays exactly as public as before.
Sparkle 2 is the update framework, added as an SPM dependency
(`https://github.com/sparkle-project/Sparkle`, `from: 2.10.0`), in the app
target only — never in `ShelfCore`, which the Linux CI job already guards
against anything AppKit- or platform-specific.

1. **Checks automatically, never installs without asking.**
   `SUEnableAutomaticChecks` is `true`, `SUAutomaticallyUpdate` is `false` —
   Sparkle's own dialog is what actually starts a download or install, from
   `Shelf ▸ Check for Updates…` or a background check. A welcome-screen
   banner (`LibraryModel.updater.availableUpdateVersion`, set from
   `SPUUpdaterDelegate.updater(_:didFindValidUpdate:)`, drawn with
   SlateKit's own `SlateBanner`) says so if a background check found
   something while nobody was looking.
2. **The EdDSA key pair is asymmetric on purpose, and always under its own
   named account.** `generate_keys --account shelf` wrote the private half
   to this Mac's keychain only (`security find-generic-password -s
   "https://sparkle-project.org" -a shelf`) — it never touches the repo, a
   file, or a screenshot. The public half (`SPARKLE_PUBLIC_ED_KEY` in
   `project.yml`, baked into `Info.plist` as `SUPublicEDKey`) is safe to
   commit: it only lets Shelf *verify* an update's signature, never
   *produce* one.

   **`--account shelf` is not a style choice; it is what keeps this key
   from being Selector's.** `generate_keys`, `sign_update` and
   `generate_appcast` all default to one *global* account (`ed25519`) when
   no `--account` is given — and this Mac's keychain already held
   Selector's own Sparkle key under exactly that default account, made
   there under its own ADR 0007. Calling any of the three tools for Shelf
   without `--account shelf` would not have failed loudly; it would have
   silently read or written Selector's key pair instead of Shelf's own.
   Checked before generating anything, and confirmed different afterwards:
   Shelf's public key is `4nZaq+Rd3IeA3c1AAqNoFUAKpnTL/Y28iEUV4izruwU=`;
   Selector's, read only, is `8O7EP++fI1zpzU3Dy1/Bc5AEEYDNolkgR/MpvfiC8GU=`.
   Losing Shelf's own key means every future release needs a new key pair
   and every existing install has to be told about the new one by hand
   (`docs/RUNBOOK.md`) — back it up.
3. **Sandboxing needs one entitlement, chosen to grant the least it can —
   and one less than Selector needed.**
   `com.apple.security.temporary-exception.mach-lookup.global-name` (with
   Sparkle's own fixed `-spks`/`-spki` suffixes) lets the sandboxed app talk
   to Sparkle's installer, which has to run outside the sandbox to replace
   the app bundle. Unlike Selector, Shelf does **not** add
   `SUEnableDownloaderService` or hand Sparkle a separate Downloader XPC
   service: Shelf already carries `com.apple.security.network.client` for
   the online-metadata lookups (CONCEPT §9), so Sparkle's own download can
   use that entitlement directly, and the app's sandbox surface grows by
   exactly one entitlement instead of two.
4. **Hardened Runtime follows the signing identity, not a fixed setting.**
   Adding Sparkle surfaced the same conflict Selector's own ADR 0007
   found first: an ad-hoc build (no Developer ID) signs the app and the
   embedded `Sparkle.framework` with no shared team, and Hardened Runtime's
   library validation then refuses to load the framework at all. The fix
   that was tried first in Selector — and rejected there for the same
   reason it is rejected here — is
   `com.apple.security.cs.disable-library-validation`: it would ship a
   standing security exception to make a *local, ad-hoc-only* problem go
   away, and it would still be sitting in the entitlements file once a
   Developer ID made it unnecessary. Instead, `ENABLE_HARDENED_RUNTIME`
   reads `$(SHELF_HARDENED)`, a build setting `make app` and
   `Scripts/release.sh` set to `YES`/`NO` themselves, from exactly the same
   `security find-identity -v -p codesigning | grep "Developer ID
   Application"` check `release.sh` already used to choose between a real
   signature and an ad-hoc one. Until Sprint 13, `project.yml` set
   `ENABLE_HARDENED_RUNTIME: YES` unconditionally, true of every Release
   build there had ever been; this ADR is the point where that stops
   holding, on purpose, dated, because Sparkle's own embedded framework
   made an unconditional "on" actively break an ad-hoc build rather than
   merely being stricter than it needed to be. A Developer ID signs the
   app *and* the framework under the same real
   team, so library validation has something to match and Hardened Runtime
   can turn on with nothing disabled. **Live proof, this session:** `make
   app` (no Developer ID on this Mac) produced `flags=0x2(adhoc)` on
   `Shelf.app` — no `runtime` flag — and `make smoke` opened the built app
   clean, with `Sparkle.framework` embedded and its own separate signature
   untouched inside it.
5. **`Scripts/release.sh` stays the one release command**, extended rather
   than replaced (Teil B): it signs the ZIP with `sign_update --account
   shelf`, creates the GitHub release in `shelf-releases` (not this repo),
   runs `generate_appcast --account shelf`, and pushes the appcast with
   release notes rendered from the matching `CHANGELOG.md` section. An
   `-rc` version goes to `appcast-beta.xml` with `--prerelease` instead, so
   a stable install is never offered a release candidate by accident.
6. **`SHELF_APPCAST_URL` redirects the feed in Debug builds only,** for
   testing a fake update end to end without touching the real appcast — a
   safeguard against a stray environment variable ever pointing a Release
   build (what Erik actually runs) at a test channel.

## Consequences

* + Shelf's own source visibility is untouched by this decision — it was
  public before and stays public for the same reason (CI), not because of
  anything here.
* + The Sparkle key-account trap is written down here, and again in
  `CLAUDE.md` (Teil E), so a future session cannot rediscover it by nearly
  overwriting Selector's key.
* + No entitlement grants more than the specific thing it is for; Shelf's
  sandbox grows by exactly one new entitlement, reusing one it already had
  for everything else Sparkle would otherwise have needed its own for.
* + Losing the signing key is bad, but recoverable-if-slow (a new key pair,
  everyone updates by hand once), not silent or unrecoverable — the
  asymmetric design guarantees that.
* − A second repository to keep in sync (a release exists in one, source in
  the other) instead of one; `Scripts/release.sh` is what keeps that from
  being a manual, error-prone step.
* − Until a Developer ID exists, distributed ad-hoc builds still fail
  Gatekeeper on first launch (right-click ▸ Open) exactly as they did
  before Sparkle — this ADR does not change that, only documents that the
  update mechanism itself works either way.

## Nachtrag, 24 September 2026 — one channel, no more `-rc` versions

Sprint 15 published `1.1.0-rc1` and `1.1.0-rc2` to `appcast-beta.xml`
specifically to prove the two-channel mechanism itself — that a beta
install offered a second beta version, in order, without disturbing a
stable channel it never touched. That proof is done, and it revealed the
premise behind having two channels does not hold here: **Erik is the only
person who ever installs Shelf, and testing happens in the building
session, before a version is published, not by a separate group of
beta users running a separate channel.** Two channels were solving a
problem — a tester on `-rc` builds who should not disturb a stable
audience — that this project does not have.

**Decision: from `1.1.0` on, every release publishes to `appcast.xml`,
the main channel, and there is no more `-rc` version number.**
`appcast-beta.xml` is not deleted — `1.1.0-rc1` and `1.1.0-rc2` stay in
it, a record that the mechanism was proved — but nothing is ever added to
it again, and no installed Shelf reads it (`SUFeedURL` in `project.yml`
has only ever pointed at `appcast.xml`; the beta channel existed for
`Scripts/release.sh`'s own `-rc`-routing and Sprint 14 Teil C's own
throwaway-channel test, never for a build Erik actually ran day to day).
`Scripts/release.sh`'s own channel routing (`case "$VERSION" in *-rc*)
...`) is unchanged — it still exists, correctly unreachable, rather than
removed, so a future project with a real second audience for a beta
channel has the mechanism already proven and does not have to rebuild it.

### Consequences

* + One fewer thing to check before trusting a release reached Erik: no
  question of "did this go to the right channel."
* + The two-channel mechanism is proven and kept, not thrown away — a
  future need for it (a real second audience) does not start from zero.
* − `appcast-beta.xml` is now a dead file that a future session could
  mistake for still-active without reading this Nachtrag first.
