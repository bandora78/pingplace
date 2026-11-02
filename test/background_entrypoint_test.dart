import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/background/background_arrival.dart';

// APP-10B root cause. PreciseLocationService starts a headless Flutter engine
// whose entrypoint never calls runApp(), so no binding exists. This file
// deliberately never initializes a test binding, matching that engine.
//
// Build 17: the first channel call threw ("Binding has not yet been
// initialized"), the engine never sent 'ready', and every ENTER, location fix
// and EXIT stayed queued in the native service. No place was ever evaluated,
// no notification was possible, and no Dart diagnostic could be written.

void main() {
  test(
    'the headless entrypoint initializes Flutter before using channels',
    () async {
      Object? error;
      try {
        await runBackgroundArrival();
      } catch (caught) {
        error = caught;
      }
      // With bindings initialized, the entrypoint reaches the 'ready'
      // handshake. The test host has no native side, so that call reports a
      // missing plugin instead of failing before any channel can be used.
      expect(error, isA<MissingPluginException>());
    },
  );
}
