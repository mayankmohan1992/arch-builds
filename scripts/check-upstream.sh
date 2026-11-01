#!/usr/bin/env bash
# Runs from a systemd user timer. Compares the versions published in the
# mayank-v4 repository against what each upstream currently ships, and
# dispatches a GitHub Actions build only for packages that are missing or
# behind. Nothing is rebuilt when nothing upstream moved.
#
# Upstream sources, by spec kind (see scripts/lib.sh):
#   arch      archlinux.org package API
#   aur       AUR RPC
#   omarchy   omacom/omarchy-pkgs PKGBUILD on the master branch
#   local     no upstream to ask; bumped by hand, always skipped here
#
# Deliberately NOT a GitHub `schedule:` workflow: GitHub disables scheduled
# workflows in public repositories after 60 days without repository activity.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=lib.sh
source scripts/lib.sh

REPO="mayankmohan1992/arch-builds"
TAG="mayank-v4"
STATE_URL="https://github.com/$REPO/releases/download/$TAG/state.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"
LOG="$STATE_DIR/arch-builds.log"
DRY_RUN=0
[[ ${1:-} == --dry-run ]] && DRY_RUN=1

mkdir -p "$STATE_DIR"
log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

if (( DRY_RUN == 0 )); then
  if ! command -v gh >/dev/null; then log "gh missing"; exit 1; fi
  if ! gh auth status >/dev/null 2>&1; then log "gh not authenticated"; exit 1; fi
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -sfL "$STATE_URL" -o "$tmp/state.json" 2>/dev/null || echo '{}' >"$tmp/state.json"

need=()
lookup_failed=0
while read -r spec; do
  kind=$(pkg_kind "$spec")
  pkg=$(pkg_name "$spec")

  case $kind in
    local)
      # Vendored recipe: no upstream to ask. The checked-in PKGBUILD is the
      # truth, so a hand-bumped pkgver is dispatched automatically.
      if ! upstream=$(local_version "$pkg"); then
        log "$pkg: no readable pkgs/$pkg/PKGBUILD; leaving it alone"
        lookup_failed=1
        continue
      fi
      ;;
    *)
      if ! upstream=$(upstream_version "$kind" "$pkg"); then
        log "$pkg: $kind upstream lookup failed; leaving it alone"
        lookup_failed=1
        continue
      fi
      ;;
  esac

  # CI publishes <pkgver>-<pkgrel>.1
  published=$(python3 -c 'import json,sys
state=json.load(open(sys.argv[1]))
print(state.get(sys.argv[2],""))' "$tmp/state.json" "$pkg")

  # Queue only when what we published is strictly behind upstream. Comparing
  # with vercmp (not equality against "<upstream>.1") is what stops the timer
  # re-queueing packages whose pkgrel was legitimately bumped
  # (git 2.56.0-2.1 vs upstream 2.56.0-1 was being re-dispatched every run).
  # A vendored recipe that has not been bumped compares equal, so it is quiet.
  if [[ -z $published ]] || (( $(vercmp "$published" "$upstream") < 0 )); then
    log "$pkg ($kind): published=${published:-none} upstream=$upstream -> queue"
    need+=("$pkg")
  fi
done < <(pkg_specs)

if (( ${#need[@]} == 0 )); then
  if (( lookup_failed )); then
    log "some upstream lookups failed; not dispatching"
  else
    log "all managed packages current"
  fi
  exit 0
fi

if (( DRY_RUN == 1 )); then
  log "dry run: would dispatch build: ${need[*]}"
  exit 0
fi

log "dispatching build: ${need[*]}"
gh workflow run build.yml --repo "$REPO" -f pkgs="${need[*]}" >>"$LOG" 2>&1
log "dispatched"
