#!/usr/bin/env bash
# Shared helpers for the mayank-v4 pipeline. Sourced, never executed.
#
# packages.txt is the single source of truth. A line is a *spec*:
#
#   git                  Arch official packaging (gitlab.archlinux.org)
#   aur:deckcraft        AUR recipe, cloned at build time
#   omarchy:owe          omacom/omarchy-pkgs recipe, sparse-checked out
#   local:gupax          hand-written recipe in pkgs/gupax
#
# Recipes for arch/aur/omarchy are fetched fresh on every build, so an upstream
# version bump always brings the matching recipe with it. Nothing is vendored
# except local:, which is why "rebuild only when upstream moved" works without
# anyone bumping a PKGBUILD by hand.

OMARCHY_PKGS_REPO="${OMARCHY_PKGS_REPO:-https://github.com/omacom/omarchy-pkgs.git}"
OMARCHY_PKGS_REF="${OMARCHY_PKGS_REF:-master}"
OMARCHY_PKGS_RAW="${OMARCHY_PKGS_RAW:-https://raw.githubusercontent.com/omacom/omarchy-pkgs/$OMARCHY_PKGS_REF}"

# Print every spec in packages.txt, comments and blanks removed.
pkg_specs() {
  grep -vE '^[[:space:]]*(#|$)' "${1:-packages.txt}"
}

# "aur:deckcraft" -> "aur";  "git" -> "arch"
pkg_kind() {
  if [[ $1 == *:* ]]; then echo "${1%%:*}"; else echo arch; fi
}

# "aur:deckcraft" -> "deckcraft";  "git" -> "git"
pkg_name() {
  if [[ $1 == *:* ]]; then echo "${1#*:}"; else echo "$1"; fi
}

# Map a bare package name back to its spec, so the update timer can dispatch
# names without knowing their source kind. Unknown names fall back to arch.
pkg_spec_for_name() {
  local want=$1 spec
  while read -r spec; do
    [[ $(pkg_name "$spec") == "$want" ]] && { echo "$spec"; return 0; }
  done < <(pkg_specs "${2:-packages.txt}")
  echo "$want"
}

# Print "<pkgver>-<pkgrel>" for what upstream currently ships.
# Returns 1 (and prints nothing) when the version cannot be determined.
upstream_version() {
  local kind=$1 name=$2 tmp json
  tmp=$(mktemp)
  case $kind in
    arch)
      curl -sfL --max-time 30 \
        "https://archlinux.org/packages/search/json/?name=$name" -o "$tmp" || { rm -f "$tmp"; return 1; }
      json=$(python3 - "$tmp" <<'PY'
import json, sys
r = (json.load(open(sys.argv[1])).get("results") or [{}])[0]
print("{}-{}".format(r.get("pkgver", ""), r.get("pkgrel", "")))
PY
      ) || { rm -f "$tmp"; return 1; }
      ;;
    aur)
      curl -sfL --max-time 30 \
        "https://aur.archlinux.org/rpc/v5/info?arg[]=$name" -o "$tmp" || { rm -f "$tmp"; return 1; }
      json=$(python3 - "$tmp" <<'PY'
import json, sys
r = (json.load(open(sys.argv[1])).get("results") or [{}])[0]
print(r.get("Version", ""))
PY
      ) || { rm -f "$tmp"; return 1; }
      ;;
    omarchy)
      curl -sfL --max-time 30 \
        "$OMARCHY_PKGS_RAW/pkgbuilds/$name/PKGBUILD" -o "$tmp" || { rm -f "$tmp"; return 1; }
      json=$(awk -F= '
        /^pkgver=/ {v = $2}
        /^pkgrel=/ {r = $2}
        END {if (v != "") printf "%s-%s", v, r}
      ' "$tmp")
      ;;
    *)
      # local: recipes have no upstream to ask; they are bumped by hand.
      rm -f "$tmp"
      return 1
      ;;
  esac
  rm -f "$tmp"
  [[ -n ${json:-} && $json != "-" ]] || return 1
  printf '%s\n' "$json"
}

# Print "<pkgver>-<pkgrel>" for a vendored recipe in pkgs/<name>.
# No network: these are bumped by hand, so the checked-in file is the truth.
local_version() {
  local name=$1 f="pkgs/$1/PKGBUILD" v r
  [[ -f $f ]] || return 1
  v=$(awk -F= '/^pkgver=/{print $2; exit}' "$f")
  r=$(awk -F= '/^pkgrel=/{print $2; exit}' "$f")
  [[ -n $v && -n $r ]] || return 1
  printf '%s-%s\n' "$v" "$r"
}

# Populate <dest> with a buildable recipe for <kind>:<name>.
# <cache> is a scratch dir reused for the omarchy sparse clone.
fetch_recipe() {
  local kind=$1 name=$2 dest=$3 cache=$4
  rm -rf "$dest"
  mkdir -p "$dest"

  case $kind in
    arch)
      curl -sfL --max-time 120 \
        "https://gitlab.archlinux.org/archlinux/packaging/packages/$name/-/archive/main/$name-main.tar.gz" |
        tar xz -C "$dest" --strip-components=1 || return 1
      # Some packaging repositories nest the recipe one level deeper.
      if [[ ! -f $dest/PKGBUILD ]]; then
        local inner
        inner=$(find "$dest" -maxdepth 2 -type f -name PKGBUILD -printf '%h\n' 2>/dev/null | head -1)
        [[ -n $inner ]] || return 1
        # Move the nested recipe up so the caller has one layout to deal with.
        shopt -s dotglob
        mv "$inner"/* "$dest"/ 2>/dev/null || true
        shopt -u dotglob
      fi
      ;;
    aur)
      git clone --depth 1 -q "https://aur.archlinux.org/$name.git" "$dest" || return 1
      ;;
    omarchy)
      if [[ ! -d $cache/.git ]]; then
        rm -rf "$cache"
        git clone --depth 1 --filter=blob:none --sparse -q "$OMARCHY_PKGS_REPO" "$cache" || return 1
        git -C "$cache" checkout -q "$OMARCHY_PKGS_REF" 2>/dev/null || true
        git -C "$cache" sparse-checkout set "pkgbuilds/$name" || return 1
      else
        git -C "$cache" sparse-checkout add "pkgbuilds/$name" || return 1
      fi
      [[ -d $cache/pkgbuilds/$name ]] || return 1
      cp -a "$cache/pkgbuilds/$name/." "$dest"/ || return 1
      ;;
    local)
      [[ -d pkgs/$name ]] || return 1
      cp -a "pkgs/$name/." "$dest"/ || return 1
      ;;
    *)
      return 1
      ;;
  esac

  [[ -f $dest/PKGBUILD ]] || return 1
  return 0
}

# Repo asset names cannot contain ':' (package epochs). GitHub silently rewrites
# it to '.', so we strip it everywhere and record the stripped name in the db.
sanitize_asset_name() {
  local n=$1
  printf '%s\n' "${n//:/}"
}
