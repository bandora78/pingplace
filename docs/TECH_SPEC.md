# PingPlace Technical Specification

## Architecture
Flutter/Dart, Android first, iOS ready, local first. Domain logic must not depend directly on platform APIs.

Platform-facing abstractions:
- GeofenceService
- LocationService
- NotificationService
- PermissionService
- SpeechService
- PlaceSearchService

Persistence uses repositories such as PlaceRepository, ReminderRepository, DetectionStateRepository. SQLite-backed persistence is preferred for the full MVP.

## Detection ownership
Detection state belongs to Place, not individual reminders. One place has one detection context.

Runtime states:
DISARMED, ARMED, APPROACHING, ARRIVED, COOLDOWN, WAITING_FOR_EXIT.

## Smart Arrival
Experimental defaults:
- outerRadius: 300 m
- innerRadius: 80 m
- rearmRadius: 350 m
- cooldownDuration: 10 min

Use hysteresis: enter <= 300 m, rearm >= 350 m.

ARRIVE flow:
OS outer geofence -> temporary location samples -> distance/accuracy validation -> arrival -> one place-level notification -> cooldown -> exit/rearm.

Poor accuracy must not be treated as precise arrival evidence.

If exit is observed during cooldown, persist that fact so cooldown expiry can rearm without requiring another crossing.

## Departure
Use a DetectionStrategy abstraction. ArrivalStrategy and DepartureStrategy must remain separable. LEAVE is outside Phase 0.

## Lifecycle
Do not run permanent background GPS. Restore monitoring after normal process/app lifecycle events and device reboot where the platform permits. Force-stop must be tested/documented separately.

## NLP and voice
Future V1 parser should begin rule-based and support Hebrew/English patterns. Voice feeds speech-to-text into the same parser. These are outside Phase 0.

## Diagnostics
Debug Mode is mandatory from Phase 0. Expose target, distance, accuracy, state, radii, cooldown, monitoring status, and an event log. Diagnostics may record event/location samples during active verification but must not become passive location history.

## Engineering North Star
Ask “Has the condition for this reminder become true?” — not “Where is the user all day?”
