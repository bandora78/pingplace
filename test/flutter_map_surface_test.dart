import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/places/coordinates.dart';
import 'package:pingplace/src/places/map/flutter_map_surface.dart';
import 'package:pingplace/src/places/map/map_config.dart';
import 'package:pingplace/src/places/map/place_map_surface.dart';

/// Tiles that never load, as when the phone is offline. No network access.
final class _UnreachableTiles extends TileProvider {
  int requests = 0;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    requests++;
    return MemoryImage(Uint8List(0)); // undecodable: fails like a lost tile
  }
}

void main() {
  final saved = GeoPoint.tryCreate(31.7401, 34.7712)!;

  Future<({List<GeoPoint> taps, List<int> errors, _UnreachableTiles tiles})>
  pump(WidgetTester tester, {GeoPoint? selected, GeoPoint? original}) async {
    final taps = <GeoPoint>[];
    final errors = <int>[];
    final tiles = _UnreachableTiles();
    final surface = FlutterMapSurface(
      config: MapConfig.current,
      tileProvider: tiles,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => surface.build(
              context,
              PlaceMapView(
                center: saved,
                zoom: 16,
                selected: selected,
                original: original,
                radii: const PreviewRadii(outer: 450, inner: 80),
                onTap: taps.add,
                onTileError: () => errors.add(1),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (taps: taps, errors: errors, tiles: tiles);
  }

  testWidgets('draws the outer and the 80 m circles in metres', (tester) async {
    await pump(tester, selected: saved, original: saved);
    final circles = tester
        .widget<CircleLayer>(find.byKey(const Key('map-radius-circles')))
        .circles;
    expect(circles.map((c) => c.radius), [450, 80]);
    expect(circles.every((c) => c.useRadiusInMeter), isTrue);
    expect(
      circles.every(
        (c) =>
            c.point.latitude == saved.latitude &&
            c.point.longitude == saved.longitude,
      ),
      isTrue,
    );
    expect(find.byKey(const Key('map-selected-marker')), findsOneWidget);
    // The saved location coincides with the selection: one marker only.
    expect(find.byKey(const Key('map-original-marker')), findsNothing);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
  });

  testWidgets('shows the saved location separately after a move', (
    tester,
  ) async {
    await pump(
      tester,
      selected: GeoPoint.tryCreate(31.7405, 34.7716), // ~60 m away
      original: saved,
    );
    expect(find.byKey(const Key('map-original-marker')), findsOneWidget);
    expect(find.byKey(const Key('map-selected-marker')), findsOneWidget);
  });

  testWidgets('no circles before a location is chosen', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('map-radius-circles')), findsNothing);
    expect(find.byKey(const Key('map-selected-marker')), findsNothing);
  });

  testWidgets('a tap reports the tapped position', (tester) async {
    final result = await pump(tester, selected: saved);
    await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
    // A single tap is reported once the double-tap (zoom) window passes.
    await tester.pump(const Duration(milliseconds: 500));
    expect(result.taps, hasLength(1));
    // The centre of the view is the camera centre.
    expect(result.taps.single.latitude, closeTo(saved.latitude, 1e-6));
    expect(result.taps.single.longitude, closeTo(saved.longitude, 1e-6));
  });

  testWidgets('failing tiles are reported to the picker', (tester) async {
    final result = await pump(tester, selected: saved);
    expect(result.tiles.requests, greaterThan(0));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(result.errors, isNotEmpty);
  });
}
