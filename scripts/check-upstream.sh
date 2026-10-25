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
while read -r pkg; do
  [[ -z $pkg || $pkg == \#* ]] && continue
  # vendored recipes (pkgs/<name>) have their own upstream tracking
  [[ -d "$(dirname "$MANAGED")/pkgs/$pkg" ]] && continue

  if ! curl -sfL "https://archlinux.org/packages/search/json/?name=$pkg" -o "$tmp/$pkg.json"; then
    log "$pkg: upstream lookup failed; leaving it alone"
    lookup_failed=1
    continue
  fi
  upstream=$(python3 -c 'import json,sys
r = (json.load(open(sys.argv[1])).get("results") or [{}])[0]
print("{}-{}".format(r.get("pkgver", ""), r.get("pkgrel", "")))' "$tmp/$pkg.json" 2>/dev/null) || upstream=""
  if [[ -z $upstream || $upstream == "-" ]]; then
    log "$pkg: could not parse upstream version"
    lookup_failed=1
    continue
  fi

  # CI publishes <pkgver>-<pkgrel>.1
  published=$(python3 -c 'import json,sys
state=json.load(open(sys.argv[1]))
print(state.get(sys.argv[2],""))' "$tmp/state.json" "$pkg")
  expected="$upstream.1"

  if [[ $published != "$expected" ]]; then
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
