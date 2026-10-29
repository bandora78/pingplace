#!/usr/bin/env bash
set -euo pipefail

apk_path="${1:?APK path is required}"
expected_sha="${2:?Expected full source SHA is required}"
expected_package="${3:?Expected package ID is required}"
expected_version="${4:?Expected versionName is required}"
expected_version_code="${5:?Expected versionCode is required}"

identity_json="$(unzip -p "${apk_path}" assets/pingplace-build-identity.json)"
test "$(jq -r .source_sha <<< "${identity_json}")" = "${expected_sha}"
test "$(jq -r .embedded_commit_sha <<< "${identity_json}")" = "${expected_sha:0:7}"
test "$(jq -r .package_id <<< "${identity_json}")" = "${expected_package}"
test "$(jq -r .version_name <<< "${identity_json}")" = "${expected_version}"
test "$(jq -r .version_code <<< "${identity_json}")" = "${expected_version_code}"
echo "Verified APK build identity asset"
