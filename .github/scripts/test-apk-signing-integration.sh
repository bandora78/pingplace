#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verify_script="${script_dir}/verify-apk-signing.sh"
apk_path="${1:?APK path is required}"
apksigner_path="${2:?apksigner path is required}"

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

password='app-ci-02b-integration-only'
alias_name='integration-test'

create_keystore() {
  local path="$1"
  keytool -genkeypair -noprompt \
    -keystore "${path}" \
    -storepass "${password}" \
    -keypass "${password}" \
    -alias "${alias_name}" \
    -keyalg RSA \
    -keysize 2048 \
    -validity 1 \
    -dname 'CN=APP-CI-02B integration test' \
    >/dev/null
}

sign_copy() {
  local keystore_path="$1"
  local output_path="$2"
  cp "${apk_path}" "${output_path}"
  "${apksigner_path}" sign \
    --ks "${keystore_path}" \
    --ks-pass "pass:${password}" \
    --ks-key-alias "${alias_name}" \
    --key-pass "pass:${password}" \
    "${output_path}" \
    >/dev/null
}

first_keystore="${test_dir}/first.keystore"
second_keystore="${test_dir}/second.keystore"
first_apk="${test_dir}/first.apk"
second_apk="${test_dir}/second.apk"
create_keystore "${first_keystore}"
create_keystore "${second_keystore}"

sign_copy "${first_keystore}" "${first_apk}"
export PINGPLACE_DEBUG_KEYSTORE_PASSWORD="${password}"
export PINGPLACE_DEBUG_KEY_ALIAS="${alias_name}"
bash "${verify_script}" "${first_apk}" "${first_keystore}" "${apksigner_path}" \
  >"${test_dir}/matching.log"
grep -q 'Verified APK signature and certificate match' "${test_dir}/matching.log"

sign_copy "${second_keystore}" "${second_apk}"
if bash "${verify_script}" "${second_apk}" "${first_keystore}" "${apksigner_path}" \
  >"${test_dir}/mismatch.log" 2>&1; then
  echo 'Expected certificate mismatch verification to fail' >&2
  exit 1
fi
grep -q 'Certificate mismatch:' "${test_dir}/mismatch.log"

echo 'APK signing integration and mismatch tests passed'
