#!/usr/bin/env bash
set -euo pipefail

fail() { echo "expected failure: $1" >&2; exit 1; }
expect_failure() {
  if "$@"; then
    fail "$*"
  fi
}
verify_run() {
  local repo="$1" path="$2" event="$3" head="$4" expected="$5" status="$6" conclusion="$7"
  test "$repo" = "bandora78/pingplace"
  test "$path" = ".github/workflows/android-untrusted-candidate.yml"
  test "$event" = "pull_request"
  test "$head" = "$expected"
  test "$status" = "completed"
  test "$conclusion" = "success"
}
verify_artifact() {
  local artifact_run="$1" expected_run="$2" artifact_name="$3" expected_name="$4" expired="$5"
  test "$artifact_run" = "$expected_run"
  test "$artifact_name" = "$expected_name"
  test "$expired" = "false"
}
verify_upgrade() {
  local baseline="$1" candidate="$2"
  test "$baseline" -gt 0
  test "$candidate" -gt "$baseline"
}

verify_run bandora78/pingplace .github/workflows/android-untrusted-candidate.yml pull_request abc abc completed success
expect_failure verify_run bandora78/pingplace .github/workflows/android-untrusted-candidate.yml pull_request abc def completed success
expect_failure verify_run bandora78/pingplace .github/workflows/android-untrusted-candidate.yml workflow_dispatch abc abc completed success
expect_failure verify_run other/repo .github/workflows/android-untrusted-candidate.yml pull_request abc abc completed success
expect_failure verify_run bandora78/pingplace .github/workflows/other.yml pull_request abc abc completed success
verify_artifact 123 123 candidate candidate false
expect_failure verify_artifact 123 456 candidate candidate false
expect_failure verify_artifact 123 123 other candidate false
expect_failure verify_artifact 123 123 candidate candidate true
verify_upgrade 10007 10013
expect_failure verify_upgrade 10013 10007
expect_failure verify_upgrade 10007 10007
echo "Signed artifact provenance regression tests passed"
