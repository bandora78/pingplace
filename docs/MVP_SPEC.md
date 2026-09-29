# PingPlace MVP Specification

## Goal
A user can quickly create a location reminder, close the app, and reliably receive it when the location condition becomes relevant.

## V1 scope
- Flutter Android app with iOS-ready architecture
- Text and voice reminder creation
- Saved places, place search, current location
- ARRIVE and LEAVE reminders
- Location-based reminder lists
- Local notifications
- Complete reminder / remind next visit
- Local persistence
- No account required

## Excluded from V1
Accounts, cloud sync, family sharing, location sharing/history, tracking other people, web dashboard, calendar, smartwatch, automatically generated reminders, advanced recurrence.

## Smart Arrival
Entering a geofence is not equivalent to arriving at a place.

Initial experimental geometry:
- outer/wake radius: 300 m
- inner/arrival radius: 80 m
- rearm radius: 350 m
- cooldown: 10 minutes

State concept:
ARMED -> APPROACHING -> ARRIVED -> COOLDOWN -> WAITING_FOR_EXIT -> ARMED.

The outer boundary wakes temporary verification. A notification is produced only after practical arrival is confirmed.

## Notification behavior
Multiple active reminders at one place should produce one place-level notification. Partial completion keeps unfinished reminders active.

## Privacy and battery
No continuous location history. Core triggering should work locally after coordinates are known. Use OS geofencing while armed and temporary precise-location verification while approaching.
