import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/geofence/geofence_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native registration receives the complete target and reminder',
    () async {
      const channel = MethodChannel('test/desired-registration');
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            received = call;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final service = MethodChannelGeofenceService(methodChannel: channel);
      await service.register(
        latitude: 31.664913,
        longitude: 34.8,
        radius: 300,
        reminderText: '  תזכורת שמורה  ',
      );

      expect(received?.method, 'register');
      expect(received?.arguments, {
        'latitude': 31.664913,
        'longitude': 34.8,
        'radius': 300.0,
        'reminderText': '  תזכורת שמורה  ',
      });
    },
  );
  test('native multi-place registration preserves stable place ids', () async {
    const channel = MethodChannel('test/multi-registration');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final service = MethodChannelGeofenceService(methodChannel: channel);
    await service.registerPlaces(const [
      GeofencePlaceRegistration(
        placeId: 'home', latitude: 31.6, longitude: 34.8, radius: 300,
      ),
      GeofencePlaceRegistration(
        placeId: 'work', latitude: 31.7, longitude: 34.9, radius: 280,
      ),
    ]);

    expect(received?.method, 'registerPlaces');
    expect(received?.arguments['places'], [
      {'placeId': 'home', 'latitude': 31.6, 'longitude': 34.8, 'radius': 300.0},
      {'placeId': 'work', 'latitude': 31.7, 'longitude': 34.9, 'radius': 280.0},
    ]);
  });

}
