# Phase 1 preparation proposal

APP-07 deliberately keeps the Phase 0 single-target behavior. The following
boundary is the proposed Phase 1 design; it is documentation only.

- Stable Place IDs identify persisted places independently of reminder text.
- A PlaceRepository owns place coordinates and geofence configuration.
- A ReminderRepository owns reminder content and scheduling metadata.
- Each place has an independent detection state, cooldown, and rearm context.
- Geofence registration uses one platform registration per place and routes
  events by stable Place ID rather than by screen state.
- Existing single-place persistence migrates into one generated stable Place ID.
- Migration is idempotent, preserves the existing target and reminder, and does
  not activate additional places.
- The production UI will manage places and reminders through repositories; the
  Developer Mode will continue to expose diagnostics without owning monitoring.

This proposal does not implement multiple places, multi-geofence registration,
event routing, or migration. Those changes require a separate APP-08 task and
new persistence and Android boundary tests.
