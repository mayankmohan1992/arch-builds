#!/usr/bin/env bash
# Regenerate the pacman database and state.json from the release assets.
#
# Runs once at the end of a run, after the per-package build jobs have uploaded
# their packages. Splitting this out is what lets the build jobs run in a
# matrix: they upload package files (disjoint names, no conflict) and never
# touch the database, so there is exactly one writer for the db and state.
#
# state.json is derived from each package's .PKGINFO, not from filenames:
# epochs contain ':' which GitHub rewrites, so a filename is not a reliable
# source of truth for a version.
#
# PRUNE=1 also deletes superseded versions of a package (keeping the newest per
# package name). Without it the release accumulates one copy per rebuild, the
# database grows, and every publish job downloads all of them.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${REPO_NAME:?}" "${GH_REPO:?}" "${KEYID:?}"

mkdir -p repo
gh release download "$REPO_NAME" --repo "$GH_REPO" --dir repo --skip-existing || true

if ! compgen -G "repo/*.pkg.tar.zst" >/dev/null; then
  echo "publish-db: no packages in the release; nothing to publish"
  exit 0
fi

echo "publish-db: $(compgen -G 'repo/*.pkg.tar.zst' | wc -l) package files"

# --- state.json (+ prune list) ---------------------------------------------
PRUNE=${PRUNE:-1} python3 - <<'PY'
import functools, glob, json, os, re, subprocess, sys

def vcmp(a, b):
    out = subprocess.run(["vercmp", a, b], capture_output=True, text=True).stdout.strip()
    return int(out or 0)

records = []
for pkg in sorted(glob.glob("repo/*.pkg.tar.zst")):
    try:
        info = subprocess.check_output(
            ["bsdtar", "-xOf", pkg, ".PKGINFO"], stderr=subprocess.DEVNULL
        ).decode("utf-8", "replace")
    except subprocess.CalledProcessError:
        print(f"publish-db: WARNING no .PKGINFO in {pkg}", file=sys.stderr)
        continue
    fields = {}
    for line in info.splitlines():
        m = re.match(r"^(pkgname|pkgbase|pkgver)\s*=\s*(.+)$", line.strip())
        if m:
            fields[m.group(1)] = m.group(2).strip()
    if not fields.get("pkgver") or not fields.get("pkgname"):
        continue
    records.append({
        "file": pkg,
        "name": fields["pkgname"],
        "base": fields.get("pkgbase", ""),
        "ver": fields["pkgver"],
    })

# One entry per package and per pkgbase, at the newest version seen.
state = {}
for r in records:
    for key in {r["name"], r["base"]}:
        if not key:
            continue
        if key not in state or vcmp(r["ver"], state[key]) > 0:
            state[key] = r["ver"]

json.dump(state, open("repo/state.json", "w"), indent=2, sort_keys=True)
print(f"publish-db: state.json has {len(state)} entries", file=sys.stderr)

# Superseded versions of the same package name, newest kept.
stale = []
if os.environ.get("PRUNE", "1") == "1":
    groups = {}
    for r in records:
        groups.setdefault(r["name"], []).append(r)
    for name, rs in groups.items():
        if len(rs) < 2:
            continue
        rs.sort(key=functools.cmp_to_key(lambda a, b: vcmp(a["ver"], b["ver"])))
        for r in rs[:-1]:
            stale.append(r["file"])

with open("repo/.prune", "w") as fh:
    # Trailing newline matters: the shell loop reads this with `while read`,
    # which silently drops a final line that has no terminator.
    if stale:
        fh.write("\n".join(stale) + "\n")
print(f"publish-db: {len(stale)} superseded files to prune", file=sys.stderr)
PY

# --- prune ------------------------------------------------------------------
if [[ -s repo/.prune ]]; then
  while IFS= read -r f; do
    [[ -n $f && -f $f ]] || continue
    echo "publish-db: pruning $(basename "$f")"
    for suffix in "" ".sig"; do
      local_file="${f}${suffix}"
      gh release delete-asset "$REPO_NAME" "$(basename "$local_file")" \
        --repo "$GH_REPO" --yes >/dev/null 2>&1 || true
      rm -f "$local_file"
    done
  done <repo/.prune
fi
rm -f repo/.prune

# --- database ---------------------------------------------------------------
( cd repo
  rm -f "$REPO_NAME.db"* "$REPO_NAME.files"*
  repo-add --sign --key "$KEYID" "$REPO_NAME.db.tar.gz" ./*.pkg.tar.zst >/dev/null || exit 1
  # pacman requests <repo>.db by name, but repo-add leaves a symlink to the
  # tarball; dereference so the uploaded asset is the real file.
  for f in "$REPO_NAME.db" "$REPO_NAME.db.sig" "$REPO_NAME.files" "$REPO_NAME.files.sig"; do
    if [[ -L $f ]]; then cp -L "$f" "$f.real" && mv -f "$f.real" "$f"; fi
  done
  rm -f "$REPO_NAME.db.tar.gz"* "$REPO_NAME.files.tar.gz"* )

# --- upload -----------------------------------------------------------------
# Delete-then-upload: `gh release upload --clobber` intermittently fails with
# HTTP 422 "ReleaseAsset.name already exists", which silently dropped a built
# package.
upload_one() {
  local file=$1
  [[ -f $file ]] || { echo "::error::publish-db: missing $file"; return 1; }
  gh release delete-asset "$REPO_NAME" "$(basename "$file")" \
    --repo "$GH_REPO" --yes >/dev/null 2>&1 || true
  gh release upload "$REPO_NAME" "$file" --repo "$GH_REPO" || {
    echo "::error::publish-db: upload failed for $(basename "$file")"; return 1; }
}

gh release view "$REPO_NAME" --repo "$GH_REPO" >/dev/null 2>&1 ||
  gh release create "$REPO_NAME" --repo "$GH_REPO" \
    --title "mayank-v4 pacman repository" \
    --notes "Signed x86-64-v4 packages built by GitHub Actions. pacman pulls updates through omarchy update."

fail=0
upload_one "repo/$REPO_NAME.db"     || fail=1
upload_one "repo/$REPO_NAME.db.sig" || fail=1
upload_one repo/state.json          || fail=1

(( fail == 0 )) || { echo "::error::publish-db: database publish failed"; exit 1; }
echo "publish-db: database and state published"
