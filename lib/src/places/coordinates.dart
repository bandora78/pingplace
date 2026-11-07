/// Coordinate handling for the place editor and the map picker (APP-11).
///
/// Pure Dart: no Flutter or platform types, so every rule is unit tested.
/// Values are never rounded, snapped or swapped; anything ambiguous is
/// rejected instead of corrected.
library;

/// A validated WGS84 position: finite, latitude in [-90, 90], longitude in
/// [-180, 180]. Always latitude first.
final class GeoPoint {
  const GeoPoint._(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  /// Null when either value is NaN, infinite or out of range.
  static GeoPoint? tryCreate(double latitude, double longitude) {
    if (!isValidLatitude(latitude) || !isValidLongitude(longitude)) {
      return null;
    }
    return GeoPoint._(latitude, longitude);
  }

  @override
  bool operator ==(Object other) =>
      other is GeoPoint &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() => 'GeoPoint($latitude, $longitude)';
}

bool isValidLatitude(double value) =>
    value.isFinite && value >= -90 && value <= 90;

bool isValidLongitude(double value) =>
    value.isFinite && value >= -180 && value <= 180;

/// Bidi controls that copying from an RTL screen may add around numbers.
final _bidiControls = RegExp('[\u200E\u200F\u202A-\u202E\u2066-\u2069]');

/// A plain decimal number: optional sign, digits, optional fraction. No
/// exponent, hex, thousands separators or decimal comma.
final _decimal = RegExp(r'^[+-]?(\d+(\.\d*)?|\.\d+)$');

/// Parses one decimal coordinate as typed or produced by [editorText].
/// Returns null for anything that is not a finite decimal number.
double? parseCoordinate(String input) {
  final text = input.replaceAll(_bidiControls, '').trim();
  if (text.isEmpty) return null;
  // Dart's shortest round-trip form of very small values uses an exponent
  // (1e-7); accept exactly that form so map values always round-trip.
  final value = _decimal.hasMatch(text) || _exponent.hasMatch(text)
      ? double.tryParse(text)
      : null;
  return value != null && value.isFinite ? value : null;
}

final _exponent = RegExp(r'^[+-]?\d+(\.\d+)?e[+-]?\d+$');

/// Text written into the editor's latitude/longitude field: the shortest
/// string that parses back to exactly [value], so no precision is lost.
String editorText(double value) => value.toString();

/// Wraps [text] in a left-to-right isolate so an RTL (Hebrew) layout cannot
/// reorder a sign, a decimal point or the two values of a pair.
String ltr(String text) => '\u2066$text\u2069';

/// Display form of one coordinate: six decimals (about 0.1 m), LTR.
/// Display only; stored and editor values keep full precision.
String displayCoordinate(double value) => ltr(value.toStringAsFixed(6));

/// Display form of a pair in Google Maps order, `lat, lng`, LTR-isolated.
String displayPair(double latitude, double longitude, {int decimals = 6}) =>
    ltr(
      '${latitude.toStringAsFixed(decimals)}, '
      '${longitude.toStringAsFixed(decimals)}',
    );

/// Radii drawn by the map picker. A geometric preview only: Android's
/// geofence ENTER timing is not guaranteed by the outer circle.
final class PreviewRadii {
  const PreviewRadii({required this.outer, required this.inner});

  /// The outer (wake) geofence radius in metres.
  final double outer;

  /// The arrival threshold in metres (80 m by default).
  final double inner;
}

/// Same defaults as [Place]: outer 300 m, inner 80 m.
const defaultOuterRadius = 300.0;
const defaultInnerRadius = 80.0;

/// The radii the place will have once saved with the editor's radius.
///
/// Mirrors PlaceManager's draft rule without changing it: the outer radius
/// is the editor's radius when it is a valid number, otherwise the saved
/// place's radius, otherwise 300 m; the inner radius is the saved place's
/// (80 m for new places), capped at the outer radius.
PreviewRadii previewRadii({
  double? editorRadius,
  double? savedOuterRadius,
  double? savedInnerRadius,
}) {
  final outer =
      editorRadius != null && editorRadius.isFinite && editorRadius > 0
      ? editorRadius
      : savedOuterRadius ?? defaultOuterRadius;
  final inner = savedInnerRadius ?? defaultInnerRadius;
  return PreviewRadii(outer: outer, inner: inner > outer ? outer : inner);
}

/// Where the map opens. Priority (APP-11 §4.6): the editor's current
/// coordinates when both are valid (for an existing place these start as
/// its saved coordinates), then the saved coordinates, then the default
/// viewport. Never the device's location.
GeoPoint? initialMapPoint({
  required String latitudeText,
  required String longitudeText,
  GeoPoint? saved,
}) {
  final latitude = parseCoordinate(latitudeText);
  final longitude = parseCoordinate(longitudeText);
  if (latitude != null && longitude != null) {
    final typed = GeoPoint.tryCreate(latitude, longitude);
    if (typed != null) return typed;
  }
  return saved;
}
