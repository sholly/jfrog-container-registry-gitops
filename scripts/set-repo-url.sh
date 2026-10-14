#!/usr/bin/env bash
#
# Points every ArgoCD manifest at a Git repo URL (and optionally a branch).
#
# Idempotent and re-runnable: it reads whatever URL is currently configured and
# replaces that, so it works both on a fresh clone carrying the CHANGE-ME
# placeholder and later, when the repo moves or the branch changes.
#
# The chart source (https://charts.jfrog.io) is never touched.
#
# Usage:
#   ./scripts/set-repo-url.sh https://github.com/myorg/my-repo.git [branch]
set -euo pipefail

REPO_URL="${1:?usage: $0 <git-repo-url> [branch]}"
BRANCH="${2:-main}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FILES=(
  "$ROOT/bootstrap/root-application.yaml"
  "$ROOT/gitops/appproject.yaml"
  "$ROOT/gitops/application-platform.yaml"
  "$ROOT/gitops/application-registry.yaml"
)

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done

# The root Application is the single source of truth for the currently
# configured URL and branch.
ROOT_APP="$ROOT/bootstrap/root-application.yaml"
CURRENT_URL="$(awk '/^ *repoURL:/ {print $2; exit}' "$ROOT_APP")"
CURRENT_REV="$(awk '/^ *targetRevision:/ {print $2; exit}' "$ROOT_APP")"

[[ -n "$CURRENT_URL" ]] || { echo "could not read repoURL from $ROOT_APP" >&2; exit 1; }

if [[ "$CURRENT_URL" == "$REPO_URL" && "$CURRENT_REV" == "$BRANCH" ]]; then
  echo "Already set to $REPO_URL ($BRANCH) -- nothing to do."
  exit 0
fi

echo "  from: $CURRENT_URL ($CURRENT_REV)"
echo "    to: $REPO_URL ($BRANCH)"
echo

# BSD and GNU sed disagree about -i, so write through a temp file. Only the
# git URL and the git branch are rewritten; the chart repo and its pinned
# chart version use different keys and are left alone.
for f in "${FILES[@]}"; do
  tmp="$(mktemp)"
  sed -e "s|${CURRENT_URL}|${REPO_URL}|g" \
      -e "s|^\( *targetRevision: \)${CURRENT_REV}$|\1${BRANCH}|" \
      "$f" > "$tmp"
  if cmp -s "$f" "$tmp"; then
    rm -f "$tmp"
    echo "unchanged $(basename "$f")"
  else
    mv "$tmp" "$f"
    echo "updated   $(basename "$f")"
  fi
done

echo
if grep -rq "CHANGE-ME" "$ROOT"/bootstrap "$ROOT"/gitops; then
  echo "WARNING: CHANGE-ME still present:" >&2
  grep -rn "CHANGE-ME" "$ROOT"/bootstrap "$ROOT"/gitops >&2
  exit 1
fi

# The chart pin must survive a branch rename.
if ! grep -q "targetRevision: 107\." "$ROOT/gitops/application-registry.yaml"; then
  echo "ERROR: the chart version pin was clobbered -- check application-registry.yaml" >&2
  exit 1
fi

echo "Done. Commit and push, then apply bootstrap/root-application.yaml."
