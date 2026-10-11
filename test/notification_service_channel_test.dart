import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/notification/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('pingplace/notifications');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'notification permission request reaches the platform channel',
    () async {
      String? method;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            method = call.method;
            return null;
          });

      await MethodChannelNotificationService(channel: channel)
          .requestPermission();

      expect(method, 'requestPermission');
    },
  );

  test('notification settings action reaches the platform channel', () async {
    String? method;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          method = call.method;
          return null;
        });

    await MethodChannelNotificationService(channel: channel).openSettings();

    expect(method, 'openSettings');
  });
}
