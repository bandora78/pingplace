import 'dart:async';

import 'package:flutter/services.dart';

import 'background_arrival_session.dart';

const _controlChannel = MethodChannel('pingplace/background/control');

@pragma('vm:entry-point')
Future<void> runBackgroundArrival() async {
  final session = BackgroundArrivalSession(
    onDiagnostic: (message) =>
        unawaited(_controlChannel.invokeMethod<void>('diagnostic', message)),
    onCommand: (command) => _controlChannel.invokeMethod<void>(command),
  );
  _controlChannel.setMethodCallHandler((call) async {
    if (call.method == 'event') {
      await session.handleEvent(
        Map<Object?, Object?>.from(call.arguments as Map),
      );
    }
    return null;
  });

  await _controlChannel.invokeMethod<void>('ready');
}
