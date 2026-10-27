#!/usr/bin/env bash
set -euo pipefail

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
mkdir -p "${root}/assets"
cat > "${root}/assets/pingplace-build-identity.json" <<'EOF'
{"source_sha":"abcdef0123456789abcdef0123456789abcdef01","embedded_commit_sha":"abcdef0","package_id":"com.example.pingplace","version_name":"1.0.0","version_code":10013}
EOF
(cd "${root}" && zip -q "${root}/candidate.apk" assets/pingplace-build-identity.json)
bash .github/scripts/verify-apk-build-identity.sh "${root}/candidate.apk" abcdef0123456789abcdef0123456789abcdef01 com.example.pingplace 1.0.0 10013
if bash .github/scripts/verify-apk-build-identity.sh "${root}/candidate.apk" 0000000123456789abcdef0123456789abcdef01 com.example.pingplace 1.0.0 10013; then
  echo "mismatched source SHA was accepted" >&2
  exit 1
fi
if bash .github/scripts/verify-apk-build-identity.sh "${root}/candidate.apk" abcdef0123456789abcdef0123456789abcdef01 com.example.pingplace 1.0.0 10012; then
  echo "mismatched versionCode was accepted" >&2
  exit 1
fi
rm "${root}/candidate.apk"
if bash .github/scripts/verify-apk-build-identity.sh "${root}/candidate.apk" abcdef0123456789abcdef0123456789abcdef01 com.example.pingplace 1.0.0 10013; then
  echo "missing identity asset was accepted" >&2
  exit 1
fi
echo "APK build identity regression tests passed"
