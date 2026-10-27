# Two-stage signed test APK pipeline

The untrusted candidate workflow builds an exact commit without signing secrets and uploads an APK plus a manifest containing the source SHA, package ID, version metadata, embedded build identity asset (assets/pingplace-build-identity.json), and APK SHA-256.

The trusted signing workflow is manual-only and runs on `main`. Before downloading the candidate it queries GitHub Actions for the source run and requires all of the following: the expected repository, the exact untrusted workflow path, pull-request event, approved PR head SHA, completed/successful conclusion, and a non-expired artifact with the requested ID/name belonging to that run.

It also verifies the previously issued signed Build 12 artifact from run `40400807491`, workflow `.github/workflows/android-signed-test-apk.yml`, head `274b395fcb998e57568fa32828f12ff0959f19dc`, and artifact `pingplace-signed-test-apk-1.0.0+9-274b395-build10007`. The baseline versionCode is extracted from that APK with `aapt`; the candidate is accepted only when its actual versionCode is strictly greater. The value `10007` is not used as the comparison source.

The signing job is protected by the `pingplace-signed-test-approval` GitHub Environment. Only after approval are the existing keystore secrets available. The signing job does not check out or execute the candidate repository, Flutter, Gradle, or project scripts. APK byte strings are never used as provenance proof; provenance comes from GitHub Actions API run/artifact identity and hash verification.

Configure the environment with required reviewers and set repository variable `PINGPLACE_TRUSTED_CERT_SHA256` to the dedicated test certificate fingerprint. Keep the existing keystore secrets unchanged.

The build identity is verified from a structured APK asset with `unzip` and `jq`; raw string searches through compressed APK bytes are not used. The asset is retained through re-signing and checked again in the trusted signing job.
