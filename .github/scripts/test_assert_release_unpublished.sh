#!/usr/bin/env bash
# Tests assert_release_unpublished.sh against a fake `gh`, so no network and no
# token is needed. Each case fakes one answer from the releases/tags endpoint.
# Exit codes alone cannot tell "refused because it is public" from "failed
# closed because the answer was unreadable" (both exit 1), so each case also
# pins the message the script prints.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/assert_release_unpublished.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GITHUB_REPOSITORY="owner/repo"

fail=0
check() { # name, expected exit code, expected output fragment, fake gh body
  local name="$1" want="$2" frag="$3" body="$4"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$tmp/gh"
  chmod +x "$tmp/gh"
  PATH="$tmp:$PATH" bash "$script" v9.9.9 > "$tmp/out" 2>&1
  local got=$?
  if [ "$got" -ne "$want" ] || ! grep -q -- "$frag" "$tmp/out"; then
    echo "FAIL: $name (exit $got, wanted $want, wanted output containing: $frag)"
    cat "$tmp/out"
    fail=1
  else
    echo "ok: $name"
  fi
}

check "a published release is refused as published" 1 "already published" \
  'echo "{\"draft\": false}"; exit 0'
check "no release at all is allowed" 0 "safe to write" \
  'echo "gh: Not Found (HTTP 404)" >&2; exit 1'
check "a draft is allowed (the tag endpoint 404s for drafts)" 0 "safe to write" \
  'echo "gh: Not Found (HTTP 404)" >&2; exit 1'
check "a network error fails closed" 1 "Could not tell" \
  'echo "dial tcp: i/o timeout" >&2; exit 1'
check "a 500 fails closed" 1 "Could not tell" \
  'echo "gh: Server Error (HTTP 500)" >&2; exit 1'
check "a rate limit fails closed" 1 "Could not tell" \
  'echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1'

exit "$fail"
