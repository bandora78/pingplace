import 'dart:async';

import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

import 'multi_place_background_arrival_session.dart';

const _controlChannel = MethodChannel('pingplace/background/control');

@pragma('vm:entry-point')
Future<void> runBackgroundArrival() async {
  // The headless engine started by PreciseLocationService never calls
  // runApp(). Without these, the first channel call below throws, 'ready' is
  // never sent and every queued ENTER, fix and EXIT is silently lost; that
  // is what happened in Builds 13-17 (APP-10B).
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final session = MultiPlaceBackgroundArrivalSession(
    onDiagnostic: (message) =>
        unawaited(_controlChannel.invokeMethod<void>('diagnostic', message)),
    onCommand: (command) {
      // Place-scoped commands are 'name:placeId'.
      final separator = command.indexOf(':');
      return separator < 0
          ? _controlChannel.invokeMethod<void>(command)
          : _controlChannel.invokeMethod<void>(
              command.substring(0, separator),
              command.substring(separator + 1),
            );
    },
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
