# Two-stage signed test APK pipeline

The untrusted candidate workflow builds an exact commit without signing secrets and uploads an APK plus a JSON manifest containing the source SHA, package ID, version metadata, embedded short commit identity, and APK SHA-256.

The trusted signing workflow is manual-only and runs on `main`. It first verifies that the requested PR is open and still points at the requested SHA, downloads only the named candidate artifact, verifies its hash and metadata, and republishes that verified artifact. Its signing job is protected by the `pingplace-signed-test-approval` GitHub Environment. Only after a reviewer approves that environment are the existing keystore secrets available. The signing job runs only Android SDK tools and shell commands; it does not check out or execute the candidate repository, Flutter, Gradle, or project scripts.

Configure the environment with required reviewers before use. Configure the repository variable `PINGPLACE_TRUSTED_CERT_SHA256` with the dedicated test certificate fingerprint. Keep the existing keystore secrets unchanged.

For Build 13, the candidate uses display Build 13 and Android versionCode 10013, which is greater than signed Build 12 versionCode 10007. A successful signing run still requires manual in-place installation testing over Build 12; automated metadata checks cannot prove that device upgrade preserves app data.
