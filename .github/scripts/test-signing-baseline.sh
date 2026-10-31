#!/usr/bin/env bash
# Regression tests for the pinned issued signing baseline. Runs the real
# signing-baseline.sh against the real pin file and against fixtures.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
baseline="${script_dir}/signing-baseline.sh"
pin="${repo_root}/.github/signing/issued-baseline.env"
workflow="${repo_root}/.github/workflows/android-trusted-signed-candidate.yml"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
passed=0

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { passed=$((passed + 1)); }

# --- the committed pin is exactly the independently verified Build 14 -------
bash "${baseline}" load "${pin}" > "${work}/pin.out" || fail "committed pin does not load"
expect_pin() {
  grep -Fxq "$1=$2" "${work}/pin.out" || fail "pin $1 is not $2"
  ok
}
expect_pin build_label 1.0.0+14
expect_pin run_id 41223548927
expect_pin run_workflow .github/workflows/android-trusted-signed-candidate.yml
expect_pin run_head_sha def4444d399353b2fdc10e640c9e9e49ea0e5399
expect_pin artifact_id 13050945929
expect_pin artifact_name pingplace-signed-test-v1.0.0+14-build10014-c7cfe7a44129989200287df6b3ca14bf10c18ad8
expect_pin apk_sha256 6ab0a38ff81ae06e4517ebd3d906497b2700338adb1ed46c79cbedbb91dd2abe
expect_pin package_id com.example.pingplace
expect_pin version_name 1.0.0
expect_pin display_build_number 14
expect_pin version_code 10014
expect_pin source_sha c7cfe7a44129989200287df6b3ca14bf10c18ad8
[[ "$(wc -l < "${work}/pin.out")" -eq 13 ]] || fail "pin output has unexpected keys"
ok

# --- the workflow uses the pin and no stale hard-coded baseline -------------
for stale in 41187072871 13037620842 pingplace-signed-test-build-13- 40400807491 \
  "-eq 10013" "-eq 10007"; do
  if grep -Fq -- "${stale}" "${workflow}"; then fail "workflow still hard-codes stale baseline '${stale}'"; fi
  ok
done
for required in \
  'bash .github/scripts/signing-baseline.sh load .github/signing/issued-baseline.env' \
  'bash .github/scripts/signing-baseline.sh verify-run' \
  'bash .github/scripts/signing-baseline.sh verify-apk' \
  'name: ${{ steps.baseline.outputs.artifact_name }}' \
  'run-id: ${{ steps.baseline.outputs.run_id }}'; do
  grep -Fq -- "${required}" "${workflow}" || fail "workflow does not contain: ${required}"
  ok
done

# A stray carriage return inside a run block silently corrupts shell and YAML
# (a previous edit of this workflow did exactly that).
if tr -d '
' < "${workflow}" | grep -q $''; then fail "trusted workflow contains carriage returns"; fi
ok

# --- strict pin parsing -----------------------------------------------------
expect_load_rejection() {
  local label="$1" reason="$2"
  if bash "${baseline}" load "${work}/bad.env" > "${work}/out.txt" 2>&1; then
    fail "expected pin rejection: ${label}"
  fi
  grep -Fq "${reason}" "${work}/out.txt" || { cat "${work}/out.txt" >&2; fail "pin rejection '${label}' did not mention '${reason}'"; }
  ok
}
mutate_pin() {
  # $1: sed expression applied to a copy of the committed pin.
  sed -e "$1" "${pin}" > "${work}/bad.env"
}

# CRLF checkouts must parse identically.
sed 's/$/\r/' "${pin}" > "${work}/crlf.env"
bash "${baseline}" load "${work}/crlf.env" | cmp -s - "${work}/pin.out" || fail "CRLF pin parsed differently"
ok

mutate_pin '/^RUN_ID=/d'; expect_load_rejection "missing key" "missing pin key RUN_ID"
mutate_pin '$a RUN_ID=1'; expect_load_rejection "duplicate key" "duplicate pin key RUN_ID"
mutate_pin '$a EXTRA_KEY=1'; expect_load_rejection "unknown key" "unknown pin key EXTRA_KEY"
mutate_pin 's/^RUN_ID=.*/RUN_ID="41223548927"/'; expect_load_rejection "quoted value" "malformed pin line"
mutate_pin 's/^RUN_ID=.*/RUN_ID=$(id)/'; expect_load_rejection "command substitution" "malformed pin line"
mutate_pin 's/^RUN_ID=.*/RUN_ID=1;id/'; expect_load_rejection "shell metacharacter" "malformed pin line"
mutate_pin 's/^RUN_ID=.*/RUN_ID= 41223548927/'; expect_load_rejection "leading space" "malformed pin line"
mutate_pin 's/^RUN_ID=.*/run_id=41223548927/'; expect_load_rejection "lower-case key" "malformed pin line"
mutate_pin 's/^RUN_ID=.*/RUN_ID=abc/'; expect_load_rejection "non-numeric run" "RUN_ID must be numeric"
mutate_pin 's/^ARTIFACT_ID=.*/ARTIFACT_ID=0/'; expect_load_rejection "zero artifact id" "ARTIFACT_ID must be numeric"
mutate_pin 's/^RUN_HEAD_SHA=.*/RUN_HEAD_SHA=def4444/'; expect_load_rejection "short run head" "RUN_HEAD_SHA must be a full commit SHA"
mutate_pin 's/^SOURCE_SHA=.*/SOURCE_SHA=main/'; expect_load_rejection "branch as source" "SOURCE_SHA must be a full commit SHA"
mutate_pin 's/^APK_SHA256=6ab0/APK_SHA256=6AB0/'; expect_load_rejection "upper-case hash" "APK_SHA256 must be a lowercase SHA-256"
mutate_pin 's/^APK_SHA256=.*/APK_SHA256=6ab0a38f/'; expect_load_rejection "short hash" "APK_SHA256 must be a lowercase SHA-256"
mutate_pin 's#^RUN_WORKFLOW=.*#RUN_WORKFLOW=.github/workflows/android-untrusted-candidate.yml#'
expect_load_rejection "untrusted workflow as baseline" "RUN_WORKFLOW must be the trusted signing workflow"
mutate_pin 's/^VERSION_CODE=.*/VERSION_CODE=10013/'; expect_load_rejection "versionCode mismatch" "is not 10000 + 14"
mutate_pin 's/^DISPLAY_BUILD_NUMBER=.*/DISPLAY_BUILD_NUMBER=13/'; expect_load_rejection "display mismatch" "is not 10000 + 13"
mutate_pin 's/^BUILD_LABEL=.*/BUILD_LABEL=1.0.0+13/'; expect_load_rejection "label mismatch" "BUILD_LABEL"
mutate_pin 's/^ARTIFACT_NAME=.*/ARTIFACT_NAME=pingplace-signed-test-build-13-c3215f8dfab43e755a3c09ff4b4c3c45dd5c2fe2/'
expect_load_rejection "artifact name for another build" "ARTIFACT_NAME does not encode"
mutate_pin 's/^ARTIFACT_EXPIRES_AT=.*/ARTIFACT_EXPIRES_AT=soon/'; expect_load_rejection "bad expiry" "ARTIFACT_EXPIRES_AT"
if bash "${baseline}" load "${work}/does-not-exist.env" > "${work}/out.txt" 2>&1; then fail "missing pin file accepted"; fi
ok

# --- baseline run and artifact provenance -----------------------------------
while IFS='=' read -r key value; do
  export "BASELINE_${key^^}=${value}"
done < "${work}/pin.out"
export EXPECTED_REPOSITORY="bandora78/pingplace"

write_run() {
  jq -n --argjson id "${BASELINE_RUN_ID}" --arg path "${BASELINE_RUN_WORKFLOW}" --arg head "${BASELINE_RUN_HEAD_SHA}" \
    '{id: $id, repository: {full_name: "bandora78/pingplace"}, path: $path, head_branch: "main",
      head_sha: $head, status: "completed", conclusion: "success", event: "workflow_dispatch"}' |
    jq "${1:-.}" > "${work}/run.json"
}
write_artifacts() {
  jq -n --argjson id "${BASELINE_ARTIFACT_ID}" --arg name "${BASELINE_ARTIFACT_NAME}" --argjson run "${BASELINE_RUN_ID}" \
    '{artifacts: [{id: $id, name: $name, expired: false, workflow_run: {id: $run}},
      {id: 1, name: "verified-candidate", expired: false, workflow_run: {id: $run}}]}' |
    jq "${1:-.}" > "${work}/artifacts.json"
}
run_verify() {
  RUN_JSON="${work}/run.json" ARTIFACTS_JSON="${work}/artifacts.json" \
    bash "${baseline}" verify-run > "${work}/out.txt" 2>&1
}
expect_run_rejection() {
  local run_filter="$1" artifact_filter="$2" reason="$3"
  write_run "${run_filter}"; write_artifacts "${artifact_filter}"
  if run_verify; then fail "expected baseline run rejection: ${run_filter} / ${artifact_filter}"; fi
  grep -Fq "${reason}" "${work}/out.txt" || { cat "${work}/out.txt" >&2; fail "run rejection did not mention '${reason}'"; }
  ok
}

write_run; write_artifacts
run_verify || { cat "${work}/out.txt" >&2; fail "expected pinned baseline run to verify"; }
ok
expect_run_rejection '.id = 41187072871' . "run response is not run"
expect_run_rejection '.repository.full_name = "attacker/pingplace"' . "not from bandora78/pingplace"
expect_run_rejection '.path = ".github/workflows/android-untrusted-candidate.yml"' . "is not from"
expect_run_rejection '.head_branch = "feature"' . "not dispatched from main"
expect_run_rejection '.head_sha = "910575fd55a475772631c027c6029f685b42b672"' . "baseline run head is not"
expect_run_rejection '.status = "in_progress"' . "not completed"
expect_run_rejection '.conclusion = "failure"' . "did not succeed"
expect_run_rejection . '.artifacts[0].expired = true' "missing or expired"
expect_run_rejection . '.artifacts[0].id = 13037620842' "missing or expired"
expect_run_rejection . '.artifacts[0].name = "other"' "missing or expired"
expect_run_rejection . '.artifacts[0].workflow_run.id = 1' "missing or expired"
expect_run_rejection . '.artifacts += [.artifacts[0]]' "found 2"
expect_run_rejection . '.artifacts = []' "found 0"

# --- downloaded baseline APK facts and in-place upgrade ---------------------
trusted="906551dd51c43649cd744288e0478a099927ad029e4f2c4e82a0be49e0220c8d"
apk_verify() {
  OBSERVED_APK_SHA256="${obs_sha-${BASELINE_APK_SHA256}}" \
  OBSERVED_PACKAGE_ID="${obs_pkg-com.example.pingplace}" \
  OBSERVED_VERSION_NAME="${obs_name-1.0.0}" \
  OBSERVED_VERSION_CODE="${obs_code-10014}" \
  OBSERVED_SOURCE_SHA="${obs_src-c7cfe7a44129989200287df6b3ca14bf10c18ad8}" \
  OBSERVED_CERT_SHA256="${obs_cert-${trusted}}" \
  TRUSTED_CERT_SHA256="${trusted_cert-${trusted}}" \
  CANDIDATE_VERSION_CODE="${candidate-10015}" \
  EXPECTED_PACKAGE_ID="${expected_pkg-com.example.pingplace}" \
    bash "${baseline}" verify-apk > "${work}/out.txt" 2>&1
}
expect_apk_rejection() {
  local label="$1" reason="$2"
  if apk_verify; then fail "expected baseline APK rejection: ${label}"; fi
  grep -Fq "${reason}" "${work}/out.txt" || { cat "${work}/out.txt" >&2; fail "APK rejection '${label}' did not mention '${reason}'"; }
  ok
}

apk_verify || { cat "${work}/out.txt" >&2; fail "expected Build 15 over Build 14 to verify"; }
ok
# apksigner output formatting (colons, upper case) must not matter.
obs_cert="$(sed 's/../&:/g; s/:$//' <<< "${trusted^^}")"
apk_verify || { cat "${work}/out.txt" >&2; fail "expected formatted fingerprint to verify"; }
unset obs_cert; ok

obs_sha="$(printf '0%.0s' {1..64})"; expect_apk_rejection "different APK bytes" "is not the pinned"; unset obs_sha
obs_pkg="com.example.other"; expect_apk_rejection "different package" "baseline package"; unset obs_pkg
expected_pkg="com.example.other"; expect_apk_rejection "candidate package differs" "differs from the installed baseline"; unset expected_pkg
obs_name="1.0.1"; expect_apk_rejection "different versionName" "baseline versionName"; unset obs_name
obs_code="10013"; expect_apk_rejection "Build 13 APK instead of Build 14" "baseline versionCode"; unset obs_code
obs_src="c3215f8dfab43e755a3c09ff4b4c3c45dd5c2fe2"; expect_apk_rejection "different embedded source" "embedded source"; unset obs_src
obs_cert="$(printf 'a%.0s' {1..64})"; expect_apk_rejection "different signer" "not the trusted certificate"; unset obs_cert
obs_cert=""; expect_apk_rejection "missing signer" "OBSERVED_CERT_SHA256 is empty"; unset obs_cert
trusted_cert="906551dd"; expect_apk_rejection "malformed trusted fingerprint" "not a SHA-256"; unset trusted_cert
candidate="10014"; expect_apk_rejection "same versionCode as installed" "does not upgrade baseline 10014"; unset candidate
candidate="10013"; expect_apk_rejection "downgrade" "does not upgrade baseline 10014"; unset candidate
candidate="10015x"; expect_apk_rejection "non-numeric candidate" "positive integer"; unset candidate
candidate="16"; candidate_ok=false
apk_verify && candidate_ok=true
[[ "${candidate_ok}" == false ]] || fail "versionCode 16 accepted over 10014"
unset candidate; ok

echo "Signing baseline regression tests passed (${passed} cases)"
