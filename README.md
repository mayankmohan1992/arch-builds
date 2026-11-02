# mayank-v4 — personal x86-64-v4 pacman repository

Signed Arch packages rebuilt with `-march=znver4` on GitHub Actions, consumed on
this machine through a normal `omarchy update`.

## Why this exists

ALHP already rebuilds ~790 Arch packages with `-O3 -march=x86-64-v4`, so this
repository is **not** a replacement for it. It covers the gaps ALHP leaves:

* Arch packages ALHP does not build (see `packages.txt`);
* AUR recipes (`aur:`) and Omarchy's own packages (`omarchy:`), which no
  distribution rebuilds for this CPU;
* hand-written recipes that are expensive to build locally (`local:`);
* a delivery path for anything built elsewhere, so it survives `omarchy update`.

It deliberately does **not** include: `glibc`, `gcc`/`gcc-libs`, `binutils`,
`base`, `filesystem`, `linux-firmware/*`, keyrings, the kernel, NVIDIA's
proprietary blobs, or the `omarchy` package itself. Those are either unsafe to
replace, have no compilable code, or would fight Omarchy's own channel.

## Managed set

`packages.txt` is the source of truth. Each line is a **spec**:

| Spec | Recipe comes from | Version tracked via |
|---|---|---|
| `git` | Arch packaging (`gitlab.archlinux.org`) | archlinux.org API |
| `aur:deckcraft` | AUR (`git clone`) | AUR RPC |
| `omarchy:owe` | `omacom/omarchy-pkgs` (sparse checkout) | that PKGBUILD |
| `local:gupax` | `pkgs/gupax/` | none — bumped by hand |

Recipes are **fetched fresh on every build**, never vendored, so a version bump
upstream always arrives together with its matching PKGBUILD. That is what makes
"rebuild only when upstream actually moved" true without anyone editing a
recipe by hand.

Only the target CPU differs: the workflow rewrites `CFLAGS`/`CXXFLAGS` in
Arch's own `makepkg.conf` to `-march=znver4 -O3`, inheriting every other stock
setting. `pkgrel` gets a `.1` suffix (`1` → `1.1`) so pacman prefers our build
over the stock one, while a newer upstream version always wins until CI
rebuilds — a stale custom build can never pin itself in place.

## How a build flows

Three jobs, because one sequential job cannot hold `nodejs` (2–3 h) plus forty
other packages inside a 6 h cap:

1. **plan** — downloads `state.json` and compares every spec against its
   upstream. Emits the matrix of packages that are actually behind.
2. **build** — a matrix, one container per package (`max-parallel: 6`,
   `fail-fast: false`). Each job fetches its recipe, builds, audits the output,
   and uploads only the package + signature. One broken recipe cannot stop the
   other packages.
3. **publish** — a single writer. Downloads the assets, prunes superseded
   versions, regenerates the database with `repo-add --sign`, derives
   `state.json` from each package's `.PKGINFO`, and uploads both.

`state.json` is derived from `.PKGINFO`, not from filenames: epochs contain `:`
which GitHub rewrites in asset names, so a filename is not a reliable source of
truth for a version.

## Update process

* `scripts/check-upstream.sh` runs from a systemd **user timer** every 6 hours.
  It compares `state.json` against each spec's upstream and dispatches a build
  **only** for packages that are missing or behind. When nothing moved, nothing
  is dispatched.
* The timer reads `GH_TOKEN` from `~/.config/arch-builds/gh.env` (mode 600) via
  `EnvironmentFile=`. This matters: `gh` normally keeps its token in the session
  keyring, and a timer fires whether or not that keyring is unlocked. On
  2026-11-02 the 20:26 run logged `gh not authenticated` and silently skipped a
  cycle. With `GH_TOKEN` set, dispatching never depends on the login session.
  To rotate, replace the token in that file; a repo-scoped fine-grained PAT with
  `Actions: write` is enough.
* `local:` specs are tracked from their checked-in PKGBUILD: bump `pkgver` and
  the next timer run picks it up.
* `local:` specs are skipped by the timer: they have no upstream to ask, and
  are bumped by hand.
* A GitHub `schedule:` is deliberately not used: GitHub disables scheduled
  workflows in public repositories after 60 days without repository activity.
* Nothing needs to be run locally to receive updates; `omarchy update` is enough.
* `~/.config/omarchy/hooks/pre-refresh-pacman.d/20-mayank-v4.sh` re-adds the
  repository stanza if Omarchy ever rewrites `pacman.conf`.

Run it by hand at any time:

```sh
scripts/check-upstream.sh --dry-run   # report only, no dispatch
scripts/check-upstream.sh             # dispatch if anything is behind
```

## Why updates never break

* `pkgrel` is `<upstream>.1`, so our build wins ties but loses to any newer
  upstream version. A stale custom build cannot pin itself in place.
* The `[mayank-v4]` stanza sits above `[core]`; pacman still picks the highest
  version, so an Omarchy or Arch release immediately outranks ours until CI
  catches up.
* Every package is built from the same source and the same PKGBUILD as
  upstream — only the CPU target changes. The ABI is identical.
* Every upload is signed and verified locally before it is published; a
  package whose signature does not verify is never uploaded.
* `scripts/setup-local-repo.sh --remove` plus `pacman -Syyuu` reverses
  everything, and `omarchy-snapshot` gives a bootable rollback.

## Verifying the output is really v4

`scripts/verify-v4.sh` disassembles each built package and reports AVX-512
(`zmm`) and AVX2 (`ymm`) instruction counts. This exists because of a real
regression: `makepkg` sources the *builder's* `~/.makepkg.conf` **after** the
system config, so `RUSTFLAGS` exported in the job environment was silently
ignored and every Rust package shipped baseline x86-64 for weeks.

Measured reference points on this machine (Ryzen 5 7600):

```
starship  zmm=33529   Rust, vectorised
usage     zmm=35033   Rust, vectorised
gridcraft zmm=112552  Rust, vectorised
git       zmm=7983    C, vectorised
tldr      zmm=0       Go binary, CFLAGS never applied
semver    zmm=0       Rust, too small to vectorise
```

Zero is legitimate for Go and tiny binaries, so the audit warns rather than
fails. The hard gate is in the workflow: the run fails early if `-march=znver4`
or `target-cpu=znver4` ever stops landing in the config files.

## Free-tier notes

* Public repository → standard GitHub-hosted runners are free and unlimited.
* Release assets are free for public repos (no total size/bandwidth limit,
  2 GiB per file). Workflow artifacts are **not** used: the free plan caps them
  at 500 MB.
* Runner: 4 vCPU / 16 GB RAM / 14 GB SSD, 6 h job limit. Chromium cannot be
  built here (its checkout alone is ~40 GB); `webkit2gtk`, `qt6-webengine`,
  `opencv`, `gtk4` and the `gstreamer` stack are excluded for the same reason.
* The matrix is what keeps `nodejs` from eating the whole budget: it gets its
  own 6 h job instead of sharing one with everything else.
* No separate `-debug` packages (they doubled CI time and repo size).
* `publish-db.sh` prunes superseded versions, so the release does not grow by
  one copy per rebuild.

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

| What | How |
|---|---|
| Arch package | add the name to `packages.txt`, push |
| AUR package | add `aur:<name>`, push |
| Omarchy package | add `omarchy:<name>`, push |
| Anything else | create `pkgs/<name>/PKGBUILD`, add `local:<name>`, push |

Everything except `local:` is tracked automatically from then on.

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

## Rust binaries: where RUSTFLAGS actually comes from

Rust ignores `CFLAGS`, so the target CPU has to be applied through `RUSTFLAGS`.
Which of the two mechanisms wins depends on which config makepkg loaded — this
is subtle and got it wrong once already:

| `--config` | `~/.makepkg.conf` sourced? | Effective RUSTFLAGS |
|---|---|---|
| `/etc/makepkg.conf` (default) | **yes**, and it overrides the environment | from `~/.makepkg.conf` |
| an override file (nodejs, v3 retry) | **no** | from the environment |

`makepkg`'s `source_makepkg_config()` only reads the user file when the config
is the default `/etc/makepkg.conf`. So the workflow writes
`/home/builder/.makepkg.conf` for the normal path **and** exports `RUSTFLAGS`
for the override path, and `fall_back_to_v3` updates both.

Without this, every cargo-built package (starship, tldr, usage, semver,
librsvg, the artcraft apps, gliff, gupax) is baseline x86-64 even though CFLAGS
say znver4.

Never use `-C target-cpu=native` in CI: the runner is Zen 3 or Intel, and the
artifact must target this machine.

## Packages that cannot be v4-built here

* **Anything that runs its own freshly compiled output during the build.**
  GitHub's standard runners are AMD EPYC (Zen 3, no AVX-512), so a znver4
  binary SIGILLs ("Illegal instruction"). This is why `ruby` and
  `libcloudproviders` are dropped. Rust is the common case — every proc-macro
  and build script is compiled with `RUSTFLAGS` and then executed — and C
  `configure` probes hit it too. Those packages are not dropped: the build
  retries automatically for `x86-64-v3` (AVX2/BMI2/FMA, still far above
  baseline) when the log shows a SIGILL, so a mixed runner pool cannot turn the
  repository red. `verify-v4.sh` reports which one you got.
* **`nodejs`** is the same class: V8 runs `torque` and `mksnapshot` during
  `make`. It is built for `x86-64-v3` with `-mtune=znver4`, which only affects
  scheduling. It still beats baseline x86-64, and it is the only package in the
  set that never gets v4.
* **`gupax`** needs nightly Rust (`#![feature(path_is_empty)]`). The matrix job
  installs one minimal nightly and links it into `/usr/local/bin`, because
  Arch's rustup package does not create `~/.cargo/bin` shims.
* **`omarchy-hyprland-titlebars`** is a Hyprland plugin: it only loads into the
  exact Hyprland build it was compiled against, and the recipe pins
  `hyprland=0.57.0` while this machine runs 0.56.2 (`IgnorePkg = hyprland`).
  Left to Omarchy.
* **`aether`** ships a prebuilt Go binary in its recipe, so rebuilding changes
  nothing; a real rebuild needs wails + node + webkit2gtk.
