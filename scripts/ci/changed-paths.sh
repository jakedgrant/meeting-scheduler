#!/usr/bin/env bash
# Decides whether a pull request changes any of the given paths, so a workflow can skip its
# expensive jobs while still reporting every job on every pull request. See "How the gating
# works" in docs/release-checks.md.
#
# Usage: changed-paths.sh <pathspec>...
#
# Writes "relevant=true" or "relevant=false" to $GITHUB_OUTPUT (stdout when unset). Anything other
# than a pull request (a push to main, a manual run) is always relevant. So is any pull request
# whose changes can't be determined: the gate fails open and runs the work.
#
# Needs a checkout of the pull request merge commit with fetch-depth 2. Its first parent is the
# base branch tip, so the diff against it is exactly what merging would change.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <pathspec>..." >&2
  exit 2
fi

emit() {
  echo "relevant=$1" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  echo "$2"
}

if [ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]; then
  emit true "Event is ${GITHUB_EVENT_NAME:-unset}, not a pull request: running everything."
  exit 0
fi

if ! git rev-parse --verify --quiet HEAD^1 > /dev/null; then
  emit true "No base commit in the checkout: running everything."
  exit 0
fi

status=0
git diff --quiet HEAD^1 HEAD -- "$@" || status=$?
case "$status" in
  0) emit false "No relevant path changed: skipping the platform jobs." ;;
  1)
    emit true "Relevant paths changed:"
    git diff --name-only HEAD^1 HEAD -- "$@" | sed 's/^/  /'
    ;;
  *) emit true "Could not compare against the base commit: running everything." ;;
esac
