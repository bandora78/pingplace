#!/usr/bin/env bash
set -euo pipefail

extract_keytool_sha256() {
  awk '
    {
      line = tolower($0)
      if (line ~ /^[[:space:]]*sha-?256[[:space:]]*:/) {
        value = $0
        sub(/^[^:]*:/, "", value)
        gsub(/[[:space:]:\r]/, "", value)
        value = tolower(value)
        if (length(value) == 64 && value !~ /[^0-9a-f]/) {
          print value
          exit
        }
      }
    }
  '
}

extract_apksigner_sha256() {
  awk '
    {
      line = tolower($0)
      if (line ~ /certificate[[:space:]]+sha-[[:space:]]*256[[:space:]]+digest[[:space:]]*:/) {
        value = $0
        sub(/^[^:]*:/, "", value)
        gsub(/[[:space:]:\r]/, "", value)
        value = tolower(value)
        if (length(value) == 64 && value !~ /[^0-9a-f]/) {
          print value
          exit
        }
      }
    }
  '
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  : "${PINGPLACE_DEBUG_KEYSTORE_PASSWORD:?PINGPLACE_DEBUG_KEYSTORE_PASSWORD is required}"
  : "${PINGPLACE_DEBUG_KEY_ALIAS:?PINGPLACE_DEBUG_KEY_ALIAS is required}"

  apk_path="${1:?APK path is required}"
  keystore_path="${2:?Keystore path is required}"
  apksigner_path="${3:?apksigner path is required}"

  keytool_output="$(keytool -list -v \
    -keystore "${keystore_path}" \
    -storepass "${PINGPLACE_DEBUG_KEYSTORE_PASSWORD}" \
    -alias "${PINGPLACE_DEBUG_KEY_ALIAS}")"
  keystore_fingerprint="$(printf '%s\n' "${keytool_output}" | extract_keytool_sha256)"
  if [[ -z "${keystore_fingerprint}" ]]; then
    echo "::error::Missing keystore certificate fingerprint: keytool output did not contain a valid SHA-256 certificate digest" >&2
    exit 1
  fi

  if ! "${apksigner_path}" verify "${apk_path}"; then
    echo "::error::APK signature verification failed: apksigner verify rejected the APK" >&2
    exit 1
  fi

  apksigner_output="$("${apksigner_path}" verify --print-certs "${apk_path}")"
  apk_fingerprint="$(printf '%s\n' "${apksigner_output}" | extract_apksigner_sha256)"
  if [[ -z "${apk_fingerprint}" ]]; then
    echo "::error::Missing APK certificate fingerprint: apksigner output did not contain a valid SHA-256 certificate digest" >&2
    exit 1
  fi

  if [[ "${keystore_fingerprint}" != "${apk_fingerprint}" ]]; then
    echo "::error::Certificate mismatch: the APK certificate differs from the dedicated test keystore" >&2
    exit 1
  fi

  echo "Verified APK signature and certificate match"
fi
