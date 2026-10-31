#!/usr/bin/env bash
set -euo pipefail

is_numeric_version_code() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]]
}

valid_value="10007"
if ! is_numeric_version_code "${valid_value}"; then
  echo "valid numeric versionCode was rejected" >&2
  exit 1
fi

for invalid_value in "" "abc" "10007x"; do
  if is_numeric_version_code "${invalid_value}"; then
    echo "invalid versionCode was accepted: ${invalid_value@Q}" >&2
    exit 1
  fi
done

echo "Baseline versionCode Bash validation regression test passed"
