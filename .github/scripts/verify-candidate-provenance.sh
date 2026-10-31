#!/usr/bin/env bash
# Pure provenance checks for the two-stage signed test APK pipeline.
#
# Every check reads JSON that the trusted workflow fetched from the GitHub API
# into local files, so the same code path is exercised by the regression tests
# in test-signed-artifact-provenance.sh with fixture JSON. No caller-supplied
# value is trusted on its own: each one must agree with independent API data.
#
# Usage:
#   verify-candidate-provenance.sh candidate-run
#     env: RUN_JSON ARTIFACTS_JSON COMPARE_JSON RUN_WORKFLOW_BLOB_SHA
#          TRUSTED_WORKFLOW_BLOB_SHA EXPECTED_REPOSITORY EXPECTED_SHA
#          SOURCE_RUN_ID SOURCE_ARTIFACT_ID SOURCE_ARTIFACT_NAME
#   verify-candidate-provenance.sh signing-environment
#     env: ENVIRONMENT_JSON EXPECTED_ENVIRONMENT
#   verify-candidate-provenance.sh manifest
#     env: MANIFEST_JSON EXPECTED_SHA
set -euo pipefail

readonly CANDIDATE_WORKFLOW_PATH=".github/workflows/android-untrusted-candidate.yml"
readonly DISPATCH_TITLE_PREFIX="Untrusted candidate APK for "
readonly VERSION_CODE_OFFSET=10000

reject() {
  echo "::error::Provenance rejected: $*" >&2
  exit 1
}

require_env() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      reject "required value ${name} is empty"
    fi
  done
}

require_full_sha() {
  local label="$1" value="$2"
  if ! [[ "${value}" =~ ^[0-9a-f]{40}$ ]]; then
    reject "${label} must be a full lowercase 40-character commit SHA, got '${value}'"
  fi
}

json_field() {
  jq -er "$2 // empty | tostring" "$1" 2>/dev/null || true
}

verify_candidate_run() {
  require_env RUN_JSON ARTIFACTS_JSON EXPECTED_REPOSITORY EXPECTED_SHA \
    SOURCE_RUN_ID SOURCE_ARTIFACT_ID SOURCE_ARTIFACT_NAME
  require_full_sha "EXPECTED_SHA" "${EXPECTED_SHA}"
  [[ "${SOURCE_RUN_ID}" =~ ^[0-9]+$ ]] || reject "SOURCE_RUN_ID must be numeric"
  [[ "${SOURCE_ARTIFACT_ID}" =~ ^[0-9]+$ ]] || reject "SOURCE_ARTIFACT_ID must be numeric"

  local repo path status conclusion event run_id run_head_sha
  repo="$(json_field "${RUN_JSON}" '.repository.full_name')"
  path="$(json_field "${RUN_JSON}" '.path')"
  status="$(json_field "${RUN_JSON}" '.status')"
  conclusion="$(json_field "${RUN_JSON}" '.conclusion')"
  event="$(json_field "${RUN_JSON}" '.event')"
  run_id="$(json_field "${RUN_JSON}" '.id')"
  run_head_sha="$(json_field "${RUN_JSON}" '.head_sha')"

  [[ "${run_id}" == "${SOURCE_RUN_ID}" ]] || reject "run id ${run_id} does not match ${SOURCE_RUN_ID}"
  [[ "${repo}" == "${EXPECTED_REPOSITORY}" ]] || reject "run repository '${repo}' is not ${EXPECTED_REPOSITORY}"
  [[ "${path}" == "${CANDIDATE_WORKFLOW_PATH}" ]] || reject "run workflow '${path}' is not ${CANDIDATE_WORKFLOW_PATH}"
  [[ "${status}" == "completed" ]] || reject "run status is '${status}', not completed"
  [[ "${conclusion}" == "success" ]] || reject "run conclusion is '${conclusion}', not success"

  case "${event}" in
    pull_request)
      # The workflow ran on the PR head itself, so the run head is the build source.
      [[ "${run_head_sha}" == "${EXPECTED_SHA}" ]] ||
        reject "pull_request run head ${run_head_sha} is not the approved SHA ${EXPECTED_SHA}"
      ;;
    workflow_dispatch)
      verify_dispatch_run "${run_head_sha}"
      ;;
    *)
      reject "run event '${event}' is not an accepted candidate trigger"
      ;;
  esac

  local matches
  matches="$(jq --arg id "${SOURCE_ARTIFACT_ID}" --arg name "${SOURCE_ARTIFACT_NAME}" \
    --arg run "${SOURCE_RUN_ID}" --arg head "${run_head_sha}" \
    '[.artifacts[]? | select((.id|tostring) == $id
       and .name == $name
       and .expired == false
       and (.workflow_run.id|tostring) == $run
       and .workflow_run.head_sha == $head)] | length' "${ARTIFACTS_JSON}")" ||
    reject "artifacts response could not be parsed"
  [[ "${matches}" == "1" ]] ||
    reject "expected exactly one unexpired artifact ${SOURCE_ARTIFACT_ID} '${SOURCE_ARTIFACT_NAME}' from run ${SOURCE_RUN_ID}, found ${matches}"

  echo "Verified ${event} candidate run ${SOURCE_RUN_ID} builds ${EXPECTED_SHA} and owns artifact ${SOURCE_ARTIFACT_ID}"
}

# A workflow_dispatch run reports the dispatching ref (main) as head_sha, not the
# commit it built. The built commit is bound to the run only through run-name,
# which GitHub renders from the workflow definition before any job starts, so
# untrusted build code cannot alter it. That binding is only meaningful when
# the workflow definition itself is the trusted one, which is checked here.
verify_dispatch_run() {
  local run_head_sha="$1"
  require_env COMPARE_JSON RUN_WORKFLOW_BLOB_SHA TRUSTED_WORKFLOW_BLOB_SHA
  require_full_sha "dispatch run head_sha" "${run_head_sha}"

  local head_branch title compare_status behind_by compare_base
  head_branch="$(json_field "${RUN_JSON}" '.head_branch')"
  title="$(json_field "${RUN_JSON}" '.display_title')"

  [[ "${head_branch}" == "main" ]] ||
    reject "workflow_dispatch run was started from '${head_branch}', not main"

  compare_base="$(json_field "${COMPARE_JSON}" '.merge_base_commit.sha')"
  compare_status="$(json_field "${COMPARE_JSON}" '.status')"
  behind_by="$(json_field "${COMPARE_JSON}" '.behind_by')"
  [[ "${compare_base}" == "${run_head_sha}" ]] ||
    reject "dispatch commit ${run_head_sha} is not an ancestor of trusted main (merge base '${compare_base}')"
  [[ "${compare_status}" == "identical" || "${compare_status}" == "ahead" ]] ||
    reject "trusted main compared to dispatch commit is '${compare_status}', not identical or ahead"
  [[ "${behind_by}" == "0" ]] ||
    reject "trusted main is behind the dispatch commit by ${behind_by} commits"

  [[ "${RUN_WORKFLOW_BLOB_SHA}" == "${TRUSTED_WORKFLOW_BLOB_SHA}" ]] ||
    reject "candidate workflow at ${run_head_sha} (blob ${RUN_WORKFLOW_BLOB_SHA}) differs from trusted main (blob ${TRUSTED_WORKFLOW_BLOB_SHA})"

  [[ "${title}" == "${DISPATCH_TITLE_PREFIX}${EXPECTED_SHA}" ]] ||
    reject "dispatch run title '${title}' does not bind the approved SHA ${EXPECTED_SHA}"
}

verify_signing_environment() {
  require_env ENVIRONMENT_JSON EXPECTED_ENVIRONMENT
  local name reviewers
  name="$(json_field "${ENVIRONMENT_JSON}" '.name')"
  [[ "${name}" == "${EXPECTED_ENVIRONMENT}" ]] ||
    reject "environment response is for '${name}', not '${EXPECTED_ENVIRONMENT}'"
  reviewers="$(jq '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?] | length' \
    "${ENVIRONMENT_JSON}")" || reject "environment response could not be parsed"
  [[ "${reviewers}" =~ ^[0-9]+$ && "${reviewers}" -ge 1 ]] ||
    reject "environment '${EXPECTED_ENVIRONMENT}' has no required reviewers, so signing would not wait for approval"
  echo "Verified environment '${EXPECTED_ENVIRONMENT}' requires approval from ${reviewers} reviewer(s)"
}

verify_manifest() {
  require_env MANIFEST_JSON EXPECTED_SHA
  require_full_sha "EXPECTED_SHA" "${EXPECTED_SHA}"
  local source_sha embedded display version_code
  source_sha="$(json_field "${MANIFEST_JSON}" '.source_sha')"
  embedded="$(json_field "${MANIFEST_JSON}" '.embedded_commit_sha')"
  display="$(json_field "${MANIFEST_JSON}" '.display_build_number')"
  version_code="$(json_field "${MANIFEST_JSON}" '.version_code')"
  [[ "${source_sha}" == "${EXPECTED_SHA}" ]] || reject "manifest source_sha '${source_sha}' is not ${EXPECTED_SHA}"
  [[ "${embedded}" == "${EXPECTED_SHA:0:7}" ]] || reject "manifest embedded_commit_sha '${embedded}' is not ${EXPECTED_SHA:0:7}"
  [[ "${display}" =~ ^[1-9][0-9]*$ ]] || reject "manifest display_build_number '${display}' is not a positive integer"
  [[ "${version_code}" =~ ^[1-9][0-9]*$ ]] || reject "manifest version_code '${version_code}' is not a positive integer"
  [[ "${version_code}" == "$((VERSION_CODE_OFFSET + display))" ]] ||
    reject "manifest version_code ${version_code} is not ${VERSION_CODE_OFFSET} + display build ${display}"
  echo "Verified manifest for ${EXPECTED_SHA:0:7}: display build ${display}, versionCode ${version_code}"
}

case "${1:-}" in
  candidate-run) verify_candidate_run ;;
  signing-environment) verify_signing_environment ;;
  manifest) verify_manifest ;;
  *) echo "usage: $0 candidate-run|signing-environment|manifest" >&2; exit 2 ;;
esac
