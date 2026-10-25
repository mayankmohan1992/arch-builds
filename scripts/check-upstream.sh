#!/usr/bin/env bash
# Report when an upstream project has a newer release than the PKGBUILD pins.
#
# Report-only on purpose: the xmrig-cuda clockRate patch has to keep applying
# across upstream releases, so a bump should be reviewed and tested rather than
# committed by a timer.
#
# Exit status: 0 = everything current, 1 = at least one package is behind.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

latest_tag() { # latest_tag <owner/repo>
  local tag
  tag=$(curl -sfL "https://api.github.com/repos/$1/releases/latest" |
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null) || tag=""
  printf '%s' "${tag#v}"
}

pkgbuild_var() { # pkgbuild_var <file> <name>
  sed -n "s/^$2=//p" "$1" | tr -d "'\"" | head -1
}

behind=0
printf '%-22s %-12s %-12s %s\n' PACKAGE PINNED UPSTREAM STATUS

file=pkgs/xmrig-cuda-tuned/PKGBUILD
pinned=$(pkgbuild_var "$file" pkgver)
up=$(latest_tag xmrig/xmrig)
if [[ -n $up && $up != "$pinned" ]]; then
  printf '%-22s %-12s %-12s %s\n' xmrig "$pinned" "$up" "behind"
  behind=1
else
  printf '%-22s %-12s %-12s %s\n' xmrig "$pinned" "${up:-unknown}" ok
fi

pinned=$(pkgbuild_var "$file" _cudaver)
up=$(latest_tag xmrig/xmrig-cuda)
if [[ -n $up && $up != "$pinned" ]]; then
  printf '%-22s %-12s %-12s %s\n' xmrig-cuda "$pinned" "$up" "behind"
  behind=1
else
  printf '%-22s %-12s %-12s %s\n' xmrig-cuda "$pinned" "${up:-unknown}" ok
fi

if (( behind )); then
  echo
  echo "Bump pkgver/_cudaver, refresh sha256sums, rebuild locally once to prove"
  echo "the patch still applies, then push to trigger the CI build."
  exit 1
fi

echo
echo "All packages match upstream."
