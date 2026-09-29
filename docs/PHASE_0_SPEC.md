# PingPlace Phase 0 Specification

## Purpose
Phase 0 is a technical experiment, not a mini-app. Its job is to prove Smart Arrival Detection in real-world Android conditions and explain failures.

## Scope
Include only:
- one test location
- ARRIVE only
- outer geofence
- inner proximity validation
- cooldown
- exit-to-rearm
- one local notification
- background operation
- persistent runtime state
- debug dashboard
- diagnostic event log
- development Simulation Mode

Exclude voice, NLP, multiple places, lists, LEAVE, accounts, cloud, map UI, and iOS implementation.

## Test location
Configurable name, latitude, longitude.
Initial defaults:
- outerRadius = 300 m
- innerRadius = 80 m
- rearmRadius = 350 m
- cooldownDuration = 10 min
- approachTimeout = 10 min
- maxAcceptedAccuracy = configurable

Target can initially be set using current location or manual coordinates. No map/search is required.

## States
- DISARMED
- ARMED
- APPROACHING
- ARRIVED
- COOLDOWN
- WAITING_FOR_EXIT

Successful path:
DISARMED -> ARM -> ARMED -> OUTER_ENTER -> APPROACHING -> INNER_REACHED -> ARRIVED -> NOTIFICATION -> COOLDOWN -> WAITING_FOR_EXIT -> REARM_RADIUS_CROSSED -> ARMED.

Nearby pass:
ARMED -> OUTER_ENTER -> APPROACHING -> OUTER_EXIT -> ARMED, with no notification.

## Arrival evidence
Arrival requires:
- state is APPROACHING
- distance <= innerRadius
- location accuracy meets configured threshold

Log every location sample used by the active verifier: distance, accuracy, timestamp (and coordinates in development diagnostics). Reject inadequate samples explicitly with LOW_ACCURACY.

## Cooldown and rearm
Only one notification per visit.
After arrival enter 10-minute cooldown.
Rearm requires leaving to at least rearmRadius.
If exit occurs during cooldown, persist exitObservedDuringCooldown=true; when cooldown expires, rearm immediately if the exit has already been observed.

## Approach timeout
While APPROACHING, precise location updates are temporary. Default experimental timeout is 10 minutes. If no arrival or exit is confirmed by then, stop active location and return to ARMED. Log APPROACH_TIMEOUT.

## Debug screen
Must show at least:
- target
- current/last distance
- accuracy
- detection state
- outer/inner/rearm radii
- cooldown
- geofence registered status
- precise location active status
- notification readiness
- RESET TEST
- VIEW EVENT LOG
- COPY LOG

SHARE LOG is strongly preferred.

## Diagnostic events
Examples:
APP_STARTED
GEOFENCE_REGISTERED
OUTER_ENTER
OUTER_EXIT
STATE old->new
LOCATION distance=... accuracy=...
LOCATION_REJECTED reason=LOW_ACCURACY
INNER_REACHED
NOTIFICATION_SENT
APPROACH_TIMEOUT

Explicit failures include:
GEOFENCE_REGISTRATION_FAILED
LOCATION_PERMISSION_MISSING
BACKGROUND_PERMISSION_MISSING
NOTIFICATION_PERMISSION_MISSING
LOCATION_SERVICES_DISABLED
LOCATION_UPDATE_TIMEOUT
BACKGROUND_EVENT_FAILED

Do not hide failures.

## Reset
RESET TEST clears runtime state, cooldown, exit flag, and test notification; preserves target/config/reminder, re-registers monitoring, and returns to ARMED.
A full reset may delete target, reminder, state, and log.

## Persistence
Persist target, reminder text, detection config, current state, cooldown timestamp, and exitObservedDuringCooldown. Normal app restart must preserve an armed test.

## Simulation Mode
Development-only controls:
- SIMULATE OUTER ENTER
- SIMULATE LOCATION 250m
- SIMULATE LOCATION 150m
- SIMULATE LOCATION 90m
- SIMULATE LOCATION 70m
- SIMULATE EXIT 400m

Simulation must invoke the same Detection Engine used by real events; do not duplicate fake detection logic.

## Minimum unit tests
- successful arrival
- nearby pass
- GPS jitter
- cooldown
- exit during cooldown
- rearm
- bad accuracy
- approach timeout

## Physical test matrix
T01 walk to target
T02 drive to target
T03 drive nearby without arriving
T04 stay >10 min
T05 leave >350 m
T06 return after rearm
T07 screen locked
T08 app backgrounded
T09 normal UI/process closed
T10 reboot
T11 poor GPS
T12 enter outer zone then move away

Capture test ID, date/time, WALK/CAR, expected result, actual result, notification yes/no, approximate trigger distance, event log, and notes.

## Metrics
Track true arrival detection, false positives, false negatives, trigger distance, duplicate rate, and practical battery impact.

Initial target: reliable actual arrivals, very low false positives, zero duplicate notifications, acceptable battery.

## Phase 0 deliverables
- Flutter project
- Android build configuration
- installable debug APK
- source
- README.md
- TESTING.md
- known limitations
- automated tests

## Definition of Done
Phase 0 is done when:
1. Debug build installs.
2. A target can be configured.
3. Test can be armed.
4. Outer entry is detected.
5. Inner arrival is confirmed.
6. Exactly one notification is produced per visit.
7. Duplicate protection works.
8. Exit/rearm works.
9. Runtime state survives normal restart.
10. Debug UI explains current state.
11. Diagnostic log can be copied.
12. Automated tests pass.
13. Real-world scenarios have been performed and recorded.

## Golden rule
Do not hide failures. If PingPlace fails to detect an arrival, Phase 0 must provide enough information to answer why.
