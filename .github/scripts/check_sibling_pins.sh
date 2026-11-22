#!/usr/bin/env bash
# Shared by test.yml (test job) and build.yml (preflight job) — a release
# tagged straight off `main` never runs test.yml at all, so this guard has
# to live in both places to actually protect a release.
#
# This pin-drift class has bitten the project repeatedly:
#   - v43 rode a floating `main` ref and silently picked up a breaking change
#   - 2026-07-20: the pinned SHA didn't actually contain the analytics fix a
#     changelog entry cited — the bug it "fixed" stayed live for 3 releases
#   - 2026-07-26: a local `flutter pub get` run WITH pubspec_overrides.yaml
#     present rewrote the tracked pubspec.lock to local path sources,
#     silently dropping the git provenance — happened twice in one session
#   - 2026-07-30: edge shipped a full day pinned one merge behind BOTH
#     protocol and analytics main — including a protocol fix for a decoder
#     bug that could eat up to 4092 bytes of good historical data — because
#     nothing ever re-checked the pin against upstream after it was set
#
# Two independent checks, run per sibling package:
#   1. pubspec.lock actually resolves what pubspec.yaml pins (not a local
#      path, not some other ref). FATAL — catches the pub-get-with-overrides
#      class above; a release built from this state doesn't contain what its
#      own pin claims.
#   2. the pinned ref is not stale against the sibling's current main.
#      NON-FATAL (a warning annotation, not a build failure) — a deliberate
#      short lag while a fix bakes is a legitimate call for a maintainer to
#      make, but per 2026-07-30 it must be a call someone actually makes,
#      not a silent default nobody notices. Skipped (not failed) if the
#      sibling repo can't be reached — a network hiccup here must not block
#      an otherwise-good build.
set -euo pipefail
fail=0

# pubspec_overrides.yaml is gitignored and local-dev only. If one ever arrives
# in the tree, `flutter pub get` picks it up automatically and CI silently
# stops testing the pinned SHAs. Checked before `pub get` runs, so this
# inspects the committed file, not whatever pub resolution produced from it.
if [ -e pubspec_overrides.yaml ]; then
  echo "::error::pubspec_overrides.yaml is present in CI — dependency"
  echo "::error::resolution would use local paths instead of the pins."
  fail=1
fi

for pkg in openstrap_protocol openstrap_analytics; do
  case "$pkg" in
    openstrap_protocol) repo="protocol" ;;
    openstrap_analytics) repo="analytics" ;;
  esac

  block=$(awk -v p="  $pkg:" '$0==p{f=1;next} /^  [a-z_]+:/{f=0} f' pubspec.lock)

  if printf '%s' "$block" | grep -qE '^\s+source: path'; then
    echo "::error::pubspec.lock resolves $pkg from a local path."
    echo "::error::Re-run: mv pubspec_overrides.yaml /tmp/ && flutter pub get && mv /tmp/pubspec_overrides.yaml ."
    fail=1
    continue
  fi

  locked=$(printf '%s' "$block" | grep -E '^\s+resolved-ref:' | head -1 | awk '{print $2}' | tr -d '"' || true)
  pinned=$(awk -v p="  $pkg:" '$0==p{f=1;next} /^  [a-z_]+:/{f=0} f' pubspec.yaml \
    | grep -E '^\s+ref:' | head -1 | awk '{print $2}' | tr -d '"' || true)

  if [ -z "$locked" ] || [ -z "$pinned" ]; then
    echo "::error::could not read a commit pin for $pkg (lock='$locked' pubspec='$pinned')."
    fail=1
    continue
  fi
  if [ "$locked" != "$pinned" ]; then
    echo "::error::$pkg pin drift — pubspec.yaml says $pinned, pubspec.lock resolved $locked."
    echo "::error::A release citing a sibling change would not actually contain it."
    fail=1
    continue
  fi
  echo "$pkg pinned at $pinned, lock agrees."

  # Bounded: git ls-remote has no built-in timeout, and this whole probe is
  # supposed to degrade to a warning on any network trouble — an unbounded
  # hang on a stalled connection would instead wedge the job (test job or,
  # worse, release preflight) until CI's own multi-hour job timeout, which is
  # a much bigger failure than the staleness check it's guarding against.
  if upstream="$(timeout --kill-after=5s 30s git ls-remote "https://github.com/OpenStrap/$repo.git" refs/heads/main 2>/dev/null | awk '{print $1}')" \
      && [ -n "$upstream" ]; then
    if [ "$upstream" != "$pinned" ]; then
      echo "::warning::$pkg is pinned at $pinned but $repo's main has moved to $upstream."
      echo "::warning::Deliberate short lag is fine — just make sure it's a conscious call, not a forgotten one. (This exact gap shipped edge a full day behind protocol's CRC8-length-check fix on 2026-07-30.)"
    fi
  else
    echo "::warning::could not reach $repo's main to check pin staleness — not failing the build for it."
  fi
done

[ "$fail" = 0 ]
