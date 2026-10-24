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
}
