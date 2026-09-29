# PingPlace UX Flow

## Principle
Think -> Tell PingPlace -> Confirm -> Forget.

## First launch
Explain why location is required before requesting it. Ask only for the minimum permission initially and request background access contextually.

## Home
Show places with active reminder counts and top reminders. Primary action is +.

## Creation
User types or dictates a natural sentence, for example:
“כשאני מגיע לברקו תזכיר לי לקנות סכינים לחריצת לחם.”

Confirmation shows:
- action/reminder
- place
- trigger
Each field can be corrected before saving.

Never silently choose an ambiguous place.

## Place screen
Show the human-facing active reminder list. Do not expose radii, coordinates, cooldowns, or runtime state in normal product UI.

## Arrival UX
Outer geofence entry is silent. Confirmed arrival produces one notification for the place. Actions may include Done, Next Visit, and View List.

## Reminder states exposed to users
ACTIVE, COMPLETED, PAUSED.
Runtime detection states remain internal.

## Navigation
Keep navigation minimal: REMINDERS / PLACES, central +, settings in header.

## LEAVE
Departure is a separate detection problem. Do not reuse ARRIVE behavior blindly. MVP departure behavior must be field-tested independently.
