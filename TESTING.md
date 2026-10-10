# PingPlace Phase 0 testing

## Real Android outer geofence test

This task uses the official Google Play services Location Geofencing API (`play-services-location:21.3.0`) through a native Android implementation behind `GeofenceService`. It supports one non-expiring outer geofence and ENTER/EXIT transitions. Android delivery is best-effort: location services, device power management, Google Play services, permission state, and device movement all affect timing. This task does not implement precise GPS verification, notifications, persistence/database, or final rearm wiring.

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
