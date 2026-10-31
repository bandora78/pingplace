#!/usr/bin/env bash
# Regression tests for verify-candidate-provenance.sh. Every case runs the real
# verifier against fixture JSON shaped like the GitHub REST API responses the
# trusted signing workflow fetches.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verifier="${script_dir}/verify-candidate-provenance.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

repo="bandora78/pingplace"
main_sha="910575fd55a475772631c027c6029f685b42b672"
target_sha="c7cfe7a44129989200287df6b3ca14bf10c18ad8"
other_sha="c3215f8dfab43e755a3c09ff4b4c3c45dd5c2fe2"
run_id="41196764279"
artifact_id="13041247801"
artifact_name="pingplace-untrusted-candidate-c7cfe7a-v1.0.0+14"
workflow_blob="1111111111111111111111111111111111111111"
passed=0

fail() { echo "FAIL: $*" >&2; exit 1; }

write_run() {
  local event="$1" head_sha="$2" title="$3" branch="$4"
  jq -n --arg repo "${repo}" --arg event "${event}" --arg head "${head_sha}" \
    --arg title "${title}" --arg branch "${branch}" --argjson id "${run_id}" \
    '{id: $id, repository: {full_name: $repo},
      path: ".github/workflows/android-untrusted-candidate.yml",
      event: $event, head_sha: $head, head_branch: $branch,
      display_title: $title, status: "completed", conclusion: "success"}' \
    > "${work}/run.json"
}

write_artifacts() {
  local head_sha="$1"
  jq -n --argjson id "${artifact_id}" --arg name "${artifact_name}" \
    --argjson run "${run_id}" --arg head "${head_sha}" \
    '{total_count: 1, artifacts: [{id: $id, name: $name, expired: false,
      workflow_run: {id: $run, head_sha: $head}}]}' > "${work}/artifacts.json"
}

write_compare() {
  local base="$1" status="$2" behind="$3"
  jq -n --arg base "${base}" --arg status "${status}" --argjson behind "${behind}" \
    '{status: $status, behind_by: $behind, ahead_by: 3, merge_base_commit: {sha: $base}}' \
    > "${work}/compare.json"
}

mutate() {
  local file="$1" filter="$2"
  jq "${filter}" "${work}/${file}" > "${work}/${file}.tmp"
  mv "${work}/${file}.tmp" "${work}/${file}"
}

dispatch_fixture() {
  write_run workflow_dispatch "${main_sha}" "Untrusted candidate APK for ${target_sha}" main
  write_artifacts "${main_sha}"
  write_compare "${main_sha}" ahead 0
}

pull_request_fixture() {
  write_run pull_request "${target_sha}" "APP-09A: Fix geofence disarm and target update lifecycle" fix/app-09a-geofence-lifecycle
  write_artifacts "${target_sha}"
  write_compare "${other_sha}" diverged 4
}

run_verifier() {
  RUN_JSON="${work}/run.json" \
  ARTIFACTS_JSON="${work}/artifacts.json" \
  COMPARE_JSON="${work}/compare.json" \
  RUN_WORKFLOW_BLOB_SHA="${run_blob:-${workflow_blob}}" \
  TRUSTED_WORKFLOW_BLOB_SHA="${workflow_blob}" \
  EXPECTED_REPOSITORY="${repo}" \
  EXPECTED_SHA="${expected_sha:-${target_sha}}" \
  SOURCE_RUN_ID="${source_run_id:-${run_id}}" \
  SOURCE_ARTIFACT_ID="${source_artifact_id:-${artifact_id}}" \
  SOURCE_ARTIFACT_NAME="${source_artifact_name:-${artifact_name}}" \
    bash "${verifier}" candidate-run > "${work}/out.txt" 2>&1
}

accept() {
  local label="$1"
  run_verifier || { cat "${work}/out.txt" >&2; fail "expected acceptance: ${label}"; }
  passed=$((passed + 1))
}

reject() {
  local label="$1" reason="$2"
  if run_verifier; then
    cat "${work}/out.txt" >&2
    fail "expected rejection: ${label}"
  fi
  grep -Fq "${reason}" "${work}/out.txt" ||
    { cat "${work}/out.txt" >&2; fail "rejection for '${label}' did not mention '${reason}'"; }
  passed=$((passed + 1))
}

# --- pull_request candidates (path used for Build 13) -----------------------
pull_request_fixture
accept "pull_request candidate at approved PR head"

pull_request_fixture; expected_sha="${other_sha}"
reject "pull_request head differs from approved SHA" "is not the approved SHA"
unset expected_sha

pull_request_fixture; mutate run.json '.repository.full_name = "attacker/pingplace"'
reject "run from another repository" "run repository"

pull_request_fixture; mutate run.json '.path = ".github/workflows/other.yml"'
reject "run from another workflow" "run workflow"

pull_request_fixture; mutate run.json '.status = "in_progress"'
reject "run not completed" "run status"

pull_request_fixture; mutate run.json '.conclusion = "failure"'
reject "failed run" "run conclusion"

pull_request_fixture; mutate run.json '.id = 1'
reject "run response for a different run id" "run id"

for event in push schedule pull_request_target workflow_run repository_dispatch; do
  pull_request_fixture; mutate run.json ".event = \"${event}\""
  reject "unsupported event ${event}" "is not an accepted candidate trigger"
done

# --- artifact identity ------------------------------------------------------
pull_request_fixture; source_artifact_id="999"
reject "artifact id mismatch" "expected exactly one unexpired artifact"
unset source_artifact_id

pull_request_fixture; source_artifact_name="pingplace-untrusted-candidate-c7cfe7a-v1.0.0+13"
reject "artifact name mismatch" "expected exactly one unexpired artifact"
unset source_artifact_name

pull_request_fixture; mutate artifacts.json '.artifacts[0].expired = true'
reject "expired artifact" "expected exactly one unexpired artifact"

pull_request_fixture; mutate artifacts.json '.artifacts[0].workflow_run.id = 1'
reject "artifact from another run" "expected exactly one unexpired artifact"

pull_request_fixture; mutate artifacts.json ".artifacts[0].workflow_run.head_sha = \"${other_sha}\""
reject "artifact head differs from run head" "expected exactly one unexpired artifact"

pull_request_fixture; mutate artifacts.json '.artifacts += .artifacts'
reject "duplicate matching artifacts" "found 2"

pull_request_fixture; mutate artifacts.json '.artifacts = []'
reject "no artifacts" "found 0"

# --- caller input validation ------------------------------------------------
pull_request_fixture; expected_sha="${target_sha:0:7}"
reject "abbreviated expected SHA" "full lowercase 40-character"
expected_sha="$(tr '[:lower:]' '[:upper:]' <<< "${target_sha}")"
reject "uppercase expected SHA" "full lowercase 40-character"
expected_sha="main"
reject "branch name as expected SHA" "full lowercase 40-character"
unset expected_sha

pull_request_fixture; source_run_id="41196764279 "
reject "non-numeric run id" "SOURCE_RUN_ID must be numeric"
unset source_run_id

# --- workflow_dispatch candidates (SIGN-04) ---------------------------------
dispatch_fixture
accept "dispatch from main with title binding the approved SHA"

dispatch_fixture; write_compare "${main_sha}" identical 0
accept "dispatch from the current main commit"

dispatch_fixture; mutate run.json '.display_title = "Android untrusted candidate APK"'
reject "legacy dispatch run without SHA-binding run-name (run 41196764279)" "does not bind the approved SHA"

dispatch_fixture; mutate run.json ".display_title = \"Untrusted candidate APK for ${other_sha}\""
reject "dispatch title names a different SHA" "does not bind the approved SHA"

dispatch_fixture; mutate run.json ".display_title = \"Untrusted candidate APK for ${target_sha:0:7}\""
reject "dispatch title names an abbreviated SHA" "does not bind the approved SHA"

dispatch_fixture; mutate run.json ".display_title = \"Untrusted candidate APK for ${target_sha} \""
reject "dispatch title with trailing text" "does not bind the approved SHA"

dispatch_fixture; mutate run.json '.head_branch = "fix/app-09a-geofence-lifecycle"'
reject "dispatch from a non-main branch" "not main"

dispatch_fixture; write_compare "${other_sha}" diverged 2
reject "dispatch commit not on main history" "is not an ancestor of trusted main"

dispatch_fixture; write_compare "${main_sha}" behind 0
reject "main behind dispatch commit" "not identical or ahead"

dispatch_fixture; write_compare "${main_sha}" ahead 1
reject "compare reports main behind" "is behind the dispatch commit"

dispatch_fixture; printf 'not json' > "${work}/compare.json"
reject "unparseable compare response" "is not an ancestor of trusted main"

dispatch_fixture; run_blob="2222222222222222222222222222222222222222"
reject "candidate workflow definition differs from trusted main" "differs from trusted main"
unset run_blob

dispatch_fixture; mutate run.json '.head_sha = "main"'
reject "dispatch head is not a commit SHA" "full lowercase 40-character"

dispatch_fixture; mutate artifacts.json ".artifacts[0].workflow_run.head_sha = \"${target_sha}\""
reject "dispatch artifact head differs from run head" "expected exactly one unexpired artifact"

dispatch_fixture; expected_sha="${other_sha}"
reject "dispatch run used for a different approved SHA" "does not bind the approved SHA"
unset expected_sha

# --- signing environment approval gate --------------------------------------
env_verifier() {
  ENVIRONMENT_JSON="${work}/env.json" EXPECTED_ENVIRONMENT="pingplace-signed-test-approval" \
    bash "${verifier}" signing-environment > "${work}/out.txt" 2>&1
}
protected_env='{name: "pingplace-signed-test-approval", protection_rules: [
  {type: "required_reviewers", reviewers: [{type: "User", reviewer: {login: "bandora78"}}]}]}'

jq -n "${protected_env}" > "${work}/env.json"
env_verifier || { cat "${work}/out.txt" >&2; fail "expected protected environment to pass"; }
passed=$((passed + 1))

for filter in \
  '.protection_rules = []' \
  '.protection_rules = [{type: "wait_timer", wait_timer: 5}]' \
  '.protection_rules[0].reviewers = []' \
  '.name = "pingplace-signed-test-approval."' \
  'del(.protection_rules)'; do
  jq -n "${protected_env}" | jq "${filter}" > "${work}/env.json"
  if env_verifier; then fail "expected unprotected environment to be rejected: ${filter}"; fi
  grep -Fq "Provenance rejected" "${work}/out.txt" || fail "environment rejection was not reported: ${filter}"
  passed=$((passed + 1))
done

# --- candidate manifest identity --------------------------------------------
manifest_verifier() {
  MANIFEST_JSON="${work}/manifest.json" EXPECTED_SHA="${target_sha}" \
    bash "${verifier}" manifest > "${work}/out.txt" 2>&1
}
write_manifest() {
  jq -n --arg sha "${target_sha}" --arg short "${target_sha:0:7}" \
    '{source_sha: $sha, embedded_commit_sha: $short, package_id: "com.example.pingplace",
      version_name: "1.0.0", display_build_number: "14", version_code: 10014,
      apk_sha256: "bb0e2d4fbdbcd61d6ebe0064d4bbaeda0477be7e193e3df28d5a367b853e3219"}' > "${work}/manifest.json"
}

write_manifest
manifest_verifier || { cat "${work}/out.txt" >&2; fail "expected Build 14 manifest to pass"; }
passed=$((passed + 1))

for filter in \
  ".source_sha = \"${other_sha}\"" \
  '.embedded_commit_sha = "c3215f8"' \
  '.display_build_number = "13"' \
  '.display_build_number = "14a"' \
  '.version_code = 10013' \
  'del(.display_build_number)' \
  'del(.version_code)'; do
  write_manifest; mutate manifest.json "${filter}"
  if manifest_verifier; then fail "expected manifest rejection: ${filter}"; fi
  grep -Fq "Provenance rejected" "${work}/out.txt" || fail "manifest rejection was not reported: ${filter}"
  passed=$((passed + 1))
done

echo "Signed artifact provenance regression tests passed (${passed} cases)"
