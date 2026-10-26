#!/usr/bin/env bash
set -euo pipefail

required=(
  PINGPLACE_DEBUG_KEYSTORE_FILE
  PINGPLACE_DEBUG_STORE_PASSWORD
  PINGPLACE_DEBUG_KEY_ALIAS
  PINGPLACE_DEBUG_KEY_PASSWORD
)

if [[ "${{PINGPLACE_REQUIRE_CI_DEBUG_SIGNING:-}" != "true" ]]; then
  echo "::error::PINGPLACE_REQUIRE_CI_DEBUG_SIGNING must be true for a trusted signed build" >&2
  exit 1
fi

missing=0
for name in "${{required[@]}"; do
  if [[ -z "${{!name:-}" ]]; then
    echo "::error::Missing signing configuration: ${{name}" >&2
    missing=1
  fi
done
if [[ "${{missing}" -ne 0 ]]; then
  exit 1
fi

if [[ ! -s "${{PINGPLACE_DEBUG_KEYSTORE_FILE}" ]]; then
  echo "::error::Signing keystore is missing or empty" >&2
  exit 1
fi
