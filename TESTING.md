# PingPlace Phase 0 testing

## APP-04A desired-registration persistence

The schema-1 desired-registration record stores one target, radius, reminder text
and `desiredMonitoring`. Existing current/Activity preference namespaces are
migrated only when the canonical record is absent. Migration commits and verifies
the new record before use, preserves the source preferences and existing runtime
reminder, and never combines partial targets or falls back from a corrupt or
unsupported canonical record. Persistence diagnostics expose failure categories,
not stored coordinates, reminder contents or JSON parser details.

Registration/recovery must commit desired state before platform mutations.
Removal commits the same configuration with `desiredMonitoring=false` before
calling Android, keeping legacy data from being reactivated. Missing/corrupt
configuration fails closed; a failed platform removal remains disabled and is
reported as a failure. APP-04A adds no automatic removal retries, tombstones,
generation-based coordination or stale-callback suppression. The existing
startup confirmation shortcut is retained for APP-04B review.

Run `cd android && ./gradlew :app:testDebugUnitTest` for behavioral persistence,
migration and platform-call gating tests (including commit failure with an
in-memory-only write). These tests use real JSON serialization and storage/platform
fakes; they do not establish power-loss durability or OEM lifecycle behavior.
Also run the existing Flutter notification, cooldown and rearm tests. On Xiaomi,
verify upgrading preserves the target/reminder and that a removed target is not
restored after reopening/reboot. Physical validation is still required.

## Real Android outer geofence test

This task uses the official Google Play services Location Geofencing API (`play-services-location:21.3.0`) through a native Android implementation behind `GeofenceService`. It supports one non-expiring outer geofence and ENTER/EXIT transitions. Android delivery is best-effort: location services, device power management, Google Play services, permission state, and device movement all affect timing. The geofence-only procedure below is retained as the registration and outer-wake-up baseline; temporary precise verification and arrival notifications are covered in the Task 04 and Task 05 sections.

1. Install the debug APK on a physical Android device and open PingPlace.
2. In **REAL GEOFENCE TEST**, set the target latitude and longitude (or use the default test target).
3. Tap **REQUEST / CHECK PERMISSION**. Grant foreground location, then grant **Allow all the time** in Android app settings. The UI must show `BACKGROUND / ALWAYS ALLOWED`.
4. Tap **REGISTER OUTER GEOFENCE**. Confirm `REGISTERED` and `GEOFENCE_REGISTERED` in the real-geofence log.
5. Move outside the roughly 300 m outer radius.
6. Approach and enter the outer radius. Confirm `OUTER_ENTER_RECEIVED`, a timestamp, and the engine transition to `approaching` when the app process is available.
7. Repeat with the screen off and with the app backgrounded where possible.
8. Tap **REMOVE GEOFENCE** and confirm `GEOFENCE_REMOVED`; re-register to verify the replacement path.

Test these states separately:

- **App backgrounded:** the activity is not visible, but Android may keep the app process available for delivery.
- **App UI closed:** the task is removed or the process is recreated. The receiver retains one pending event for the next Flutter startup where Android delivers it; verify the event appears after reopening.
- **Android force-stop:** force-stop is a different state. Android may prevent the receiver and background execution until the user launches the app again. Do not treat force-stop as equivalent to normal background behavior.

Record the device model/Android version, permission state, screen/process state, approximate trigger distance, timestamps, and the complete visible diagnostic log. Automated Flutter tests cover translation/controller behavior only; they do not prove Android background delivery.

## Task 04 temporary precise-location verification

Task 04 keeps the outer geofence as a wake-up mechanism. A valid ENTER moves the
engine to `APPROACHING`, starts a temporary high-accuracy Android location
foreground service, and feeds samples into the same pure Dart detection engine.
The service stops after arrival, outer EXIT, approach timeout, location failure,
reset, or disposal. The foreground notification is a platform requirement for
near-real-time background samples; this is not permanent tracking.

### T04-01 — Normal arrival

1. Grant foreground and background location permission, then register a target.
2. Begin outside the roughly 300 m outer radius and enter it.
3. Confirm `OUTER_ENTER_RECEIVED`, `APPROACHING`, and `PRECISE_LOCATION_STARTED`.
4. Confirm latitude, longitude, timestamp, distance, and accuracy samples appear.
5. Approach within roughly 80 m and confirm `INNER_REACHED`, `ARRIVED CONFIRMED`,
   `STATE APPROACHING -> ARRIVED`, and `PRECISE_LOCATION_STOPPED`.

### T04-02 — Nearby pass

Enter the outer region but remain outside the inner radius, then leave the outer
region. Confirm no arrival, `OUTER_EXIT_RECEIVED`, return to `ARMED`, and stopped
precise location.

### T04-03 — Poor GPS

Repeat near the target where reported accuracy is worse than the configured
maximum. Confirm samples remain visible, `LOCATION_REJECTED reason=LOW_ACCURACY`
is logged, and the engine does not confirm arrival.

### T04-04 — Timeout

Enter `APPROACHING` and remain without a valid inner-radius sample until the
configured 10-minute timeout. Confirm `APPROACH_TIMEOUT`, return to `ARMED`, and
stopped precise location.

### T04-05 — Background

Repeat T04-01 with the screen off and the app backgrounded. Record actual device
behavior; Android background execution and OEM power management can affect
delivery. Distinguish foreground, background, UI closed/process recreated, and
force-stop. Force-stop may prevent future receiver/service delivery until the
user launches the app again.

For each run record device model, Android version, permission state, approximate
outer/inner trigger distances, sample accuracy, time from outer trigger to inner
confirmation, duplicate events, errors, and the complete diagnostic log.

Automated Flutter tests verify orchestration and domain behavior only; they do
not prove Android background GPS behavior or OEM-specific power-management
behavior.

### T04-06 — Cold/background geofence entry

1. Register the target and confirm background location permission.
2. Move outside the outer radius.
3. Put PingPlace in normal background or close the UI/process as appropriate.
4. Do **not** force-stop PingPlace.
5. Enter the outer radius.
6. Verify the geofence receiver starts temporary arrival verification without
   manually reopening the UI. A visible low-importance foreground-service
   notification is expected while verification is active.
7. Continue inside the inner radius and verify the headless Dart engine records
   `INNER_REACHED`/arrival processing and stops the service.
8. Reopen PingPlace and verify the persisted geofence/location event history is
   replayed and the diagnostic state is reconciled.

The geofence transition is an Android 12+ foreground-service start exemption,
but the app must still have the required background location permission and the
service must declare the `location` foreground-service type. Android 14+ also
enforces the matching foreground-service permission. OEM power management,
location settings, and process death can still prevent or delay delivery; record
the actual result. Force-stop is a separate state and can block receiver/service
delivery until the user launches PingPlace again.

## Geofence PendingIntent registration regression

Physical testing on a Xiaomi 15 exposed `ApiException: 10: PendingIntent must be mutable` during geofence registration. The geofence PendingIntent now uses `FLAG_UPDATE_CURRENT` plus `FLAG_MUTABLE` on Android 12/API 31 and later. Earlier Android versions omit the mutability flag for compatibility. Registration, removal, and restoration continue to use the same explicit `GeofenceBroadcastReceiver`, request code `4202`, and PendingIntent helper.

Retest procedure:

1. Install the current debug APK and grant the requested location permissions.
2. Register a test place and confirm registration succeeds without `ApiException: 10`.
3. Confirm diagnostics show the geofence as registered.
4. Remove and re-register the same test place to verify removal and registration use the same PendingIntent identity.
5. Repeat the cold/background geofence procedure without force-stopping the app and record whether temporary verification starts in the background.

Record the device model, Android version, permission state, registration/removal results, foreground-service notification behavior, and any logcat errors. This fix requires physical Android verification; Dart tests cannot prove OEM geofencing behavior.

## Task 05 real Android arrival notifications

Task 05 adds a separate `Arrival reminders` notification channel. The temporary
GPS foreground-service notification remains distinct and is expected only while
precise verification is active. Android 13/API 33 and later require
`POST_NOTIFICATIONS`; the permission request is available from the visible UI
only. A denied permission is shown as `DENIED`, logged as
`NOTIFICATION_PERMISSION_MISSING`, and can be revisited through **NOTIFICATION
SETTINGS**. Normal Android background/process termination is not the same as
Force Stop; HyperOS battery management may still delay or suppress delivery.

### Xiaomi 15 notification test

1. Install the current debug APK, open PingPlace, and tap **ALLOW NOTIFICATIONS**.
2. Confirm the real-geofence diagnostics show notification readiness as
   `ALLOWED`. If permission was previously denied, use **NOTIFICATION SETTINGS**.
3. Register one test target while outside its roughly 300 m outer radius.
4. Background PingPlace without force-stopping it.
5. Enter the outer radius and then the roughly 80 m inner radius.
6. Verify exactly one visible notification titled `PingPlace — הגעת ליעד`.
   Confirm the body is the persisted reminder text and that tapping it opens
   PingPlace.
7. Drive or walk past the target and return during the 10-minute cooldown.
   Confirm there is no second notification and diagnostics contain
   `NOTIFICATION_SUPPRESSED_DUPLICATE` only if a duplicate delivery was
   attempted.
8. After the cooldown and a valid rearm beyond the configured rearm radius,
   return to the target and verify a new visit can produce one new notification.
9. Open PingPlace and verify the persisted engine state, current/last visit,
   last notification result and timestamp, background diagnostics, and event log.
10. Repeat with the Flutter UI/process not running, without Android Force Stop,
    to verify cold-background delivery through the headless engine.

Record device model (Xiaomi 15), Android/HyperOS version, notification and
location permission states, whether the UI was foreground/background/closed,
approximate outer and inner trigger distances, GPS accuracy, time to
notification, duplicate callbacks, foreground-service notification visibility,
and errors. Confirm `NOTIFICATION_SENT` appears only after the native Android
notification request succeeds. Automated tests cover the shared engine,
persistent handoff, and notification deduplication abstractions; they cannot
prove Android channel behavior, OEM delivery, or cold-process execution without
a physical device. A geofence EXIT alone is not treated as crossing the 350 m
rearm radius: the headless path starts temporary verification and requires an
accurate GPS sample. Poor accuracy can leave the visit in `WAITING_FOR_EXIT`.
Xiaomi/HyperOS battery optimization, process eviction, notification settings,
and Force Stop can still prevent or delay the receiver, foreground service, or
arrival notification; record those outcomes separately.

## Task 05.1 UI and registration regressions

1. On Android 13+ tap **ALLOW NOTIFICATIONS** from the visible PingPlace UI.
   Confirm the system permission prompt appears once, then confirm diagnostics
   refresh to `ALLOWED` after granting it. On a previously denied permission,
   confirm the button reports that settings are required and use
   **NOTIFICATION SETTINGS**.
2. Tap **NOTIFICATION SETTINGS** and confirm the app's notification settings
   page opens. On devices without that route, confirm it falls back to the app
   details page and any failure is visible in the diagnostics.
3. On a fresh install, wait for initialization to finish before registering.
   Confirm the latitude and longitude fields show ordinary decimal degrees and
   registration succeeds for values such as `31.664913` and `34.8`.
4. Register, close and reopen PingPlace, and confirm the restored fields match
   the registered coordinates exactly; they must not be scaled (for example,
   `31.664913` must not become `3.10664913E8`).
5. Try latitude outside `[-90, 90]`, longitude outside `[-180, 180]`, and
   malformed text. Confirm registration is rejected before the Android API is
   called and a short validation error is shown.

These checks require physical Android verification for OEM settings intents,
permission-dialog behavior, and first-launch state restoration. They do not
change the existing exactly-one-notification-per-visit or background delivery
test procedure.

## Task 06 versioned APKs

Every push to `main` runs the **Flutter validation and debug APK** workflow in
GitHub Actions. Open the repository's **Actions** tab, select the completed
workflow run for the desired commit, and download the artifact named like
`pingplace-1.0.0+6-<commit>`. The APK filename contains the same version/build
and short source commit shown in the app's debug screen. GitHub Actions is the
distribution path; APK binaries are not committed to the repository.

To install a downloaded debug APK with ADB:

```bash
adb install -r pingplace-1.0.0+6-<commit>.apk
```

If Android reports a signature conflict, uninstall the previous debug build
first, then install again. The workflow build receives the exact GitHub commit
SHA through `--dart-define`; local builds without that define display
`Commit: unknown` as the intentional fallback.

## Task 06.1 consistent debug signing

The CI artifact is intentionally signed with the same local debug keystore so
it can update the locally installed `com.example.pingplace` app and preserve
its data. The keystore and passwords are never committed. The workflow fails
before building if any required secret is missing.

One-time Windows PowerShell setup, using GitHub CLI:

```powershell
$keystorePath = Join-Path $env:USERPROFILE '.android\debug.keystore'
if (-not (Test-Path -LiteralPath $keystorePath)) { throw "Missing $keystorePath" }
$alias = 'androiddebugkey'
$storePassword = 'android'
$keyPassword = 'android'
keytool -list -v -keystore $keystorePath -alias $alias -storepass $storePassword |
  Select-String 'Alias name:|SHA256:'

function Set-GitHubSecretFromText([string] $name, [string] $value) {
  $temp = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllText($temp, $value)
    Get-Content -LiteralPath $temp -Raw | gh secret set $name --body-file -
  } finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  }
}

$keystoreBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($keystorePath))
Set-GitHubSecretFromText 'PINGPLACE_DEBUG_KEYSTORE_BASE64' $keystoreBase64
Set-GitHubSecretFromText 'PINGPLACE_DEBUG_KEYSTORE_PASSWORD' $storePassword
Set-GitHubSecretFromText 'PINGPLACE_DEBUG_KEY_ALIAS' $alias
Set-GitHubSecretFromText 'PINGPLACE_DEBUG_KEY_PASSWORD' $keyPassword
```

The commands assume the standard Android debug keystore values. If the local
keystore uses different credentials, determine the alias with `keytool -list`
and enter the credentials in memory instead; never print them or commit them.
The four required repository secrets are
`PINGPLACE_DEBUG_KEYSTORE_BASE64`, `PINGPLACE_DEBUG_KEYSTORE_PASSWORD`,
`PINGPLACE_DEBUG_KEY_ALIAS`, and `PINGPLACE_DEBUG_KEY_PASSWORD`. The workflow
reconstructs the keystore only in the ephemeral runner workspace and removes it
after the build.

To compare certificates, obtain the local fingerprint without exposing private
material:

```powershell
keytool -list -v -keystore "$env:USERPROFILE\.android\debug.keystore" `
  -alias androiddebugkey -storepass android | Select-String 'SHA256:'
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
$apksigner = Get-ChildItem (Join-Path $sdk 'build-tools') -Recurse -Filter apksigner.bat |
  Sort-Object FullName -Descending | Select-Object -First 1
& $apksigner.FullName verify --print-certs .\pingplace-1.0.0+6-<commit>.apk
```

The SHA-256 certificate fingerprints must match. Matching fingerprints plus
the unchanged application ID allow an update install and preserve app data;
the CI signing setup is not considered verified until the user creates the
secrets, downloads the artifact, and confirms the fingerprints and update on a
device.

## Task 06.2 Build 10 in-place upgrade validation

Build 10 is a minimal versioned APK intended to validate an in-place update from
the consistently signed Build 9 artifact. The signed Build 9 baseline is the
artifact named
`pingplace-signed-test-apk-1.0.0+9-274b395-build10007` from workflow run
[40400807491](https://github.com/bandora78/pingplace/actions/runs/40400807491).
Its Android `versionCode` is 10007.

After this PR is merged, run the trusted signed APK workflow and record the
actual artifact name, commit, `versionCode`, and certificate fingerprint. The
existing workflow strategy is `10000 + GITHUB_RUN_NUMBER`; the next run must
produce a value greater than 10007 (normally 10008 if the next run number is 8).

Manual device test:

1. Start with signed Build 9 installed; do not uninstall it.
2. Confirm an existing target is saved and record its reminder and diagnostics.
3. Install the signed Build 10 APK over Build 9 without uninstalling.
4. Confirm Android accepts the installation and the application still opens.
5. Confirm the app displays `Build 10` and the expected source commit.
6. Confirm the previously saved target and reminder remain intact.
7. Open **Geofence Diagnostics** and record the registration status after upgrade.
8. Record the actual device, Android/HyperOS version, APK artifact, versionCode,
   certificate fingerprint, and result. Do not mark this test passed without
   physical device evidence.

## Task 07 background resilience matrix

Use a registered target while outside the outer radius. Record device model,
Android/HyperOS version, permission state, location-services state, current
engine state, recovery timestamps, and the diagnostic log for each case.

| Case | Procedure | Expected behavior |
| --- | --- | --- |
| App backgrounded | Background normally | Geofence and temporary verification remain available as Android allows. |
| Screen locked | Lock the screen before entering the outer radius | Foreground-service notification appears during temporary GPS; arrival remains exactly once. |
| Removed from recents | Swipe PingPlace away without Force Stop | Geofence receiver may continue; reopen and verify persisted state and diagnostics. |
| OS process kill | Let HyperOS/Android reclaim the process, then trigger the geofence | Headless engine restores the persisted state; a completed visit does not notify again. |
| Reboot/unlock | Reboot, unlock, wait for recovery, then use **CHECK / RESTORE GEOFENCE** if needed | `BOOT_RECOVERY_STARTED`, `BOOT_RECOVERY_COMPLETED`, and `GEOFENCE_RESTORED` are visible; no notification is generated by reboot alone. |
| Cooldown restart | Arrive, then restart/reopen during the 10-minute cooldown | Cooldown and visit identity remain intact; repeated ENTER does not notify again. |
| Rearm restart | Observe EXIT/rearm verification, then restart before a valid 350 m sample | Waiting/rearm state is restored; only an accurate sample can rearm. |
| Permissions revoked | Revoke background location, then run recovery | Recovery fails visibly with an actionable permission error; no GPS starts. |
| Location disabled | Disable device location services, then run recovery | Recovery fails visibly; no stale registration is reported as confirmed. |
| HyperOS restrictions | Repeat with battery saver/autostart restrictions enabled and disabled | Record actual receiver/service behavior; do not infer support from saved preferences. |

Android may defer `BOOT_COMPLETED` until the first device unlock because the
application uses credential-encrypted preferences. Recovery never starts a
location foreground service directly from boot. Android Force Stop is a hard
platform boundary: after Force Stop, receiver delivery may remain blocked until
the user launches the app, and PingPlace does not claim to bypass that state.
Normal process termination and removal from recents are separate from Force
Stop. The platform registration status is confirmed only after the geofencing
API accepts the restored request; saved coordinates alone are not proof.

## Task 07 production UI and Build 10 to Build 11 upgrade

The normal app launch now opens the Hebrew-first production home screen. It shows
the single active target, reminder, monitoring status, and actionable permission
or recovery errors. Simulation controls, raw event logs, and detailed geofence
diagnostics are not shown there.

Developer Mode is deliberately hidden behind a long press on the version
information at the bottom of the home screen. It retains Simulation Mode, real
geofence diagnostics, recovery controls, event logs, and copy/share diagnostics.
The geofence controller is owned by the app root, so navigating between screens
does not start or stop monitoring subscriptions.

Manual upgrade test:

1. Start with the signed Build 10 installed and an existing target saved.
2. Record the current target, reminder, monitoring status, and displayed commit.
3. Install signed Build 11 over Build 10 without uninstalling.
4. Confirm Android accepts the update and the app opens on the production home screen.
5. Confirm the screen displays Build 11 and the expected commit.
6. Confirm the saved target and reminder are unchanged.
7. Confirm monitoring status and permission diagnostics reconcile after launch.
8. Long-press the version information and confirm Developer Mode opens; verify simulation and diagnostics remain available.
9. Record device model, Android/HyperOS version, artifact, versionCode, certificate fingerprint, and actual result. Do not mark this test passed without physical device evidence.

The following Phase 0 physical checks remain required on Xiaomi 15: background and
cold-process geofence entry, arrival notification exactly-once behavior, exit
beyond 350 m and re-entry, reboot recovery, permission revocation, location
services disabled, and HyperOS battery/autostart restrictions. APP-07 does not
claim those checks passed.


## APP-08 Build 11 -> Build 12 persistence upgrade

Build 12 (1.0.0+12) introduces the local place/reminder persistence document.
The first launch after upgrading from Build 11 must be tested without uninstalling
the app:

1. Install signed Build 11 and save a target, reminder, and monitoring state.
2. Confirm the target coordinates, radius, reminder, and monitoring intent in
   Geofence Diagnostics.
3. Install signed Build 12 over Build 11 without clearing app data.
4. Confirm one migrated place and reminder are present and the displayed version
   is Build 12.
5. Restart the app and reboot once; confirm migration does not create a duplicate
   place and the original target/reminder remain unchanged.
6. Confirm a disabled Build 11 target remains disabled and is not re-registered.
7. Confirm migration does not produce a register/remove operation. Multi-place
   simultaneous monitoring is intentionally not part of APP-08.
8. Record the actual device, Android version, installed APK metadata, target
   preservation, reminder preservation, duplicate count, and diagnostics.

Automated tests cover repository CRUD, persistence across repository
reinitialization, write failures, valid/idempotent migration, missing legacy
data, corrupt/partial-write fail-closed behavior, and the no-mutation migration
boundary. They do not prove SharedPreferences power-loss durability or OEM
process/reboot behavior; record those only from a physical device.

### APP-08 review regression coverage

The automated persistence tests cover conflicting Android/runtime legacy
records, disabled desired monitoring, corrupt and malformed documents,
validation of IDs/references/coordinates/radii/durations, failed commits,
concurrent migration and repository writes, idempotent migration, and the
absence of platform register/remove calls. A migration initialization failure
is exposed through the coordinator diagnostic field and must be recorded with
its type and reason.
## APP-09 multi-place validation

Verify multiple enabled places, overlapping regions, per-place cooldown/rearm,
removed/disabled IDs, duplicate ENTER/EXIT delivery, process/reboot recovery,
partial registration failure, and the copyable Developer Mode report. Android's
simultaneous geofence limit and Xiaomi/HyperOS delivery behavior must be recorded
from a physical device; automated tests do not prove OEM delivery.
