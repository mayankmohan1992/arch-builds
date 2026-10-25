#!/usr/bin/env bash
# Builds packages and publishes them to the mayank-v4 release.
# Runs as the unprivileged `builder` user inside the Arch container.
#
# Sources:
#   pkgs/<name>/          vendored recipe (AUR / custom)
#   otherwise             Arch's official PKGBUILD, fetched from
#                         gitlab.archlinux.org/archlinux/packaging/packages
#
# Only CFLAGS differ from Arch: the workflow rewrites /etc/makepkg.conf to
# -march=znver4 -O3, so Arch's own patches and dependency graph are reused
# verbatim. pkgrel gets a ".1" suffix so pacman prefers our build over the
# stock one without ever outranking a newer upstream version.
set -uo pipefail

: "${REPO_NAME:?}" "${GH_REPO:?}" "${KEYID:?}"

cd "${GITHUB_WORKSPACE:?}"
mkdir -p repo out srcdest

if [[ -z ${PKGS:-} ]]; then
  PKGS=$(grep -vE '^[[:space:]]*(#|$)' packages.txt | tr '\n' ' ')
fi
echo "packages: $PKGS"

# The runner is ephemeral: recover the current database and packages first,
# otherwise each build publishes a database containing only its own package.
gh release download "$REPO_NAME" --repo "$GH_REPO" --dir repo --skip-existing || true
[[ -f repo/state.json ]] || echo '{}' >repo/state.json

publish() {
  ( cd repo
    # pacman requests <repo>.db by name, but repo-add leaves a symlink to the
    # tarball; dereference so the uploaded asset is the real file.
    for f in "$REPO_NAME.db" "$REPO_NAME.files"; do
      [ -L "$f" ] && { cp -L "$f" "$f.real" && mv -f "$f.real" "$f"; }
    done
    rm -f "$REPO_NAME.db.tar.gz" "$REPO_NAME.files.tar.gz" )
  gh release view "$REPO_NAME" --repo "$GH_REPO" >/dev/null 2>&1 ||
    gh release create "$REPO_NAME" --repo "$GH_REPO" \
      --title "mayank-v4 pacman repository" \
      --notes "Signed x86-64-v4 packages built by GitHub Actions. pacman pulls updates through omarchy update."
  gh release upload "$REPO_NAME" repo/* --repo "$GH_REPO" --clobber
}

fail=0
built=""
for pkg in $PKGS; do
  echo "::group::build $pkg"
  if [[ -d pkgs/$pkg ]]; then
    src="$GITHUB_WORKSPACE/pkgs/$pkg"
  else
    src="$GITHUB_WORKSPACE/work/$pkg"
    rm -rf "$src"; mkdir -p "$src"
    if ! curl -sfL "https://gitlab.archlinux.org/archlinux/packaging/packages/$pkg/-/archive/main/$pkg-main.tar.gz" |
         tar xz -C "$src" --strip-components=1; then
      echo "::error::no packaging source for $pkg"
      fail=1; echo "::endgroup::"; continue
    fi
  fi

  # "1" -> "1.1" so our build beats stock; an already-suffixed pkgrel is kept
  # so repeated runs are idempotent instead of drifting to 1.1.1.
  sed -i -E 's/^pkgrel=([0-9]+)$/pkgrel=\1.1/' "$src/PKGBUILD"
  read -r pv pr < <(cd "$src" && makepkg --printsrcinfo |
    awk -F' = ' '/^\tpkgver/{v=$2} /^\tpkgrel/{r=$2} END{print v, r}')
  echo "building $pkg $pv-$pr"

  # Idempotent: a push or a re-dispatch must not rebuild packages that are
  # already published at this exact version.
  if [[ $(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2],""))
except Exception: print("")' repo/state.json "$pkg") == "$pv-$pr" ]]; then
    if compgen -G "repo/${pkg}-${pv}-${pr}-*.pkg.tar.zst" >/dev/null; then
      echo "$pkg $pv-$pr already published; skipping"
      echo "::endgroup::"
      continue
    fi
  fi

  # Arch's recipes verify upstream release signatures, and a fresh container
  # has an empty keyring. Import every key the recipe declares so makepkg can
  # actually validate the sources instead of us disabling the check.
  mapfile -t vkeys < <(cd "$src" && makepkg --printsrcinfo |
    awk -F' = ' '/^\tvalidpgpkeys/{print $2}')
  for k in "${vkeys[@]}"; do
    [[ -z $k ]] && continue
    gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$k" >/dev/null 2>&1 ||
      gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$k" >/dev/null 2>&1 ||
      echo "::warning::could not import PGP key $k for $pkg"
  done

  if ! ( cd "$src" && PKGDEST="$GITHUB_WORKSPACE/out" SRCDEST="$GITHUB_WORKSPACE/srcdest" \
         RUSTFLAGS="-C target-cpu=znver4" CARGO_BUILD_JOBS="$(nproc)" \
         makepkg -s --noconfirm --nocheck --cleanbuild --sign --key "$KEYID" ); then
    echo "::error::build failed: $pkg"
    fail=1; echo "::endgroup::"; continue
  fi

  cp out/*.pkg.tar.zst repo/
  cp out/*.pkg.tar.zst.sig repo/ 2>/dev/null || true
  # Regenerate rather than update: repo-add is incremental, so a deleted
  # package asset would otherwise leave a dangling database entry that pacman
  # still tries to download.
  ( cd repo && rm -f "$REPO_NAME.db"* "$REPO_NAME.files"* &&
    repo-add --sign --key "$KEYID" "$REPO_NAME.db.tar.gz" ./*.pkg.tar.zst >/dev/null )
  python3 - "$pv-$pr" "$pkg" <<'PY'
import json, sys
version, pkg = sys.argv[1], sys.argv[2]
path = "repo/state.json"
state = json.load(open(path)) if __import__("os").path.exists(path) else {}
state[pkg] = version
json.dump(state, open(path, "w"), indent=2, sort_keys=True)
PY
  rm -f out/*
  publish
  built="$built $pkg"
  # Bound disk use on the 14 GB runner: source tarballs are re-fetched per
  # package rather than accumulated across ~30 builds.
  rm -rf srcdest
  echo "::endgroup::"
done

echo "built:$built"

# Always republish once at the end, even when every package was skipped, so the
# database always matches the assets actually present (this is what drops
# packages that were deleted from the release). Guarded so an empty repo dir
# cannot produce an empty database.
if compgen -G "repo/*.pkg.tar.zst" >/dev/null; then
  ( cd repo && rm -f "$REPO_NAME.db"* "$REPO_NAME.files"* &&
    repo-add --sign --key "$KEYID" "$REPO_NAME.db.tar.gz" ./*.pkg.tar.zst >/dev/null )
  publish
fi

(( fail == 0 )) || { echo "::error::one or more packages failed"; exit 1; }
