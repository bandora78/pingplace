import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/domain/smart_arrival_detection.dart';
import 'package:pingplace/src/geofence/multi_place_detection.dart';
import 'package:pingplace/src/persistence/place.dart';

void main() {
  test('routes events and notifications independently by place id', () async {
    final notifications = <String>[];
    final places = [
      const Place(id: 'a', name: 'A', latitude: 32, longitude: 34.8, enabled: true),
      const Place(id: 'b', name: 'B', latitude: 31, longitude: 35, enabled: true),
    ];
    final coordinator = MultiPlaceDetectionCoordinator(
      places: places,
      reminders: const [
        Reminder(id: 'ra', placeId: 'a', text: 'A reminder'),
        Reminder(id: 'rb', placeId: 'b', text: 'B reminder'),
      ],
      notify: (place, reminderText) async =>
          notifications.add('${place.id}:$reminderText'),
    );

    for (final id in ['a', 'b']) {
      await coordinator.handle(id, const Arm());
      await coordinator.handle(id, OuterEnter(at: DateTime(2026)));
    }
    await coordinator.handle(
      'a',
      LocationReceived(
        LocationSample(
          latitude: 32,
          longitude: 34.8,
          accuracy: 5,
          timestamp: DateTime(2026),
        ),
      ),
    );

    expect(coordinator.stateFor('a'), DetectionState.cooldown);
    expect(coordinator.stateFor('b'), DetectionState.approaching);
    expect(notifications, ['a:A reminder']);
  });

  test('duplicate callbacks do not duplicate a place visit notification', () async {
    var count = 0;
    final coordinator = MultiPlaceDetectionCoordinator(
      places: const [
        Place(id: 'a', name: 'A', latitude: 32, longitude: 34.8, enabled: true),
      ],
      reminders: const [Reminder(id: 'r', placeId: 'a', text: 'r')],
      notify: (_, _) async => count++,
    );
    await coordinator.handle('a', const Arm());
    await coordinator.handle('a', OuterEnter(at: DateTime(2026)));
    final sample = LocationReceived(
      LocationSample(
        latitude: 32,
        longitude: 34.8,
        accuracy: 5,
        timestamp: DateTime(2026),
      ),
    );
    await coordinator.handle('a', sample);
    await coordinator.handle('a', sample);
    expect(count, 1);
  });

  test('multiple reminders become one deterministic place notification', () async {
    String? text;
    final coordinator = MultiPlaceDetectionCoordinator(
      places: const [
        Place(id: 'a', name: 'A', latitude: 32, longitude: 34.8, enabled: true),
      ],
      reminders: const [
        Reminder(id: 'r1', placeId: 'a', text: 'first'),
        Reminder(id: 'r2', placeId: 'a', text: 'second'),
      ],
      notify: (_, reminderText) async => text = reminderText,
    );
    await coordinator.handle('a', const Arm());
    await coordinator.handle('a', OuterEnter(at: DateTime(2026)));
    await coordinator.handle(
      'a',
      LocationReceived(
        LocationSample(
          latitude: 32, longitude: 34.8, accuracy: 5, timestamp: DateTime(2026),
        ),
      ),
    );
    expect(text, 'first • second');
  });

}
