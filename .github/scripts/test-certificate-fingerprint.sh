#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=verify-apk-signing.sh
source "${script_dir}/verify-apk-signing.sh"

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    echo "${label}: expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
}

expected="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

keytool_colon_output=$'Owner: CN=PingPlace\nSHA256: 01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF\n'
keytool_hyphen_output=$'Owner: CN=PingPlace\n  SHA-256 :\t01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef\n'
apksigner_colon_output=$'Signer #1 certificate SHA-256 digest: 01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF\n'
apksigner_spaced_output=$'Signer #1 certificate SHA-256 digest :   01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef\n'
apksigner_wrapped_output=$'Signer #1 certificate SHA-256 digest:\n  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n'

assert_equal "${expected}" "$(printf '%s' "${keytool_colon_output}" | extract_keytool_sha256)" "keytool colon format"
assert_equal "${expected}" "$(printf '%s' "${keytool_hyphen_output}" | extract_keytool_sha256)" "keytool hyphen/space format"
assert_equal "${expected}" "$(printf '%s' "${apksigner_colon_output}" | extract_apksigner_sha256)" "apksigner colon format"
assert_equal "${expected}" "$(printf '%s' "${apksigner_spaced_output}" | extract_apksigner_sha256)" "apksigner space format"
assert_equal "${expected}" "$(printf '%s' "${apksigner_wrapped_output}" | extract_apksigner_sha256)" "apksigner wrapped format"

if [[ -n "$(printf '%s' 'SHA256: not-a-fingerprint' | extract_keytool_sha256)" ]]; then
  echo "invalid keytool output was accepted" >&2
  exit 1
fi
if [[ -n "$(printf '%s' 'Signer #1 certificate SHA-256 digest: not-a-fingerprint' | extract_apksigner_sha256)" ]]; then
  echo "invalid apksigner output was accepted" >&2
  exit 1
fi

echo "Certificate fingerprint parser regression tests passed"
