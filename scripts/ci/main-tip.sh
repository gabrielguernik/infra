#!/usr/bin/env bash
# Fails unless this run's commit ($GITHUB_SHA) is main's current tip on GitHub. terraform-apply runs it before
# planning and before applying, so an old run (a re-run, or one queued behind a newer push) never applies older code
# over newer. Needs GH_TOKEN with contents: read.
set -euo pipefail
tip="$(gh api "repos/${GITHUB_REPOSITORY:?}/git/ref/heads/main" --jq .object.sha)"
if [[ "$tip" != "${GITHUB_SHA:?}" ]]; then
  echo "::error::${GITHUB_SHA:0:7} is no longer main's tip (${tip:0:7}). The run for the newer commit plans and applies it."
  exit 1
fi
echo "${GITHUB_SHA:0:7} is main's tip"
