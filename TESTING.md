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
