# pingplace

## Android debug APKs from pull requests

Every pull request targeting `main` runs the Android debug checks and build in GitHub Actions. After the workflow succeeds, open the repository's **Actions** tab, select **Android debug APK**, open the workflow run for the pull request, and download the artifact named `pingplace-debug-apk-<short-sha>-v<version>` from the **Artifacts** section. Artifacts are retained for 30 days.

The workflow produces the normal Flutter debug APK using the existing Android application ID and debug signing configuration, so it can be installed over an existing debug build when the signing keys are compatible. It does not create GitHub Releases.

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
