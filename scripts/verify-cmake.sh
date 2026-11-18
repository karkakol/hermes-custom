#!/usr/bin/env bash
# Usage: verify-cmake.sh <hermes-dir> <expected-file>
# Fails unless every build_<slice>/CMakeCache.txt contains every line of <expected-file>.
set -euo pipefail

hermes_dir="$1"
expected="$2"
status=0

shopt -s nullglob
caches=("$hermes_dir"/build_*/CMakeCache.txt)
if [[ ${#caches[@]} -eq 0 ]]; then
  echo "No CMakeCache.txt found under $hermes_dir/build_*" >&2
  exit 1
fi

for cache in "${caches[@]}"; do
  [[ "$cache" == *build_host_hermesc* ]] && continue
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if grep -qxF "$line" "$cache"; then
      echo "ok      $cache: $line"
    else
      echo "MISSING $cache: $line" >&2
      status=1
    fi
  done < "$expected"
done

exit "$status"
