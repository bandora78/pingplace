import 'package:flutter/material.dart';
import 'package:pingplace/src/places/coordinates.dart';
import 'package:pingplace/src/places/map/place_map_surface.dart';

/// Map surface for widget tests: no tiles, no network. Records what the
/// picker asked it to show and lets a test tap a position or fail tiles.
final class FakeMapSurface implements PlaceMapSurface {
  final List<PlaceMapView> views = [];

  PlaceMapView get view => views.last;

  /// Simulates a tap on the map at [latitude], [longitude].
  void tap(double latitude, double longitude) =>
      view.onTap(GeoPoint.tryCreate(latitude, longitude)!);

  /// Simulates map tiles failing to load (offline or provider error).
  void failTiles() => view.onTileError();

  @override
  Widget build(BuildContext context, PlaceMapView view) {
    views.add(view);
    return ColoredBox(
      key: const Key('fake-map'),
      color: Colors.grey.shade300,
      child: const SizedBox.expand(),
    );
  }
}

GeoPoint point(double latitude, double longitude) =>
    GeoPoint.tryCreate(latitude, longitude)!;
