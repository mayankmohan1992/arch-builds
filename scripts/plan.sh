#!/usr/bin/env bash
# Emit the build matrix: the specs that still need a build.
#
# Usage: scripts/plan.sh [spec-or-name...]
#
# With no arguments, plans everything in packages.txt. With arguments, plans
# only those (bare names are mapped back to their spec via packages.txt, so the
# update timer can dispatch names alone).
#
# A package is skipped when state.json already records a version at least as
# new as what upstream ships. That is the same rule ci-build.sh applies per
# package; doing it here keeps the matrix from spinning up a container per
# already-current package.
#
# Output: a JSON array on stdout, e.g. ["aur:deckcraft","omarchy:owe"].
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=lib.sh
source scripts/lib.sh

state=${STATE_FILE:-repo/state.json}
[[ -f $state ]] || state=/dev/null

published_version() {
  [[ -s $state ]] || { echo ""; return; }
  python3 - "$state" "$1" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception:
    print("")
PY
}

specs=()
if (( $# )); then
  for arg in "$@"; do specs+=("$(pkg_spec_for_name "$arg")"); done
else
  while read -r spec; do specs+=("$spec"); done < <(pkg_specs)
fi

selected=()
skipped=0
failed_lookup=0
for spec in "${specs[@]}"; do
  kind=$(pkg_kind "$spec")
  name=$(pkg_name "$spec")

  if [[ ${FORCE:-0} == 1 ]]; then
    selected+=("$spec")
    continue
  fi

  published=$(published_version "$name")
  if [[ -z $published ]]; then
    selected+=("$spec")
    continue
  fi

  case $kind in
    local)
      # Vendored recipe: the checked-in PKGBUILD is the source of truth, so a
      # hand-bumped pkgver is picked up without any network call.
      upstream=$(local_version "$name") || upstream=""
      if [[ -z $upstream ]]; then
        echo "plan: $name: no readable pkgs/$name/PKGBUILD, planning it anyway" >&2
        failed_lookup=1
        selected+=("$spec")
        continue
      fi
      ;;
    *)
      if ! upstream=$(upstream_version "$kind" "$name"); then
        # Cannot tell: build anyway. ci-build.sh re-checks and no-ops if current.
        echo "plan: $name: upstream lookup failed, planning it anyway" >&2
        failed_lookup=1
        selected+=("$spec")
        continue
      fi
      ;;
  esac

  if (( $(vercmp "$published" "$upstream") >= 0 )); then
    echo "plan: $name: published=$published upstream=$upstream, current" >&2
    skipped=$((skipped + 1))
    continue
  fi
  echo "plan: $name: published=$published upstream=$upstream, needs build" >&2
  selected+=("$spec")
done

json=$(printf '%s\n' "${selected[@]}" | python3 -c '
import json, sys
items = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps(items))
')

echo "plan: ${#selected[@]} to build, $skipped current, $failed_lookup lookup failures" >&2
printf '%s\n' "$json"

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    echo "matrix=$json"
    if (( ${#selected[@]} )); then echo "any=true"; else echo "any=false"; fi
  } >>"$GITHUB_OUTPUT"
fi
