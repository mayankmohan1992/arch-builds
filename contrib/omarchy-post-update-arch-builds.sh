#!/usr/bin/env bash
# Installed to ~/.config/omarchy/hooks/post-update.d/40-arch-builds-check.sh.
#
# `omarchy update` installs the highest version across every configured
# repository. When Omarchy publishes a newer omafeed (or any other managed
# package) than our `pkgrel .1` build, pacman correctly takes the stock one.
# This hook dispatches the arch-builds rebuild in that same update, so the
# window where a non-optimised build is installed is minutes instead of the
# timer's six hours. The next `omarchy update` installs the optimised build.
#
# GH_TOKEN comes from the same EnvironmentFile the user timer uses; the gh
# keyring can be locked when this runs.
set -u

token_file="$HOME/.config/arch-builds/gh.env"
if [[ -r $token_file ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$token_file"
  set +a
fi

check="$HOME/arch-builds/scripts/check-upstream.sh"
[[ -x $check ]] || exit 0
GH_PROMPT_DISABLED=1 "$check" || true
