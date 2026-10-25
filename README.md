# mayank-v4 — personal x86-64-v4 pacman repository

Signed Arch packages rebuilt with `-march=znver4` on GitHub Actions, consumed on
this machine through a normal `omarchy update`.

## Why this exists

ALHP already rebuilds ~790 Arch packages with `-O3 -march=x86-64-v4`, so this
repository is **not** a replacement for it. It covers the gaps ALHP leaves:

* Arch packages ALHP does not build (see `packages.txt`);
* AUR/custom recipes that are expensive to build locally (`xmrig-cuda-tuned`);
* a delivery path for anything built elsewhere, so it survives `omarchy update`.

It deliberately does **not** include: `glibc`, `gcc`/`gcc-libs`, `binutils`,
`base`, `filesystem`, `linux-firmware/*`, keyrings, the kernel, NVIDIA's
proprietary blobs, or Omarchy's own packages. Those are either unsafe to
replace, have no compilable code, or would fight Omarchy's own channel.

## Managed set

`packages.txt` is the source of truth. Recipes come from Arch's official
packaging repository (`gitlab.archlinux.org/archlinux/packaging/packages`), so
upstream patches and dependency lists are reused verbatim and tracking upstream
is automatic.

Only the target CPU differs: the workflow rewrites `CFLAGS`/`CXXFLAGS` in
Arch's own `makepkg.conf` to `-march=znver4 -O3`, inheriting every other stock
setting. `pkgrel` gets a `.1` suffix (`1` → `1.1`) so pacman prefers our build
over the stock one, while a newer upstream version always wins until CI
rebuilds — a stale custom build can never pin itself in place.

`python` is deliberately absent: Arch already builds it with PGO+LTO, so our
only gain is `-march` (~3–8%), and its PGO profile step needs a generated
`en_US.UTF-8` locale. Not worth replacing the system interpreter.

## How a build flows

1. `workflow_dispatch` (or a push touching `packages.txt`, `pkgs/**`,
   `scripts/ci-build.sh`, or the workflow) starts the job.
2. The job runs in an `archlinux:base-devel` container, rewrites `makepkg.conf`
   for znver4, imports the signing key and every `validpgpkeys` entry the recipe
   declares, then builds each package with `makepkg --sign`.
3. After **each** package it regenerates the database with `repo-add --sign`,
   updates `state.json`, and re-uploads to the `mayank-v4` release. A failure
   late in the list does not lose the packages already built.
4. `pacman -Syu` — normally via `omarchy update` — sees the newer `pkgrel` and
   installs it.

## Update process

* `scripts/check-upstream.sh` runs from a systemd **user timer** every 6 hours.
  It compares `state.json` against Arch's package API and dispatches a build
  only for packages that are missing or behind.
* A GitHub `schedule:` is deliberately not used: GitHub disables scheduled
  workflows in public repositories after 60 days without repository activity.
* Nothing needs to be run locally to receive updates; `omarchy update` is enough.
* `~/.config/omarchy/hooks/pre-refresh-pacman.d/20-mayank-v4.sh` re-adds the
  repository stanza if Omarchy ever rewrites `pacman.conf`.

## Free-tier notes

* Public repository → standard GitHub-hosted runners are free and unlimited.
* Release assets are free for public repos (no total size/bandwidth limit,
  2 GiB per file). Workflow artifacts are **not** used: the free plan caps them
  at 500 MB.
* Runner: 4 vCPU / 16 GB RAM / 14 GB SSD, 6 h job limit. Chromium cannot be
  built here (its checkout alone is ~40 GB); `webkit2gtk`, `qt6-webengine`,
  `opencv`, `gtk4` and the `gstreamer` stack are excluded for the same reason.
* No separate `-debug` packages (they doubled CI time and repo size).

## Activate on this machine (one time, needs root)

```sh
cd ~/arch-builds && sudo bash scripts/setup-local-repo.sh
```

That trusts `keys/mayank-v4.asc`, inserts `[mayank-v4]` before `[core]`, and
also enables `[multilib-x86-64-v4]` (44 more of this machine's `lib32-*`
packages are already built for v4 in ALHP's multilib repository).

## Verify by hand

```sh
curl -sfLO https://github.com/mayankmohan1992/arch-builds/releases/download/mayank-v4/mayank-v4.db
curl -sfLO https://github.com/mayankmohan1992/arch-builds/releases/download/mayank-v4/mayank-v4.db.sig
gpg --verify mayank-v4.db.sig mayank-v4.db
bsdtar -tf mayank-v4.db
```

## Adding a package

Arch package: add the name to `packages.txt` and push.

AUR/custom recipe: create `pkgs/<name>/PKGBUILD` (and any local sources) and
push. Vendored recipes are not auto-tracked by `check-upstream.sh`; bump their
`pkgver` deliberately, since patches may need refreshing.

## Signing

Private key lives only in the `PKG_SIGNING_KEY` repository secret and in this
user's GnuPG keyring. To rotate: generate a new key, update
`keys/mayank-v4.asc`, rotate the secret, then `pacman-key --add` +
`pacman-key --lsign-key` locally and remove the old key.

## Rollback

* `sudo bash scripts/setup-local-repo.sh --remove` (removes only `[mayank-v4]`).
* `sudo pacman -Syyuu` so stock packages win again — the double `u` permits the
  downgrade back to the `-1` / `-1.1` pkgrels.
* `/var/cache/pacman/pkg` keeps the previous builds; `omarchy-snapshot` gives a
  bootable rollback.
