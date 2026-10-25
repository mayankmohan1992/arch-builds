# mayank-v4 — personal x86-64-v4 pacman repository

Signed Arch packages built on GitHub Actions and consumed by this machine
through a normal `omarchy update`.

## Why this exists

ALHP already rebuilds ~790 Arch packages with `-O3 -march=x86-64-v4`, so this
repository is **not** a replacement for it. It exists for the gaps:

* packages that are expensive enough that CI is the right place to build them
  (`xmrig-cuda-tuned` needs the CUDA toolkit and a long nvcc compile);
* packages ALHP does not cover;
* a delivery path for anything built locally (e.g. a PGO Chromium) so it
  survives `omarchy update` without manual `pacman -U`.

## Layout

```
pkgs/<name>/PKGBUILD      package recipes (mirrors of upstream, flags adjusted)
keys/mayank-v4.asc        public signing key
.github/workflows/build.yml
scripts/setup-local-repo.sh   one-time root setup on the Arch machine
scripts/check-upstream.sh     reports when an upstream tag is newer
```

## How a build flows

1. `workflow_dispatch` (or a push touching `pkgs/**`) starts the job.
2. The job runs in an `archlinux:base-devel` container, rewrites `CFLAGS` in
   Arch's own `makepkg.conf` to `-march=znver4 -O3` (inheriting every other
   stock setting), and runs `makepkg -s --sign`.
3. It downloads the existing `mayank-v4` release assets (the runner is
   ephemeral, so the current database and packages must be fetched back),
   runs `repo-add --sign`, and re-uploads the database plus the new package.
4. The machine's `pacman -Syu` — normally via `omarchy update` — sees the new
   version and installs it.

## Versioning rules

* Our `pkgrel` must be higher than the equivalent upstream/ALHP build, so use
  `pkgrel=2` (or higher) when taking over a package ALHP also builds.
* When upstream publishes a new `pkgver`, our older build loses to it
  automatically. That is intentional: a stale custom build reverts to the
  stock package rather than being pinned forever.

## Free-tier notes

* Public repository → standard GitHub-hosted runners are free and unlimited.
* Release assets are free for public repositories (no total size or bandwidth
  limit; 2 GiB per file). Workflow artifacts are **not** used: the free plan
  caps them at 500 MB.
* Runner is 4 vCPU / 16 GB RAM / 14 GB SSD with a 6 hour job limit. Chromium
  cannot be built here (checkout alone is ~40 GB); it needs a local build.
* Scheduled workflows in public repos are disabled after 60 days of repo
  inactivity, so this repository uses `workflow_dispatch` instead of `schedule`.

## Adding a package

```sh
mkdir -p pkgs/<name>
cp /var/cache/pacman/pkg/... # or fetch upstream PKGBUILD
# adjust pkgrel, keep Arch's patch set, add real sha256sums
git add pkgs/<name> && git commit -m "pkg: add <name>" && git push
```

Then either let the push trigger the workflow or run:

```sh
gh workflow run build-package.yml -f pkg=<name>
```

## Signing

The private key lives only in the `PKG_SIGNING_KEY` repository secret and in
this user's GnuPG keyring. To rotate: generate a new key, update
`keys/mayank-v4.asc`, rotate the secret, then on the machine run
`pacman-key --add` + `pacman-key --lsign-key` for the new fingerprint and
delete the old one.

## Rollback

* Remove the `[mayank-v4]` stanza (or run `scripts/setup-local-repo.sh --remove`).
* `sudo pacman -Syyuu` to let stock packages win again (the double `u` is what
  permits the downgrade back to `-1`/`-1.1` pkgrels).
* Cache in `/var/cache/pacman/pkg` keeps the previous builds.

## Current state

| Package | Version | Why it is here |
|---|---|---|
| `xmrig-cuda-tuned` | 6.26.0-1 | Needs the CUDA toolkit and a long `nvcc` compile; also replaces stock `xmrig` (`provides`/`conflicts`). Built against the CUDA stub, so the plugin `dlopen`s `libcuda.so.1` from the real driver at runtime. |

Repository URL:
`https://github.com/mayankmohan1992/arch-builds/releases/download/mayank-v4`

Verify by hand at any time:

```sh
curl -sfLO https://github.com/mayankmohan1992/arch-builds/releases/download/mayank-v4/mayank-v4.db
curl -sfLO https://github.com/mayankmohan1992/arch-builds/releases/download/mayank-v4/mayank-v4.db.sig
gpg --verify mayank-v4.db.sig mayank-v4.db
bsdtar -tf mayank-v4.db
```

## Activate on this machine (one time, needs root)

```sh
cd ~/arch-builds && sudo bash scripts/setup-local-repo.sh
```

That trusts `keys/mayank-v4.asc`, inserts `[mayank-v4]` before `[core]`, and
runs `pacman -Sy`. From then on `omarchy update` picks up new builds with no
extra steps. `~/.config/omarchy/hooks/pre-refresh-pacman.d/20-mayank-v4.sh`
re-adds the stanza if Omarchy ever rewrites `pacman.conf`.
