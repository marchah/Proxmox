#!/usr/bin/env bash
# Stage pro-v620/ on the Proxmox host at one commit, so a test record can name the exact
# scripts it ran. Runs on the authoring machine, from anywhere in the repo.
#
#   ./pro-v620/push-harness.sh            # HEAD
#   ./pro-v620/push-harness.sh <commit>   # any commit
#
# Writes /root/harness/<sha12>/pro-v620/ plus a HARNESS_COMMIT file that
# placement-sweep.sh records. Only committed content is staged: uncommitted edits are
# left out, never copied. A staged commit is immutable, so re-running is a no-op.
set -Eeuo pipefail

HOST="${HOST:-pve}"
REV="${1:-HEAD}"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

cd "$(git rev-parse --show-toplevel)"
sha="$(git rev-parse --verify "${REV}^{commit}")" || die "unknown commit ${REV}"
dest="/root/harness/${sha:0:12}"

if [ "$REV" = "HEAD" ] && ! git diff --quiet HEAD -- pro-v620; then
  warn "uncommitted changes under pro-v620/ are not staged; commit them to run them"
fi
if [ -z "$(git branch -r --contains "$sha" 2>/dev/null)" ]; then
  warn "${sha:0:12} is on no remote branch yet; push it so the record's commit can be found"
fi

if ssh "$HOST" "test -e '${dest}/HARNESS_COMMIT'"; then
  echo "${dest}/pro-v620 (already staged)"
  exit 0
fi

git archive --format=tar "$sha" pro-v620 \
  | ssh "$HOST" "set -e; mkdir -p '${dest}'; tar -xf - -C '${dest}'
      printf '%s\n%s\n' '${sha}' '$(git log -1 --format=%cI "$sha")' >'${dest}/HARNESS_COMMIT'"
echo "${dest}/pro-v620"
