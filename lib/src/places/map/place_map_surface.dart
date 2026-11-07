import 'package:flutter/widgets.dart';

import '../coordinates.dart';

/// What the map picker asks a map to show. Everything the picker decides
/// (selection, radii, failure handling) lives in the picker; a surface only
/// draws this and reports taps and tile failures.
final class PlaceMapView {
  const PlaceMapView({
    required this.center,
    required this.zoom,
    required this.selected,
    required this.original,
    required this.radii,
    required this.onTap,
    required this.onTileError,
  });

  /// Initial camera position. Read once when the surface is created; the
  /// camera is never written anywhere.
  final GeoPoint center;
  final double zoom;

  /// The marker being chosen, or null before the first tap on a new place.
  final GeoPoint? selected;

  /// The saved location of an existing place, shown for reference.
  final GeoPoint? original;

  /// Circles drawn around [selected].
  final PreviewRadii radii;

  /// A tap at a valid position. Taps outside the valid range are dropped.
  final ValueChanged<GeoPoint> onTap;

  /// A map tile failed to load (offline, provider error, blocked).
  final VoidCallback onTileError;
}

/// Narrow boundary between the picker and a map implementation, so widget
/// tests run with a fake surface and no network or tiles.
abstract interface class PlaceMapSurface {
  Widget build(BuildContext context, PlaceMapView view);
}
