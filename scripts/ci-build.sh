#!/usr/bin/env bash
# Builds one or more packages and uploads them to the mayank-v4 release.
# Runs as the unprivileged `builder` user inside the Arch container.
#
# Two modes:
#   PUBLISH_DB=1 (default)  legacy single-job mode: build, publish db, state.
#   PUBLISH_DB=0            matrix mode: build, upload package + signature only.
#                           scripts/publish-db.sh owns the database afterwards.
#
# Recipes are never vendored for arch/aur/omarchy: they are fetched fresh on
# every build (scripts/lib.sh), so an upstream version bump always arrives with
# its matching PKGBUILD. Only `local:` specs live in pkgs/.
#
# Only CFLAGS differ from Arch: the workflow rewrites /etc/makepkg.conf to
# -march=znver4, so Arch's own patches and dependency graph are reused
# verbatim. pkgrel gets a ".1" suffix so pacman prefers our build over the
# stock one without ever outranking a newer upstream version.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=lib.sh
source scripts/lib.sh

: "${REPO_NAME:?}" "${GH_REPO:?}" "${KEYID:?}"

PUBLISH_DB=${PUBLISH_DB:-1}
mkdir -p repo out srcdest work

if [[ -z ${PKGS:-} ]]; then
  PKGS=$(pkg_specs | tr '\n' ' ')
fi
echo "packages: $PKGS"
echo "mode: PUBLISH_DB=$PUBLISH_DB"

# In matrix mode every job only needs state.json (to decide whether to skip);
# downloading the whole release per job would multiply the bandwidth by the
# number of parallel jobs for no reason.
if [[ $PUBLISH_DB == 1 ]]; then
  gh release download "$REPO_NAME" --repo "$GH_REPO" --dir repo --skip-existing || true
else
  gh release download "$REPO_NAME" --repo "$GH_REPO" --dir repo \
    --pattern state.json --skip-existing || true
fi
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
  gh release view "$REPO_NAME" --repo "$GH_REPO" >/dev/null 2>&1 && return 0
  # Matrix jobs can race here; losing the create to a sibling is success, not
  # failure, as long as the release exists afterwards.
  gh release create "$REPO_NAME" --repo "$GH_REPO" \
    --title "mayank-v4 pacman repository" \
    --notes "Signed x86-64-v4 packages built by GitHub Actions. pacman pulls updates through omarchy update." \
    >/dev/null 2>&1 || true
  gh release view "$REPO_NAME" --repo "$GH_REPO" >/dev/null 2>&1
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
for spec in $PKGS; do
  kind=$(pkg_kind "$spec")
  pkg=$(pkg_name "$spec")
  echo "::group::build $pkg ($kind)"
  echo "building $spec"

  src="$GITHUB_WORKSPACE/work/$pkg"
  if ! fetch_recipe "$kind" "$pkg" "$src" "$GITHUB_WORKSPACE/work/.omarchy-pkgs"; then
    echo "::error::could not fetch a recipe for $spec"
    fail=1; echo "::endgroup::"; continue
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
  asset_present=1
  if [[ $PUBLISH_DB == 1 ]]; then
    compgen -G "repo/${pkg}-*${pv}-*.pkg.tar.zst" >/dev/null || asset_present=0
  fi
  if [[ ${FORCE:-0} != 1 && -n $state_ver ]] &&
     (( $(vercmp "$state_ver" "$computed") >= 0 )) &&
     (( asset_present == 1 )); then
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

  build_conf=/etc/makepkg.conf
  extra_env=()
  case $pkg in
    # Some builds execute their own freshly compiled tools. V8 runs `torque`
    # and `mksnapshot` during `make`, and GitHub's runner pool mixes Intel
    # (AVX-512) with AMD EPYC (Zen 3, no AVX-512) - a znver4 torque binary
    # SIGILLs on EPYC, which is why nodejs failed intermittently. Build such
    # packages for x86-64-v3 (AVX2/BMI2, still well above baseline) and keep
    # -mtune=znver4, which only affects scheduling.
    nodejs)
      build_conf="$GITHUB_WORKSPACE/makepkg-v3.conf"
      sed 's/-march=znver4/-march=x86-64-v3/g' /etc/makepkg.conf >"$build_conf"
      echo "$pkg: building for x86-64-v3 so build-time tools can execute on any runner"
      ;;
    # Go ignores CFLAGS entirely; GOAMD64 is its equivalent of -march. v4 is
    # the x86-64-v4 microarchitecture level (AVX-512), matching znver4.
    cliamp)
      extra_env=(GOAMD64=v4)
      echo "$pkg: GOAMD64=v4 (Go has no CFLAGS)"
      ;;
  esac

  build_log="$GITHUB_WORKSPACE/build-$pkg.log"
  # Rust ignores CFLAGS. This value is what actually applies the target CPU in
  # two different situations:
  #   * build_conf is /etc/makepkg.conf -> makepkg then also sources
  #     ~/.makepkg.conf, and that file wins over the environment;
  #   * build_conf is an override file (nodejs, the v3 retry) -> makepkg does
  #     NOT source ~/.makepkg.conf at all, so this environment value is the
  #     only thing that applies.
  # Both are kept in sync, which is why fall_back_to_v3 rewrites both.
  rust_flags="-C target-cpu=znver4"
  makepkg_once() {
    ( cd "$src" && env "${extra_env[@]}" \
       PKGDEST="$GITHUB_WORKSPACE/out" SRCDEST="$GITHUB_WORKSPACE/srcdest" \
       RUSTFLAGS="$rust_flags" CARGO_BUILD_JOBS="$(nproc)" \
       makepkg --config "$build_conf" -s --noconfirm --nocheck --cleanbuild --sign --key "$KEYID" "${pgp_flags[@]}" ) \
      2>&1 | tee -a "$build_log"
  }

  # Anything that executes its own freshly compiled output during the build
  # dies on a runner without AVX-512: GitHub's pool mixes Intel (AVX-512) with
  # AMD EPYC (Zen 3, none). Rust is the common case - every proc-macro and
  # build script is compiled with RUSTFLAGS and then run - but C configure
  # probes hit it too. Falling back to x86-64-v3 (AVX2/BMI2/FMA, still far
  # above baseline) is what keeps a mixed runner pool from turning the repo red.
  fall_back_to_v3() {
    echo "::warning::$pkg: build-time tool SIGILL (runner has no AVX-512); rebuilding for x86-64-v3"
    rust_flags="-C target-cpu=x86-64-v3"
    cat >"$HOME/.makepkg.conf" <<EOF
RUSTFLAGS="-C force-frame-pointers=yes -C target-cpu=x86-64-v3"
CARGO_BUILD_JOBS="$(nproc)"
EOF
    build_conf="$GITHUB_WORKSPACE/makepkg-v3.conf"
    sed 's/-march=znver4/-march=x86-64-v3/g' /etc/makepkg.conf >"$build_conf"
    echo "$pkg: retrying with -march=x86-64-v3 / target-cpu=x86-64-v3"
  }

  if ! makepkg_once; then
    if grep -qE 'SIGILL|Illegal instruction' "$build_log"; then
      fall_back_to_v3
    elif grep -q 'PGP signatures could not be verified' "$build_log"; then
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
    # GitHub release assets cannot contain ':' (package epochs) and silently
    # rewrite it to '.'. Record the sanitized name in the database, otherwise
    # pacman requests a filename that does not exist and the transaction fails.
    safe_name=$(sanitize_asset_name "${f##*/}")
    cp "$f" "repo/$safe_name"
    if [[ -f $f.sig ]]; then
      cp "$f.sig" "repo/$safe_name.sig"
    else
      echo "::error::makepkg produced no signature for $(basename "$f")"
    fi
    changed+=("repo/$safe_name")
    # Report znver4 code generation; never fails unless STRICT_V4=1.
    ./scripts/verify-v4.sh "repo/$safe_name" || fail=1
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

  if [[ $PUBLISH_DB == 0 ]]; then
    # Matrix mode: package bytes only. publish-db.sh regenerates the database
    # and state.json once, after every build job has finished.
    ensure_release || { fail=1; echo "::endgroup::"; continue; }
    up_ok=1
    for f in "${uploads[@]}"; do upload_one "$f" || up_ok=0; done
    rm -f out/*
    if (( up_ok == 0 )); then
      echo "::error::upload failed for $pkg"
      fail=1; echo "::endgroup::"; continue
    fi
    built="$built $pkg"
    rm -rf srcdest
    echo "::endgroup::"
    continue
  fi

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
# skipped, so it matches the assets actually present. Matrix mode leaves this
# to publish-db.sh.
if [[ $PUBLISH_DB == 1 ]] && compgen -G "repo/*.pkg.tar.zst" >/dev/null; then
  publish
fi

(( fail == 0 )) || { echo "::error::one or more packages failed"; exit 1; }
