#!/usr/bin/env bash
# Runs from a systemd user timer. Compares the versions published in the
# mayank-v4 repository against what Arch currently ships, and dispatches a
# GitHub Actions build only for packages that are missing or behind.
#
# Deliberately NOT a GitHub `schedule:` workflow: GitHub disables scheduled
# workflows in public repositories after 60 days without repository activity.
set -euo pipefail

REPO="mayankmohan1992/arch-builds"
TAG="mayank-v4"
STATE_URL="https://github.com/$REPO/releases/download/$TAG/state.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"
LOG="$STATE_DIR/arch-builds.log"
MANAGED="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/packages.txt"

mkdir -p "$STATE_DIR"
log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

if ! command -v gh >/dev/null; then log "gh missing"; exit 1; fi
if ! gh auth status >/dev/null 2>&1; then log "gh not authenticated"; exit 1; fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -sfL "$STATE_URL" -o "$tmp/state.json" 2>/dev/null || echo '{}' >"$tmp/state.json"

need=()
lookup_failed=0
repo_root=$(dirname "$MANAGED")
while read -r pkg; do
  [[ -z $pkg || $pkg == \#* ]] && continue

  if [[ -d "$repo_root/pkgs/$pkg" ]]; then
    # Vendored recipe (AUR/custom): track the AUR version, which carries both
    # pkgver and pkgrel in a single string.
    if ! curl -sfL "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkg" -o "$tmp/$pkg.json"; then
      log "$pkg: AUR lookup failed; leaving it alone"
      lookup_failed=1
      continue
    fi
    upstream=$(python3 -c 'import json,sys
r = (json.load(open(sys.argv[1])).get("results") or [{}])[0]
print(r.get("Version", ""))' "$tmp/$pkg.json" 2>/dev/null) || upstream=""
    if [[ -z $upstream ]]; then
      # Not in the AUR at all: nothing to compare against, leave it alone.
      log "$pkg: not found in AUR; skipping version check"
      continue
    fi
  else
    if ! curl -sfL "https://archlinux.org/packages/search/json/?name=$pkg" -o "$tmp/$pkg.json"; then
      log "$pkg: upstream lookup failed; leaving it alone"
      lookup_failed=1
      continue
    fi
    upstream=$(python3 -c 'import json,sys
r = (json.load(open(sys.argv[1])).get("results") or [{}])[0]
print("{}-{}".format(r.get("pkgver", ""), r.get("pkgrel", "")))' "$tmp/$pkg.json" 2>/dev/null) || upstream=""
  fi

  if [[ -z $upstream || $upstream == "-" ]]; then
    log "$pkg: could not parse upstream version"
    lookup_failed=1
    continue
  fi

  # CI publishes <pkgver>-<pkgrel>.1
  published=$(python3 -c 'import json,sys
state=json.load(open(sys.argv[1]))
print(state.get(sys.argv[2],""))' "$tmp/state.json" "$pkg")
  # Queue only when what we published is not at least as new as upstream.
  # Comparing with vercmp instead of equality against "<upstream>.1" is what
  # stops the timer re-queueing packages whose pkgrel was legitimately bumped
  # (git 2.56.0-2.1 vs upstream 2.56.0-1 was being re-dispatched every run).
  if [[ -z $published ]] || (( $(vercmp "$published" "$upstream") <= 0 )); then
    log "$pkg: published=${published:-none} upstream=$upstream -> queue"
    need+=("$pkg")
  fi
done <"$MANAGED"

if (( ${#need[@]} == 0 )); then
  if (( lookup_failed )); then
    log "some upstream lookups failed; not dispatching"
  else
    log "all managed packages current"
  fi
  exit 0
fi

log "dispatching build: ${need[*]}"
gh workflow run build.yml --repo "$REPO" -f pkgs="${need[*]}" >>"$LOG" 2>&1
log "dispatched"
