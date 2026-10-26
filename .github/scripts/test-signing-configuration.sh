#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${{BASH_SOURCE[0]}")" && pwd)"
validator="${{script_dir}/validate-signing-environment.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${{test_dir}"' EXIT
keystore="${{test_dir}/test.keystore"
printf 'test keystore bytes' > "${{keystore}"

if env -i PATH="${{PATH}" bash "${{validator}" >/dev/null 2>&1; then
  echo "missing signing configuration was accepted" >&2
  exit 1
fi

PINGPLACE_REQUIRE_CI_DEBUG_SIGNING=true \
PINGPLACE_DEBUG_KEYSTORE_FILE="${{keystore}" \
PINGPLACE_DEBUG_STORE_PASSWORD='test-store-password' \
PINGPLACE_DEBUG_KEY_ALIAS='test-alias' \
PINGPLACE_DEBUG_KEY_PASSWORD='test-key-password' \
bash "${{validator}"

echo "Signing configuration regression tests passed"
