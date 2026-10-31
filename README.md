# pingplace

## Android debug APKs from pull requests

Every pull request targeting `main` runs the Android debug checks and build in GitHub Actions. After the workflow succeeds, open the repository's **Actions** tab, select **Android debug APK**, open the workflow run for the pull request, and download the artifact named `pingplace-debug-apk-<short-sha>-v<version>` from the **Artifacts** section. Artifacts are retained for 30 days.

The workflow produces the normal Flutter debug APK using the existing Android application ID and debug signing configuration, so it can be installed over an existing debug build when the signing keys are compatible. It does not create GitHub Releases.

## Consistently signed test APKs

The **Android signed test APK** workflow is manual-only and always checks out the trusted `main` branch. It uses a dedicated test keystore supplied through GitHub Actions secrets; it is separate from the pull-request workflow above, which continues to use the default Android debug signing behavior.

### One-time repository-owner setup

1. Create a dedicated, non-production test keystore locally. Do not use a release keystore:

   ```sh
   keytool -genkeypair -v \
     -keystore pingplace-debug.keystore \
     -alias pingplace-debug \
     -keyalg RSA -keysize 2048 -validity 10000
   ```

   Choose and record the keystore password, key password, and alias. Keep the keystore and passwords in encrypted, access-controlled backup storage. Never commit them to this repository. Keep an encrypted backup of the JKS and its credentials in access-controlled storage, and record the certificate fingerprint separately so rotation can be audited.

2. Base64-encode the keystore without changing its bytes. On Linux/macOS:

   ```sh
   base64 -w 0 pingplace-debug.keystore
   ```

   On PowerShell:

   ```powershell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes('pingplace-debug.keystore'))
   ```

3. In the repository, open **Settings → Secrets and variables → Actions → New repository secret** and configure these four secrets:

   - `PINGPLACE_KEYSTORE_BASE64`: the base64-encoded keystore
   - `PINGPLACE_KEYSTORE_PASSWORD`: the keystore password
   - `PINGPLACE_KEY_ALIAS`: `pingplace-debug` (or the chosen alias)
   - `PINGPLACE_KEY_PASSWORD`: the key password

   The workflow fails before reconstructing a keystore or building an APK when any secret is missing. Secrets are never printed, and the temporary keystore is removed even when a later step fails.

4. In **Actions → Android signed test APK → Run workflow**, select the `main` branch in the workflow's branch selector and run it. The signed job is guarded so it runs only for `main`; it builds only the current trusted `main` commit, verifies that the APK certificate matches the dedicated keystore, and uploads an artifact containing the app version, commit short SHA, and versionCode.

The signed workflow enforces this version policy: `versionCode = 10000 + GITHUB_RUN_NUMBER`. It reads the generated APK's actual Android manifest versionCode with Android `aapt` and fails if it differs. This is increasing for subsequent executions of this exact workflow. It is not a globally durable counter if the workflow is recreated or its run numbering is reset; in that case, or if an installed APK has a higher versionCode, increase the policy offset or perform the one-time uninstall migration before installing the next test APK.

If the APK currently installed on the Xiaomi 15 was signed with a different certificate, Android requires one final uninstall before the first APK signed with this dedicated key can be installed. After that migration, consecutive signed test APKs use the same certificate and increasing version codes, so they can be installed as updates.

To confirm signing consistency, download two consecutive signed artifacts, run `apksigner verify --print-certs <apk>` on each, and compare the `Signer #1 certificate SHA-256 digest` values. They must match; the workflow also performs this comparison against the keystore for every build.

## Two-stage signed candidate APKs

Code that is not yet on `main` is signed in two stages so the signing secrets never reach a job that executes project code:

1. **Android untrusted candidate APK** builds the exact source commit with no secrets and uploads `candidate/pingplace-candidate.apk` plus `manifest.json`. It runs automatically for pull requests targeting `main`, or manually from `main` with `target_sha` set to a full 40-character commit SHA. A manual run is titled `Untrusted candidate APK for <sha>`; that title is rendered from the trusted workflow definition before the build starts and is the only run metadata that binds the built commit to the run.
2. **Android trusted signed test APK** (dispatched from `main`) independently re-verifies the candidate through the GitHub API before the protected signing job runs:
   - the approved PR is open and its head equals `source_sha`;
   - the source run is a successful run of `android-untrusted-candidate.yml` in this repository;
   - for a `pull_request` run, the run head equals `source_sha`;
   - for a `workflow_dispatch` run, it was started from `main`, its commit is in the history of trusted `main`, its candidate workflow definition is byte-identical to the one on trusted `main`, and its title is exactly `Untrusted candidate APK for <source_sha>`;
   - the artifact ID and name belong to that run, are unexpired and unique;
   - the APK SHA-256, manifest, embedded identity asset, package, versionName and `versionCode = 10000 + display build number` all match, and the versionCode is newer than the issued baseline;
   - the `pingplace-signed-test-approval` environment has required reviewers.

   The signing job then signs with the dedicated key and checks the certificate against `PINGPLACE_TRUSTED_CERT_SHA256`. Manual candidate runs created before this check existed (for example run `41196764279`) carry no SHA-binding title and are rejected; dispatch a new candidate run instead.

The checks live in `.github/scripts/verify-candidate-provenance.sh` and are covered by `.github/scripts/test-signed-artifact-provenance.sh`.

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Task 03 Android geofence integration

The Phase 0 development screen now includes a separate **REAL GEOFENCE TEST** section. Android uses the official Google Play services Geofencing API behind `GeofenceService`; the pure Smart Arrival engine remains platform-independent and unchanged. See [TESTING.md](TESTING.md) for permissions, background behavior, force-stop limitations, and the first-device procedure.

## Read-only task watcher

Stage B watcher setup and verification are documented in [automation/README.md](automation/README.md). The watcher reads GitHub task metadata and local state only; it never dispatches work or installs its optional scheduled task automatically.

## Backup and rotation

Back up the JKS bytes, alias, store password, key password, and certificate SHA-256 fingerprint in separate access-controlled storage. To rotate the key, create a new JKS, verify its fingerprint locally, update the four repository secrets together, and update `PINGPLACE_TRUSTED_CERT_SHA256` only after the new certificate is approved. Never expose the JKS or passwords in logs, artifacts, pull requests, or issue comments.

Android requires an update APK to be signed by the same certificate as the installed package. Changing the signing key therefore prevents an in-place upgrade; users must uninstall the old package before installing the first APK signed with the replacement key, which also removes app data unless it has been backed up.

The signed workflow is manual-only, checks out trusted `main`, and is never used by pull-request code. Pull-request validation remains unsigned and receives no signing secrets.
