import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/background/multi_place_background_arrival_session.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/runtime/arrival_runtime_store.dart';

import 'support/place_fakes.dart';

// Event-to-place routing for APP-10 places, using the production headless
// router with per-place runtime and notification namespaces.

final _at = DateTime.utc(2026, 11, 1, 12);

Future<void> _arrive(
  MultiPlaceBackgroundArrivalSession session,
  String placeId,
  double latitude,
  double longitude,
  String reminder,
  DateTime at,
) async {
  await session.handleEvent({
    'type': 'enter',
    'placeId': placeId,
    'targetLatitude': latitude,
    'targetLongitude': longitude,
    'reminderText': reminder,
    'cooldownSeconds': 600,
    'timestamp': at.toIso8601String(),
  });
  // An accurate sample about 70 m from the target: inside the inner radius.
  await session.handleEvent({
    'type': 'location',
    'placeId': placeId,
    'latitude': latitude + 0.00063,
    'longitude': longitude,
    'accuracy': 10.0,
    'timestamp': at.add(const Duration(minutes: 1)).toIso8601String(),
  });
}

MultiPlaceBackgroundArrivalSession _session(
  InMemoryArrivalRuntimeStore runtime,
  InMemoryNotificationService notifications,
  DateTime Function() clock,
) => MultiPlaceBackgroundArrivalSession(
  onDiagnostic: (_) {},
  onCommand: (_) async {},
  runtimeStore: runtime,
  notificationService: notifications,
  clock: clock,
);

void main() {
  test(
    'each place notifies once per visit and cooldowns are per place',
    () async {
      final runtime = InMemoryArrivalRuntimeStore();
      final notifications = InMemoryNotificationService();
      var now = _at;
      final session = _session(runtime, notifications, () => now);

      await _arrive(session, 'place-1', 32.0, 34.8, 'Home', _at);
      expect(notifications.deliveredVisitIds, hasLength(1));
      expect(notifications.deliveredVisitIds.single, startsWith('place-1:'));

      // A second ENTER for the same place within its 10-minute cooldown, as
      // after a duplicate platform callback: no second notification.
      now = _at.add(const Duration(minutes: 3));
      await _arrive(session, 'place-1', 32.0, 34.8, 'Home', now);
      expect(notifications.deliveredVisitIds, hasLength(1));

      // Another place is not blocked by place-1's cooldown.
      await _arrive(session, 'place-2', 32.01, 34.8, 'Office', now);
      expect(notifications.deliveredVisitIds, hasLength(2));
      expect(notifications.deliveredVisitIds.last, startsWith('place-2:'));
      expect(runtime.placeSnapshots['place-1']?.state, DetectionState.cooldown);
      expect(runtime.placeSnapshots['place-2']?.state, DetectionState.cooldown);
      session.dispose();
    },
  );

  test(
    'a new background process resumes each place cooldown from storage',
    () async {
      final runtime = InMemoryArrivalRuntimeStore();
      final notifications = InMemoryNotificationService();
      final first = _session(runtime, notifications, () => _at);
      await _arrive(first, 'place-1', 32.0, 34.8, 'Home', _at);
      first.dispose();

      final later = _at.add(const Duration(minutes: 5));
      final restarted = _session(runtime, notifications, () => later);
      await _arrive(restarted, 'place-1', 32.0, 34.8, 'Home', later);

      expect(notifications.deliveredVisitIds, hasLength(1));
      restarted.dispose();
    },
  );

  test('after a location edit resets runtime, detection uses the new target', () async {
    final rig = PlaceTestRig();
    final manager = rig.manager();
    await manager.initialize();
    await manager.add(draft(name: 'Home', latitude: 32.0, longitude: 34.8));

    final notifications = InMemoryNotificationService();
    final first = _session(rig.runtime, notifications, () => _at);
    await _arrive(first, 'place-1', 32.0, 34.8, 'Home', _at);
    first.dispose();
    expect(rig.runtime.placeSnapshots['place-1']?.target?.latitude, 32.0);

    // The user moves the place 5 km north.
    await manager.update(
      'place-1',
      draft(name: 'Home', latitude: 32.045, longitude: 34.8),
    );
    expect(rig.runtime.placeSnapshots.containsKey('place-1'), isFalse);
    final moved = rig.registrar.calls.last.single;
    expect(moved.latitude, 32.045);

    final later = _at.add(const Duration(minutes: 2));
    final restarted = _session(rig.runtime, notifications, () => later);
    await _arrive(
      restarted,
      'place-1',
      moved.latitude,
      moved.longitude,
      'Home',
      later,
    );

    // A new visit at the new location notifies, inside the old cooldown window.
    expect(notifications.deliveredVisitIds, hasLength(2));
    expect(rig.runtime.placeSnapshots['place-1']?.target?.latitude, 32.045);
    restarted.dispose();
  });
}
