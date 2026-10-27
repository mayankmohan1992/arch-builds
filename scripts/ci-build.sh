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
  [[ -f $file ]] || { echo "::error::missing upload file $file"; return 1; }
  gh release delete-asset "$REPO_NAME" "$(basename "$file")" \
    --repo "$GH_REPO" --yes >/dev/null 2>&1 || true
  if ! gh release upload "$REPO_NAME" "$file" --repo "$GH_REPO"; then
    echo "::error::upload failed for $(basename "$file")"
    return 1
  fi
}

# The authoritative check is the pair we are about to upload: makepkg just
# signed it, so if it verifies locally the bytes are consistent.
verify_local() { # verify_local <pkg.tar.zst>
  local pkgfile=$1
  [[ -f $pkgfile && -f $pkgfile.sig ]] || { echo "::error::missing signature for $(basename "$pkgfile")"; return 1; }
  gpg --verify "$pkgfile.sig" "$pkgfile" >/dev/null 2>&1 || {
    echo "::error::local signature mismatch for $(basename "$pkgfile")"
    return 1
  }
}

# Remote check, best effort: GitHub's asset API is eventually consistent right
# after an upload, so a failure here must not destroy a good artifact. Retries
# with a delay, and only warns.
verify_remote() { # verify_remote <pkg.tar.zst>
  local pkgfile=$1 name dir attempt
  name=$(basename "$pkgfile")
  for attempt in 1 2 3; do
    sleep "$attempt"
    dir=$(mktemp -d)
    gh release download "$REPO_NAME" --repo "$GH_REPO" --pattern "$name" --dir "$dir" >/dev/null 2>&1 || true
    gh release download "$REPO_NAME" --repo "$GH_REPO" --pattern "$name.sig" --dir "$dir" >/dev/null 2>&1 || true
    if [[ -s $dir/$name && -s $dir/$name.sig ]] && gpg --verify "$dir/$name.sig" "$dir/$name" >/dev/null 2>&1; then
      rm -rf "$dir"
      return 0
    fi
    rm -rf "$dir"
  done
  echo "::warning::$name did not verify remotely after 3 attempts (upload may still be propagating)"
  return 1
}

state_version() { # state_version <pkg>
  python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2],""))
except Exception:
    print("")' repo/state.json "$1"
}

ensure_release() {
  gh release view "$REPO_NAME" --repo "$GH_REPO" >/dev/null 2>&1 ||
    gh release create "$REPO_NAME" --repo "$GH_REPO" \
      --title "mayank-v4 pacman repository" \
      --notes "Signed x86-64-v4 packages built by GitHub Actions. pacman pulls updates through omarchy update."
}

publish() { # publish <changed files...>
  regenerate_db || return 1
  ensure_release || return 1
  upload_one "repo/$REPO_NAME.db" || return 1
  upload_one "repo/$REPO_NAME.db.sig" || return 1
  upload_one repo/state.json || return 1
  local f
  for f in "$@"; do upload_one "$f" || return 1; done
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

  # Idempotent: skip when what is already published is at least as new as what
  # we would build now. Comparing with vercmp (not equality) is what makes a
  # bumped pkgrel (1.2 vs computed 1.1) settle instead of rebuilding forever.
  state_ver=$(state_version "$pkg")
  computed="$pv-$pr"
  if [[ ${FORCE:-0} != 1 && -n $state_ver ]] &&
     (( $(vercmp "$state_ver" "$computed") >= 0 )) &&
     compgen -G "repo/${pkg}-*${pv}-*.pkg.tar.zst" >/dev/null; then
    echo "$pkg $state_ver already published; skipping"
    echo "::endgroup::"
    continue
  fi

  # Only a deliberate repair (FORCE=1) bumps the version. Rebuilding because an
  # asset was missing must reuse the same version: there are no published bytes
  # under that name to collide with, and bumping on every hiccup caused
  # version churn.
  if [[ ${FORCE:-0} == 1 && -n $state_ver && ${state_ver%%-*} == "$pv" ]]; then
    new_pr=$(awk -F. 'BEGIN{OFS="."} { $NF = $NF + 1; print }' <<<"${state_ver##*-}")
    sed -i -E "s/^pkgrel=.*/pkgrel=$new_pr/" "$src/PKGBUILD"
    echo "repair rebuild $pkg: pkgrel $pr -> $new_pr"
    pr=$new_pr
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
    if [[ -f $f.sig ]]; then
      cp "$f.sig" repo/
    else
      echo "::error::makepkg produced no signature for $(basename "$f")"
    fi
    changed+=("repo/$(basename "$f")")
  done

  # Authoritative check: the pair we are about to upload must verify locally.
  local_ok=1
  for f in "${changed[@]}"; do
    verify_local "$f" || local_ok=0
  done
  if (( local_ok == 0 )); then
    echo "::error::$pkg: package/signature mismatch locally; not publishing"
    for f in "${changed[@]}"; do rm -f "$f" "$f.sig"; done
    fail=1; rm -f out/*; echo "::endgroup::"; continue
  fi

  uploads=()
  for f in "${changed[@]}"; do
    uploads+=("$f")
    [[ -f $f.sig ]] && uploads+=("$f.sig")
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
  if ! publish "${uploads[@]}"; then
    echo "::error::publish failed for $pkg"
    fail=1; echo "::endgroup::"; continue
  fi
  # Best-effort remote confirmation; never deletes a locally valid artifact.
  for f in "${changed[@]}"; do
    verify_remote "$f" || true
  done
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
