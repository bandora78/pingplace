#!/usr/bin/env bash
# Pinned upgrade baseline for trusted signing.
#
#   signing-baseline.sh load <pin-file>
#     Strictly parses and validates the pin file and prints key=value lines
#     (lowercase keys) suitable for $GITHUB_OUTPUT. Never sources the file.
#
#   signing-baseline.sh verify-run
#     env: RUN_JSON ARTIFACTS_JSON EXPECTED_REPOSITORY plus the BASELINE_* pin
#     values. Checks the baseline run and artifact through API responses.
#
#   signing-baseline.sh verify-apk
#     env: BASELINE_* pin values plus OBSERVED_APK_SHA256 OBSERVED_PACKAGE_ID
#     OBSERVED_VERSION_NAME OBSERVED_VERSION_CODE OBSERVED_SOURCE_SHA
#     OBSERVED_CERT_SHA256 TRUSTED_CERT_SHA256 CANDIDATE_VERSION_CODE.
#     Checks the downloaded baseline APK is exactly the pinned build, carries
#     the trusted certificate, and that the candidate upgrades it in place.
set -euo pipefail

readonly VERSION_CODE_OFFSET=10000
# Allow-list: upper-case keys; values without whitespace, quotes or shell
# metacharacters.
readonly PIN_LINE_PATTERN='^([A-Z][A-Z0-9_]*)=([A-Za-z0-9._:+/-]+)$'
readonly REQUIRED_KEYS=(BUILD_LABEL RUN_ID RUN_WORKFLOW RUN_HEAD_SHA ARTIFACT_ID
  ARTIFACT_NAME ARTIFACT_EXPIRES_AT APK_SHA256 PACKAGE_ID VERSION_NAME
  DISPLAY_BUILD_NUMBER VERSION_CODE SOURCE_SHA)

reject() {
  echo "::error::Signing baseline rejected: $*" >&2
  exit 1
}

is_sha1() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
is_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
is_positive() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

load_pin() {
  local file="$1"
  [[ -f "${file}" ]] || reject "pin file ${file} does not exist"
  declare -A values=()
  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" =~ ${PIN_LINE_PATTERN} ]] ||
      reject "malformed pin line '${line}'"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    local known=false required
    for required in "${REQUIRED_KEYS[@]}"; do
      [[ "${required}" == "${key}" ]] && known=true
    done
    [[ "${known}" == true ]] || reject "unknown pin key ${key}"
    [[ -z "${values[${key}]+set}" ]] || reject "duplicate pin key ${key}"
    values["${key}"]="${value}"
  done < "${file}"
  for key in "${REQUIRED_KEYS[@]}"; do
    [[ -n "${values[${key}]+set}" ]] || reject "missing pin key ${key}"
  done

  is_positive "${values[RUN_ID]}" || reject "RUN_ID must be numeric"
  is_positive "${values[ARTIFACT_ID]}" || reject "ARTIFACT_ID must be numeric"
  is_sha1 "${values[RUN_HEAD_SHA]}" || reject "RUN_HEAD_SHA must be a full commit SHA"
  is_sha1 "${values[SOURCE_SHA]}" || reject "SOURCE_SHA must be a full commit SHA"
  is_sha256 "${values[APK_SHA256]}" || reject "APK_SHA256 must be a lowercase SHA-256"
  [[ "${values[RUN_WORKFLOW]}" == ".github/workflows/android-trusted-signed-candidate.yml" ]] ||
    reject "RUN_WORKFLOW must be the trusted signing workflow"
  is_positive "${values[DISPLAY_BUILD_NUMBER]}" || reject "DISPLAY_BUILD_NUMBER must be a positive integer"
  is_positive "${values[VERSION_CODE]}" || reject "VERSION_CODE must be a positive integer"
  [[ "${values[VERSION_CODE]}" == "$((VERSION_CODE_OFFSET + ${values[DISPLAY_BUILD_NUMBER]}))" ]] ||
    reject "VERSION_CODE ${values[VERSION_CODE]} is not ${VERSION_CODE_OFFSET} + ${values[DISPLAY_BUILD_NUMBER]}"
  [[ "${values[BUILD_LABEL]}" == "${values[VERSION_NAME]}+${values[DISPLAY_BUILD_NUMBER]}" ]] ||
    reject "BUILD_LABEL ${values[BUILD_LABEL]} does not match VERSION_NAME+DISPLAY_BUILD_NUMBER"
  [[ "${values[ARTIFACT_NAME]}" == "pingplace-signed-test-v${values[BUILD_LABEL]}-build${values[VERSION_CODE]}-${values[SOURCE_SHA]}" ]] ||
    reject "ARTIFACT_NAME does not encode the pinned build identity"
  [[ "${values[ARTIFACT_EXPIRES_AT]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    reject "ARTIFACT_EXPIRES_AT must be an ISO-8601 UTC timestamp"

  for key in "${REQUIRED_KEYS[@]}"; do
    printf '%s=%s\n' "${key,,}" "${values[${key}]}"
  done
}

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || reject "required value ${name} is empty"
  done
}

json_field() { jq -er "$2 // empty | tostring" "$1" 2>/dev/null || true; }

verify_run() {
  require_env RUN_JSON ARTIFACTS_JSON EXPECTED_REPOSITORY BASELINE_RUN_ID \
    BASELINE_RUN_WORKFLOW BASELINE_RUN_HEAD_SHA BASELINE_ARTIFACT_ID BASELINE_ARTIFACT_NAME
  [[ "$(json_field "${RUN_JSON}" '.id')" == "${BASELINE_RUN_ID}" ]] || reject "run response is not run ${BASELINE_RUN_ID}"
  [[ "$(json_field "${RUN_JSON}" '.repository.full_name')" == "${EXPECTED_REPOSITORY}" ]] ||
    reject "baseline run is not from ${EXPECTED_REPOSITORY}"
  [[ "$(json_field "${RUN_JSON}" '.path')" == "${BASELINE_RUN_WORKFLOW}" ]] ||
    reject "baseline run is not from ${BASELINE_RUN_WORKFLOW}"
  [[ "$(json_field "${RUN_JSON}" '.head_branch')" == "main" ]] || reject "baseline run was not dispatched from main"
  [[ "$(json_field "${RUN_JSON}" '.head_sha')" == "${BASELINE_RUN_HEAD_SHA}" ]] ||
    reject "baseline run head is not ${BASELINE_RUN_HEAD_SHA}"
  [[ "$(json_field "${RUN_JSON}" '.status')" == "completed" ]] || reject "baseline run is not completed"
  [[ "$(json_field "${RUN_JSON}" '.conclusion')" == "success" ]] || reject "baseline run did not succeed"
  local matches
  matches="$(jq --arg id "${BASELINE_ARTIFACT_ID}" --arg name "${BASELINE_ARTIFACT_NAME}" \
    --arg run "${BASELINE_RUN_ID}" \
    '[.artifacts[]? | select((.id|tostring) == $id and .name == $name and .expired == false
       and (.workflow_run.id|tostring) == $run)] | length' "${ARTIFACTS_JSON}")" ||
    reject "baseline artifacts response could not be parsed"
  [[ "${matches}" == "1" ]] ||
    reject "baseline artifact ${BASELINE_ARTIFACT_ID} is missing or expired (found ${matches}); pin the latest issued signed build"
  echo "Verified baseline run ${BASELINE_RUN_ID} and artifact ${BASELINE_ARTIFACT_ID}"
}

normalize_fingerprint() { printf '%s' "$1" | tr -d '[:space:]:' | tr '[:upper:]' '[:lower:]'; }

verify_apk() {
  require_env BASELINE_APK_SHA256 BASELINE_PACKAGE_ID BASELINE_VERSION_NAME BASELINE_VERSION_CODE \
    BASELINE_SOURCE_SHA OBSERVED_APK_SHA256 OBSERVED_PACKAGE_ID OBSERVED_VERSION_NAME \
    OBSERVED_VERSION_CODE OBSERVED_SOURCE_SHA OBSERVED_CERT_SHA256 TRUSTED_CERT_SHA256 \
    CANDIDATE_VERSION_CODE EXPECTED_PACKAGE_ID
  [[ "${OBSERVED_APK_SHA256}" == "${BASELINE_APK_SHA256}" ]] ||
    reject "downloaded baseline APK SHA-256 ${OBSERVED_APK_SHA256} is not the pinned ${BASELINE_APK_SHA256}"
  [[ "${OBSERVED_PACKAGE_ID}" == "${BASELINE_PACKAGE_ID}" ]] || reject "baseline package is ${OBSERVED_PACKAGE_ID}"
  [[ "${BASELINE_PACKAGE_ID}" == "${EXPECTED_PACKAGE_ID}" ]] ||
    reject "candidate package ${EXPECTED_PACKAGE_ID} differs from the installed baseline ${BASELINE_PACKAGE_ID}"
  [[ "${OBSERVED_VERSION_NAME}" == "${BASELINE_VERSION_NAME}" ]] || reject "baseline versionName is ${OBSERVED_VERSION_NAME}"
  [[ "${OBSERVED_VERSION_CODE}" == "${BASELINE_VERSION_CODE}" ]] || reject "baseline versionCode is ${OBSERVED_VERSION_CODE}"
  [[ "${OBSERVED_SOURCE_SHA}" == "${BASELINE_SOURCE_SHA}" ]] || reject "baseline embedded source is ${OBSERVED_SOURCE_SHA}"
  local observed trusted
  observed="$(normalize_fingerprint "${OBSERVED_CERT_SHA256}")"
  trusted="$(normalize_fingerprint "${TRUSTED_CERT_SHA256}")"
  is_sha256 "${trusted}" || reject "trusted certificate fingerprint is not a SHA-256"
  [[ "${observed}" == "${trusted}" ]] ||
    reject "baseline certificate ${observed} is not the trusted certificate, so an in-place update is impossible"
  is_positive "${CANDIDATE_VERSION_CODE}" || reject "candidate versionCode must be a positive integer"
  (( CANDIDATE_VERSION_CODE > BASELINE_VERSION_CODE )) ||
    reject "candidate versionCode ${CANDIDATE_VERSION_CODE} does not upgrade baseline ${BASELINE_VERSION_CODE}"
  echo "Verified candidate versionCode ${CANDIDATE_VERSION_CODE} upgrades issued baseline ${BASELINE_VERSION_CODE} signed by ${observed}"
}

case "${1:-}" in
  load) load_pin "${2:?pin file is required}" ;;
  verify-run) verify_run ;;
  verify-apk) verify_apk ;;
  *) echo "usage: $0 load <file>|verify-run|verify-apk" >&2; exit 2 ;;
esac
