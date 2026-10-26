#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

workflow_file="${script_dir}/../workflows/android-signed-test-apk.yml"

workflow_env_names="$(
  awk '
    /- name: Validate signing secrets/ { step = 1; next }
    step && /^      - name:/ { exit }
    step && /env:/ { in_env = 1; next }
    step && in_env && /^[[:space:]]+PINGPLACE_[A-Z0-9_]+:/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/:.*/, "", line)
      print line
    }
  ' "${workflow_file}" | sort
)"

validation_names="$(
  awk '
    /- name: Validate signing secrets/ { step = 1; next }
    step && /^      - name:/ { exit }
    step && /for name in/ { in_loop = 1; next }
    in_loop {
      line = $0
      sub(/;[[:space:]]*do.*/, "", line)
      gsub(/[[:space:]\\]/, "", line)
      if (line ~ /^PINGPLACE_/) {
        print line
      }
      if ($0 ~ /;[[:space:]]*do/) {
        exit
      }
    }
  ' "${workflow_file}" | sort
)"

if ! diff -u <(printf '%s\n' "${workflow_env_names}") <(printf '%s\n' "${validation_names}"); then
  echo "Validate signing secrets env names do not match its validation loop" >&2
  exit 1
fi

validator="${script_dir}/validate-signing-environment.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
keystore="${test_dir}/test.keystore"
printf 'test keystore bytes' > "${keystore}"

if env -i PATH="${PATH}" bash "${validator}" >/dev/null 2>&1; then
  echo "missing signing configuration was accepted" >&2
  exit 1
fi

PINGPLACE_REQUIRE_CI_DEBUG_SIGNING=true \
PINGPLACE_DEBUG_KEYSTORE_FILE="${keystore}" \
PINGPLACE_DEBUG_STORE_PASSWORD='test-store-password' \
PINGPLACE_DEBUG_KEY_ALIAS='test-alias' \
PINGPLACE_DEBUG_KEY_PASSWORD='test-key-password' \
bash "${validator}"

echo "Signing configuration regression tests passed"
