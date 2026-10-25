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
# -march=znver4, so Arch's own patches and dependency graph are reused
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

regenerate_db() {
  ( cd repo
    rm -f "$REPO_NAME.db"* "$REPO_NAME.files"*
    repo-add --sign --key "$KEYID" "$REPO_NAME.db.tar.gz" ./*.pkg.tar.zst >/dev/null
    # pacman requests <repo>.db by name, but repo-add leaves a symlink to the
    # tarball; dereference so the uploaded asset is the real file.
    for f in "$REPO_NAME.db" "$REPO_NAME.db.sig" "$REPO_NAME.files" "$REPO_NAME.files.sig"; do
      [ -L "$f" ] && { cp -L "$f" "$f.real" && mv -f "$f.real" "$f"; }
    done
    rm -f "$REPO_NAME.db.tar.gz"* "$REPO_NAME.files.tar.gz"* )
}

# Delete-then-upload. `gh release upload --clobber` intermittently fails with
# HTTP 422 "ReleaseAsset.name already exists" when the asset set is re-uploaded,
# which silently dropped a built package. Uploading only changed files and
# removing the old asset first avoids both the race and the API churn.
upload_one() {
  local file=$1
  [[ -f $file ]] || return 0
  gh release delete-asset "$REPO_NAME" "$(basename "$file")" \
    --repo "$GH_REPO" --yes >/dev/null 2>&1 || true
  gh release upload "$REPO_NAME" "$file" --repo "$GH_REPO"
}

ensure_release() {
  gh release view "$REPO_NAME" --repo "$GH_REPO" >/dev/null 2>&1 ||
    gh release create "$REPO_NAME" --repo "$GH_REPO" \
      --title "mayank-v4 pacman repository" \
      --notes "Signed x86-64-v4 packages built by GitHub Actions. pacman pulls updates through omarchy update."
}

publish() { # publish <changed files...>
  regenerate_db
  ensure_release
  upload_one "repo/$REPO_NAME.db"
  upload_one "repo/$REPO_NAME.db.sig"
  upload_one repo/state.json
  local f
  for f in "$@"; do upload_one "$f"; done
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
    # Some packaging repositories nest the recipe one level deeper.
    if [[ ! -f $src/PKGBUILD ]]; then
      inner=$(find "$src" -maxdepth 2 -type f -name PKGBUILD -printf '%h\n' 2>/dev/null | head -1)
      if [[ -n $inner ]]; then
        src=$inner
      else
        echo "::error::$pkg has no PKGBUILD (stub package? see packages.txt)"
        fail=1; echo "::endgroup::"; continue
      fi
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

  # Most upstream keys now come from Arch's packager keyring (imported by the
  # workflow). Anything missing is fetched as a best-effort fallback.
  mapfile -t vkeys < <(cd "$src" && makepkg --printsrcinfo |
    awk -F' = ' '/^\tvalidpgpkeys/{print $2}')
  pgp_flags=()
  for k in "${vkeys[@]}"; do
    [[ -z $k ]] && continue
    gpg --batch --list-keys "$k" >/dev/null 2>&1 && continue
    if gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$k" >/dev/null 2>&1 ||
       gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$k" >/dev/null 2>&1; then
      continue
    fi
    echo "::warning::$pkg: key $k not retrievable; using --skippgpcheck (checksums still enforced)"
    pgp_flags=(--skippgpcheck)
  done

  build_log="$GITHUB_WORKSPACE/build-$pkg.log"
  makepkg_once() {
    ( cd "$src" && PKGDEST="$GITHUB_WORKSPACE/out" SRCDEST="$GITHUB_WORKSPACE/srcdest" \
       RUSTFLAGS="-C target-cpu=znver4" CARGO_BUILD_JOBS="$(nproc)" \
       makepkg -s --noconfirm --nocheck --cleanbuild --sign --key "$KEYID" "${pgp_flags[@]}" ) \
      2>&1 | tee -a "$build_log"
  }

  if ! makepkg_once; then
    if grep -q 'PGP signatures could not be verified' "$build_log"; then
      # Covers the case where a key is present but the signing subkey is not.
      echo "::warning::$pkg: signature verification failed; retrying with --skippgpcheck"
      pgp_flags=(--skippgpcheck)
    else
      echo "::warning::$pkg: first attempt failed; retrying once"
    fi
    rm -f "$GITHUB_WORKSPACE"/out/*
    if ! makepkg_once; then
      echo "::error::build failed: $pkg"
      tail -n 30 "$build_log" || true
      fail=1; echo "::endgroup::"; continue
    fi
  fi

  changed=()
  for f in out/*.pkg.tar.zst; do
    [[ -e $f ]] || continue
    cp "$f" repo/
    changed+=("repo/$(basename "$f")")
    if [[ -f $f.sig ]]; then
      cp "$f.sig" repo/
      changed+=("repo/$(basename "$f").sig")
    fi
  done
  python3 - "$pv-$pr" "$pkg" <<'PY'
import json, sys
version, pkg = sys.argv[1], sys.argv[2]
path = "repo/state.json"
state = json.load(open(path)) if __import__("os").path.exists(path) else {}
state[pkg] = version
json.dump(state, open(path, "w"), indent=2, sort_keys=True)
PY
  rm -f out/*
  publish "${changed[@]}"
  built="$built $pkg"
  # Bound disk use on the 14 GB runner.
  rm -rf srcdest
  echo "::endgroup::"
done

echo "built:$built"

# Always refresh the database once at the end, even when every package was
# skipped, so it matches the assets actually present.
if compgen -G "repo/*.pkg.tar.zst" >/dev/null; then
  publish
fi

(( fail == 0 )) || { echo "::error::one or more packages failed"; exit 1; }
