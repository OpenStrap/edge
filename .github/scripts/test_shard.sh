#!/usr/bin/env bash
# Run one slice of the test suite: test_shard.sh <index> <total>.
#
# Every *_test.dart under test/ belongs to exactly one slice (its position in
# the sorted list, modulo <total>), so the slices together are the whole suite.
# Inside a slice the files still run one at a time (--concurrency=1): the suite
# uses sqflite_common_ffi against real database files and parallel workers on
# ONE machine race on them. Separate CI jobs are separate machines.
#
# ponytail: slices are balanced by file COUNT, not by duration. If one slice
# becomes the slow one, split by recorded timings instead.
set -euo pipefail

index="$1"
total="$2"

# Listed into a variable first, so a failed `find` or `sort` fails the slice
# (set -e, pipefail). Feeding the loop straight from the pipeline would let a
# half-read test tree pass with some of its files never run.
all="$(find test -name '*_test.dart' | LC_ALL=C sort)"

files=()
i=0
while IFS= read -r f; do
  if [ $((i % total)) -eq "$index" ]; then files+=("$f"); fi
  i=$((i + 1))
done <<< "$all"

if [ "${#files[@]}" -eq 0 ]; then
  echo "slice $index of $total holds no test files" >&2
  exit 1
fi

echo "slice $index of $total: ${#files[@]} of $i test files"
if [ "${TEST_SHARD_LIST_ONLY:-}" = 1 ]; then
  printf '%s\n' "${files[@]}"
  exit 0
fi
flutter test --concurrency=1 --reporter=expanded "${files[@]}"
