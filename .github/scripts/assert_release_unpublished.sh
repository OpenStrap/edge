#!/usr/bin/env bash
# Stops a release run from touching a release that is already public.
#
# The upload step deletes same-named assets before it uploads, so a re-run
# against a published release that then fails part-way leaves a PUBLIC release
# with files missing, and /releases/latest/download/<name> returns 404 for
# everyone. A run may only ever write to a release that is still a draft.
#
# `releases/tags/<tag>` returns published releases only: 200 means the release
# is public (refuse), 404 means there is no release or it is still a draft
# (fine). Any other answer, including a network error, fails closed.
#
# usage: GH_TOKEN=... GITHUB_REPOSITORY=owner/name assert_release_unpublished.sh <tag>
set -uo pipefail

tag="${1:?usage: assert_release_unpublished.sh <tag>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"

out=$(gh api "repos/${repo}/releases/tags/${tag}" 2>&1)
rc=$?

if [ "$rc" -eq 0 ]; then
  echo "::error::The release for ${tag} is already published. This run would delete and re-upload its assets in place, and a failure part-way would leave a public release with files missing. Cut a new tag instead."
  exit 1
fi

case "$out" in
  *"HTTP 404"* | *"Not Found"*)
    echo "No published release for ${tag}: safe to write to its draft."
    exit 0
    ;;
  *)
    echo "::error::Could not tell whether the release for ${tag} is published, so stopping."
    echo "$out"
    exit 1
    ;;
esac
