# PingPlace Phase 0 testing

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
