#!/usr/bin/env bash
# Ensure the [mayank-v4] repository exists and carries both download endpoints.
# Omarchy calls the pre-refresh-pacman hooks before every `pacman -Sy`, so this
# also repairs /etc/pacman.conf after Omarchy rewrites it. Idempotent.
#
# Two Server lines, in order:
#   1. the pinned tag  (/releases/download/mayank-v4) - canonical
#   2. the latest release (/releases/latest/download) - fallback
#
# On 2026-11-08 GitHub's pinned-tag release endpoint returned 504 for every
# repository (ripgrep too) while /releases/latest/download kept working, which
# made `omarchy update` fail at database sync. pacman tries the next Server
# when one fails, so the fallback keeps updates flowing through that outage.
# The fallback is only valid while mayank-v4 is this repository's latest
# release, which it always is: the publish job only ever writes that tag.
set -euo pipefail

REPO=mayank-v4
OWNER_REPO=mayankmohan1992/arch-builds
BASE_TAG="https://github.com/$OWNER_REPO/releases/download/$REPO"
BASE_LATEST="https://github.com/$OWNER_REPO/releases/latest/download"
conf=/etc/pacman.conf

if grep -q "^\[$REPO\]" "$conf" &&
   grep -qxF "Server = $BASE_TAG" "$conf" &&
   grep -qxF "Server = $BASE_LATEST" "$conf"; then
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Drop an existing stanza, then insert the canonical one before [core].
awk -v r="$REPO" '
  $0 == "[" r "]" { skip = 1; next }
  skip && /^\[/ { skip = 0 }
  !skip { print }
' "$conf" | awk -v r="$REPO" -v tag="$BASE_TAG" -v latest="$BASE_LATEST" '
  /^\[core\]$/ && !done {
    print "[" r "]"
    print "Server = " tag
    print "Server = " latest
    print "SigLevel = Required DatabaseRequired"
    print ""
    done = 1
  }
  { print }
' >"$tmp"

if ! grep -q "^\[core\]" "$tmp"; then
  echo "could not find a [core] section; leaving pacman.conf untouched" >&2
  exit 0
fi

sudo install -m644 "$tmp" "$conf"
echo "Restored [$REPO] in $conf (pinned tag + latest fallback)"
