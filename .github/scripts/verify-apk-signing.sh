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
    function emit(value) {
      gsub(/[[:space:]:\r]/, "", value)
      value = tolower(value)
      if (length(value) == 64 && value !~ /[^0-9a-f]/) {
        print value
        found = 1
      }
    }
    {
      line = tolower($0)
      if (line ~ /certificate[[:space:]]+sha-[[:space:]]*256[[:space:]]+digest[[:space:]]*:/) {
        value = $0
        sub(/^.*digest[[:space:]]*:/, "", value)
        emit(value)
        if (found) {
          exit
        }
        pending = 1
        next
      }
      if (pending) {
        value = $0
        gsub(/[[:space:]:\r]/, "", value)
        if (value ~ /^[0-9a-fA-F]+$/) {
          wrapped = wrapped value
          if (length(wrapped) == 64) {
            print tolower(wrapped)
            exit
          }
          if (length(wrapped) > 64) {
            pending = 0
          }
        } else if (value != "") {
          pending = 0
        }
      }
    }
  '
}

print_apksigner_structure() {
  local stream_name="$1"
  local stream_file="$2"
  local line_count
  local sha256_label_count

  line_count="$(wc -l < "${stream_file}" | tr -d '[:space:]')"
  sha256_label_count="$(awk '
    {
      line = tolower($0)
      if (line ~ /certificate[[:space:]]+sha-[[:space:]]*256[[:space:]]+digest[[:space:]]*:/) {
        count++
      }
    }
    END { print count + 0 }
  ' "${stream_file}")"
  echo "apksigner ${stream_name}: lines=${line_count}, sha256-digest-labels=${sha256_label_count}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  : "${PINGPLACE_DEBUG_STORE_PASSWORD:?PINGPLACE_DEBUG_STORE_PASSWORD is required}"
  : "${PINGPLACE_DEBUG_KEY_ALIAS:?PINGPLACE_DEBUG_KEY_ALIAS is required}"

  apk_path="${1:?APK path is required}"
  keystore_path="${2:?Keystore path is required}"
  apksigner_path="${3:?apksigner path is required}"

  keytool_output="$(keytool -list -v \
    -keystore "${keystore_path}" \
    -storepass "${PINGPLACE_DEBUG_STORE_PASSWORD}" \
    -alias "${PINGPLACE_DEBUG_KEY_ALIAS}")"
  keystore_fingerprint="$(printf '%s\n' "${keytool_output}" | extract_keytool_sha256)"
  if [[ -z "${keystore_fingerprint}" ]]; then
    echo "::error::Missing keystore certificate fingerprint: keytool output did not contain a valid SHA-256 certificate digest" >&2
    exit 1
  fi

  diagnostics_dir="$(mktemp -d)"
  trap 'rm -rf "${diagnostics_dir}"' EXIT

  set +e
  "${apksigner_path}" verify "${apk_path}" \
    >"${diagnostics_dir}/verify-stdout" 2>"${diagnostics_dir}/verify-stderr"
  verify_status=$?
  set -e
  echo "apksigner verify exit status: ${verify_status}"
  print_apksigner_structure verify-stdout "${diagnostics_dir}/verify-stdout"
  print_apksigner_structure verify-stderr "${diagnostics_dir}/verify-stderr"
  if [[ "${verify_status}" -ne 0 ]]; then
    echo "::error::APK signature verification failed: apksigner verify rejected the APK" >&2
    exit 1
  fi

  set +e
  "${apksigner_path}" verify --print-certs "${apk_path}" \
    >"${diagnostics_dir}/stdout" 2>"${diagnostics_dir}/stderr"
  print_certs_status=$?
  set -e

  print_apksigner_structure stdout "${diagnostics_dir}/stdout"
  print_apksigner_structure stderr "${diagnostics_dir}/stderr"
  if [[ "${print_certs_status}" -ne 0 ]]; then
    echo "::error::apksigner verify --print-certs failed with exit status ${print_certs_status}" >&2
    exit 1
  fi

  apksigner_output="$(cat "${diagnostics_dir}/stdout" "${diagnostics_dir}/stderr")"
  apk_fingerprint="$(printf '%s\n' "${apksigner_output}" | extract_apksigner_sha256)"
  if [[ -z "${apk_fingerprint}" ]]; then
    echo "::error::Missing APK certificate fingerprint: apksigner output did not contain a valid SHA-256 certificate digest" >&2
    exit 1
  fi

  if [[ "${keystore_fingerprint}" != "${apk_fingerprint}" ]]; then
    echo "::error::Certificate mismatch: the APK certificate differs from the dedicated test keystore" >&2
    exit 1
  fi

  configured_fingerprint="$(printf '%s' "${PINGPLACE_TRUSTED_CERT_SHA256:-}" |
    tr -d '[:space:]:' | tr '[:upper:]' '[:lower:]')"
  if [[ -n "${configured_fingerprint}" ]]; then
    if [[ ! "${configured_fingerprint}" =~ ^[0-9a-f]{64}$ ]]; then
      echo "::error::PINGPLACE_TRUSTED_CERT_SHA256 is not a valid SHA-256 fingerprint" >&2
      exit 1
    fi
    if [[ "${configured_fingerprint}" != "${apk_fingerprint}" ]]; then
      echo "::error::Certificate mismatch: the APK certificate differs from PINGPLACE_TRUSTED_CERT_SHA256" >&2
      exit 1
    fi
    echo "Verified configured trusted certificate fingerprint"
  fi

  echo "APK signing certificate SHA-256: ${apk_fingerprint}"
  echo "Verified APK signature and certificate match"

fi
