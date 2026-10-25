#!/usr/bin/env bash
# One-time (and idempotent) setup of the mayank-v4 pacman repository.
# Run with: sudo bash scripts/setup-local-repo.sh [--remove]
#
# Adds the repository above [core] so pacman prefers our pkgrel, trusts the
# signing key, and refreshes the databases. --remove reverses all of it.
set -euo pipefail

REPO=mayank-v4
OWNER_REPO=mayankmohan1992/arch-builds
BASE="https://github.com/$OWNER_REPO/releases/download/$REPO"
CONF=/etc/pacman.conf
KEYFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/keys/$REPO.asc"

[[ $EUID -eq 0 ]] || { echo "Run this with sudo." >&2; exit 1; }

remove_repo() {
  cp -a "$CONF" "$CONF.pre-$REPO-$(date +%Y%m%d-%H%M%S)"
  awk -v r="$REPO" '
    $0 == "[" r "]" { skip = 1; next }
    skip && /^\[/ { skip = 0 }
    !skip { print }
  ' "$CONF" >"$CONF.tmp"
  # Drop the blank line the stanza left behind.
  awk 'NF || prev { print } { prev = NF }' "$CONF.tmp" >"$CONF.tmp2"
  install -m644 "$CONF.tmp2" "$CONF"
  rm -f "$CONF.tmp" "$CONF.tmp2"
  echo "Removed [$REPO] from $CONF"
  echo "Run 'sudo pacman -Syyuu' to let stock packages win again."
}

if [[ ${1:-} == "--remove" ]]; then
  remove_repo
  exit 0
fi

if [[ ! -f $KEYFILE ]]; then
  echo "Missing $KEYFILE" >&2
  exit 1
fi

echo "==> trusting the $REPO signing key"
pacman-key --add "$KEYFILE"
pacman-key --lsign-key "$(gpg --show-keys --with-colons "$KEYFILE" | awk -F: '/^fpr:/{print $10; exit}')"

if grep -q "^\[$REPO\]" "$CONF"; then
  echo "==> [$REPO] already configured"
else
  cp -a "$CONF" "$CONF.pre-$REPO-$(date +%Y%m%d-%H%M%S)"
  tmp=$(mktemp)
  awk -v r="$REPO" -v base="$BASE" '
    /^\[core\]$/ && !done {
      print "[" r "]"
      print "Server = " base
      print "SigLevel = Required DatabaseRequired"
      print ""
      done = 1
    }
    { print }
  ' "$CONF" >"$tmp"
  grep -q "^\[$REPO\]" "$tmp" || { echo "no [core] section found" >&2; rm -f "$tmp"; exit 1; }
  install -m644 "$tmp" "$CONF"
  rm -f "$tmp"
  echo "==> added [$REPO] before [core]"
fi

echo "==> syncing"
pacman -Sy
echo
echo "Packages available from $REPO:"
pacman -Sl "$REPO" || true

# --- ALHP multilib v4 -------------------------------------------------------
# 44 of this machine's lib32-* packages are already built for x86-64-v4 in
# ALHP's multilib repository, which is not enabled by the ALHP guide's default
# two-repo stanza.
if [[ -f /etc/pacman.d/alhp-mirrorlist ]] && ! grep -q '^\[multilib-x86-64-v4\]' "$CONF"; then
  echo "==> enabling ALHP multilib-x86-64-v4"
  cp -a "$CONF" "$CONF.pre-alhp-multilib-$(date +%Y%m%d-%H%M%S)"
  tmp=$(mktemp)
  awk '
    /^\[multilib\]$/ && !done {
      print "[multilib-x86-64-v4]"
      print "Include = /etc/pacman.d/alhp-mirrorlist"
      print ""
      done = 1
    }
    { print }
  ' "$CONF" >"$tmp"
  if grep -q '^\[multilib-x86-64-v4\]' "$tmp"; then
    install -m644 "$tmp" "$CONF"
    rm -f "$tmp"
    pacman -Sy
  else
    rm -f "$tmp"
    echo "no [multilib] section found; skipped" >&2
  fi
fi
