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


## Phase 1 APP-08 persistence

APP-08 adds a durable, Android-local place database behind PlaceRepository and
ReminderRepository. The Flutter repositories share one serialized
PlaceDatabase; a place write and its reminder changes are committed as one
schema-versioned JSON document through the existing platform channel boundary.
Android stores the document in SharedPreferences with commit() and rejects
invalid or unsupported documents. This deliberately avoids introducing a new
SQLite/plugin dependency in the first Phase 1 migration while retaining a
checked, durable local store.

The document schema is:

- schemaVersion: 1
- places[]: stable id, name, latitude/longitude, enabled state, outer/inner/
  rearm radii, cooldown/approach timeout seconds, and accepted accuracy
- reminders[]: stable id, placeId, and text

Detection runtime snapshots remain separate from place/reminder records. Place
detection ownership remains place-level as defined above; APP-08 does not enable
multi-geofence registration or event routing.

On startup, PlaceMigration reads the legacy runtime snapshot, reminder text,
and Android desired registration only. If the new store is empty and a valid
legacy target exists, it commits one stable legacy-place-1 place and
legacy-reminder-1 in one write. It preserves monitoring intent and geofence
radius, does not use default coordinates when legacy target data is absent or
invalid, and does not call register/remove. Existing new data makes migration a
no-op, so reboot and repeated startup are idempotent. A failed commit leaves
legacy data untouched and the new store unchanged.

The single-target controller and Android desired-state store remain the active
compatibility boundary. APP-09 will decide how multiple enabled places are
registered and routed; APP-08 only prepares durable records.

### APP-08 legacy source-of-truth and failure policy

When both legacy sources exist, Android's desired-registration record is the
source of truth for the platform target and radius because it is the durable
monitoring intent. The Dart runtime snapshot is used for coordinates only when
Android has no desired record. If both records contain coordinates that differ
beyond a small floating-point tolerance, migration fails closed and leaves the
new store empty; it never combines coordinates from one source with a radius
from the other. `desiredMonitoring=false` is preserved as a disabled migrated
place.

Build 11 persisted only the target coordinates in the runtime snapshot and the
outer radius in Android desired state. The migration preserves every additional
setting when a legacy source provides it. For settings that Build 11 did not
persist, it uses the documented Phase 0 defaults (inner 80 m, rearm 350 m,
10-minute cooldown and approach timeout, accuracy 50 m); these are not
substitutions for a known stored value. Invalid or incomplete new documents,
duplicate IDs, invalid coordinates/radii/durations, and dangling reminder
references are rejected.

Migration runs inside the same serialized `PlaceDatabase` transaction as
repository writes. A failed source read or commit is reported through
`PlacePersistenceCoordinator.initializationFailure` and does not register or
remove a platform geofence.
## Phase 1 APP-09 multi-geofence

Enabled places are represented by stable Place IDs, which are the Android
Geofence request IDs. Reconciliation is serialized and idempotent: only enabled
places are submitted, disabled/deleted IDs are removed, and each callback is
checked against the current reconciliation generation. A partial add failure is
reported as partial, not as full registration success.

Android Geofencing APIs and OEM implementations impose platform limits on the
number of simultaneous geofences (the exact limit is device/service dependent).
APP-09 reports rejected registrations and retains the durable place records; it
does not silently delete or disable places. The legacy single-target request is
kept until replacement requests are accepted, preserving Build 11/12 migration
compatibility during transition.

Detection ownership remains per Place. Each place has its own SmartArrival
engine, cooldown/rearm state and place-level notification visit ID. Multiple
reminders for one place are presented as one place-level arrival notification
using the place's stable notification identity; reminder text is combined by the
notification adapter according to its explicit presentation policy. Events with
an unknown or stale Place ID are diagnostic-only and cannot change another
place's state. No permanent background GPS is introduced.
