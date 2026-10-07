#!/usr/bin/env bash
# Publish GitLab main to the public GitHub copy (where issues are filed).
#
#   tools/publish-github.sh <commit> <github-ssh-url>
#
# The GitHub copy is GitLab's main with one difference: commit messages lose any
# Claude/Anthropic attribution line (older commits carry "Co-Authored-By:
# Claude ..." trailers; the owner's rule is that none is ever published). The
# rewrite is DETERMINISTIC -- same commits in, same commits out, dates and
# authors untouched -- so every run reproduces the hashes already on GitHub and
# the push is a plain fast-forward. Commits with nothing to strip keep their
# GitLab hashes.
#
# Needs GIT_SSH_COMMAND to carry the deploy key (the CI job sets it up).
set -euo pipefail
commit="$1"; url="$2"
RE='^[[:space:]]*co-authored-by:.*(claude|anthropic)|noreply@anthropic\.com|generated with \[?claude code'

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
git clone --quiet --no-local . "$work/repo"
cd "$work/repo"
git checkout --quiet -B publish "$commit"
export RE
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --msg-filter '
  grep -v -i -E "$RE" | awk "{ l[NR] = \$0 } END { n = NR; while (n > 0 && l[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print l[i] }"
' publish >/dev/null
if git log publish --format=%B | grep -q -i -E "$RE"; then echo "attribution left after the rewrite" >&2; exit 1; fi

git remote add github "$url"
git fetch --quiet github main 2>/dev/null || true
if git rev-parse --verify --quiet refs/remotes/github/main >/dev/null; then
  if git merge-base --is-ancestor publish refs/remotes/github/main; then echo "GitHub already has it"; exit 0; fi
  if ! git merge-base --is-ancestor refs/remotes/github/main publish; then
    echo "GitHub's main is not an ancestor of the rewrite; not forcing:" >&2
    git log --oneline -5 refs/remotes/github/main >&2
    exit 1
  fi
fi
git push --quiet github publish:refs/heads/main
echo "published $(git rev-parse --short "$commit") as $(git rev-parse --short publish) to $url"
