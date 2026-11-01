#!/usr/bin/env bash
# Audit a built package for znver4 code generation.
#
# This is the regression detector for the failure that shipped baseline x86-64
# binaries for weeks: makepkg sources the *builder's* ~/.makepkg.conf last, so a
# RUSTFLAGS exported in the job environment is silently ignored. The flag
# assertions in the workflow catch the config side; this catches the output side.
#
# Measured reference points on this machine (Ryzen 5 7600):
#   starship  zmm=33529   Rust, vectorised
#   usage     zmm=35033   Rust, vectorised
#   gridcraft zmm=112552  Rust, vectorised
#   git       zmm=7983    C, vectorised
#   tldr      zmm=0       Go binary, CFLAGS never applied
#   semver    zmm=0       Rust, too small to vectorise
#
# Because zero is legitimate for some packages, this warns and reports rather
# than failing. Set STRICT_V4=1 to turn a zero count into a hard failure for
# packages that are expected to vectorise.
set -uo pipefail

pkgfile=${1:?usage: verify-v4.sh <pkg.tar.zst>}
name=${pkgfile##*/}
name=${name%%.pkg.tar.zst}

if [[ ! -f $pkgfile ]]; then
  echo "::error::verify-v4: missing $pkgfile"
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# .MTREE/.PKGINFO are metadata; only real files matter.
bsdtar -xf "$pkgfile" -C "$work" 2>/dev/null || {
  echo "::warning::verify-v4: could not extract $name"
  exit 0
}

# objdump on a 100 MB binary takes minutes and tells us nothing new: nodejs is
# built for x86-64-v3 on purpose (its torque/mksnapshot tools run during the
# build and SIGILL on Zen 3 runners).
case $name in
  nodejs|*-debug) echo "verify-v4: $name skipped by policy"; exit 0 ;;
esac

zmm_total=0
ymm_total=0
audited=0
skipped=0

while IFS= read -r -d '' f; do
  # Cap the work: a 30 MB+ object is either an interpreter or a data blob.
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if (( size > 30000000 )); then
    skipped=$((skipped + 1))
    continue
  fi
  head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF' || continue
  dis=$(timeout 120 objdump -d --no-show-raw-insn "$f" 2>/dev/null) || continue
  z=$(grep -c 'zmm' <<<"$dis" || true)
  y=$(grep -c 'ymm' <<<"$dis" || true)
  zmm_total=$((zmm_total + z))
  ymm_total=$((ymm_total + y))
  audited=$((audited + 1))
done < <(find "$work" -type f \( -path '*/usr/bin/*' -o -path '*/usr/lib/*' -o -path '*/usr/lib64/*' \) -print0 2>/dev/null)

echo "verify-v4: $name  files=$audited skipped=$skipped  zmm=$zmm_total ymm=$ymm_total"

if (( audited == 0 )); then
  echo "verify-v4: $name has no auditable ELF payload (data/script package)"
  exit 0
fi

if (( zmm_total == 0 && ymm_total == 0 )); then
  if [[ ${STRICT_V4:-0} == 1 ]]; then
    echo "::error::$name contains no AVX instructions at all - built for baseline x86-64?"
    exit 1
  fi
  echo "::warning::$name contains no AVX instructions (fine for Go/tiny binaries, suspicious for C/C++/Rust)"
fi

exit 0
