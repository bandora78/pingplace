#!/usr/bin/env bash
set -euo pipefail

pubspec_file="pubspec.yaml"
build_info_file="lib/src/build_info.dart"
workflow_file=".github/workflows/android-signed-test-apk.yml"

version_line="$(sed -nE 's/^version:[[:space:]]*([^[:space:]]+).*$/\1/p' "${pubspec_file}" | head -n 1)"
if [[ "${version_line}" != "1.0.0+12" ]]; then
  echo "Expected pubspec version 1.0.0+12, got ${version_line}" >&2
  exit 1
fi

if ! grep -Fq "defaultValue: '12'" "${build_info_file}"; then
  echo "BuildInfo default build number is not 12" >&2
  exit 1
fi

if ! grep -Fq 'build_number="$((10000 + GITHUB_RUN_NUMBER))"' "${workflow_file}"; then
  echo "Signed workflow no longer uses the increasing versionCode strategy" >&2
  exit 1
fi

if ! grep -Fq -- '--build-number "${{ steps.version.outputs.build_number }}"' "${workflow_file}"; then
  echo "Signed APK does not use the workflow versionCode output" >&2
  exit 1
fi

if ! grep -Fq 'display_build_number="${version_line##*+}"' "${workflow_file}"; then
  echo "Signed workflow does not derive the displayed build number from pubspec.yaml" >&2
  exit 1
fi

if ! grep -Fq -- '--dart-define=PINGPLACE_BUILD_NUMBER="${{ steps.version.outputs.display_build_number }}"' "${workflow_file}"; then
  echo "Displayed build number is not synchronized with the package build number" >&2
  exit 1
fi

if grep -Fq -- '--dart-define=PINGPLACE_BUILD_NUMBER="${{ steps.version.outputs.build_number }}"' "${workflow_file}"; then
  echo "Displayed build number incorrectly uses Android versionCode" >&2
  exit 1
fi

baseline_version_code=10007
next_run_number=8
next_version_code=$((10000 + next_run_number))
if (( next_version_code <= baseline_version_code )); then
  echo "The next signed APK versionCode would not upgrade Build 9" >&2
  exit 1
fi

echo "Build 12 version metadata and signed versionCode strategy passed"
