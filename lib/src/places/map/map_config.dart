import '../coordinates.dart';

/// Map tile and viewport configuration for the place picker (APP-11).
///
/// Every value can be overridden at build time with `--dart-define`, so a
/// different tile provider can be used without a code change. No key or
/// secret is stored in the repository; a provider that needs a key must
/// supply it through [tileUrlTemplate] at build time, and that key is then
/// visible in the APK (restrict it to the app on the provider side).
final class MapConfig {
  const MapConfig({
    required this.tileUrlTemplate,
    required this.attribution,
    required this.userAgentPackageName,
    required this.defaultCenter,
    required this.defaultZoom,
    required this.placeZoom,
    required this.minZoom,
    required this.maxZoom,
    required this.maxCacheBytes,
  });

  /// Defaults: OpenStreetMap's public tile server, which is suitable for this
  /// field-test build only. Its tile usage policy requires a valid
  /// identifying User-Agent, visible attribution, no bulk or offline
  /// prefetching and honouring cache headers; it offers no availability
  /// guarantee and may block heavy use. A production release needs a tile
  /// provider with production terms (configured via PINGPLACE_MAP_TILE_URL).
  static final current = MapConfig(
    tileUrlTemplate: const String.fromEnvironment(
      'PINGPLACE_MAP_TILE_URL',
      defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    ),
    attribution: const String.fromEnvironment(
      'PINGPLACE_MAP_ATTRIBUTION',
      defaultValue: '© OpenStreetMap contributors',
    ),
    userAgentPackageName: 'com.example.pingplace',
    defaultCenter:
        GeoPoint.tryCreate(
          _number(const String.fromEnvironment('PINGPLACE_MAP_DEFAULT_LAT')),
          _number(const String.fromEnvironment('PINGPLACE_MAP_DEFAULT_LNG')),
        ) ??
        _fallbackCenter,
    defaultZoom: _zoom(
      const String.fromEnvironment('PINGPLACE_MAP_DEFAULT_ZOOM'),
    ),
    placeZoom: 16,
    minZoom: 3,
    maxZoom: 19,
    maxCacheBytes: 50 * 1000 * 1000,
  );

  /// `{z}/{x}/{y}` URL template of the raster tile provider.
  final String tileUrlTemplate;

  /// Attribution shown on the map, required by the tile provider.
  final String attribution;

  /// Sent as `User-Agent: flutter_map (<package>)` to identify the app.
  final String userAgentPackageName;

  /// Where the map opens for a new place with no coordinates yet.
  final GeoPoint defaultCenter;
  final double defaultZoom;

  /// Zoom used when the map opens on a place (a 300 m circle fills the view).
  final double placeZoom;
  final double minZoom;
  final double maxZoom;

  /// On-device tile cache bound; tiles expire according to HTTP headers.
  final int maxCacheBytes;
}

/// Central Israel, wide enough to pan to any field-test location.
final _fallbackCenter = GeoPoint.tryCreate(31.5, 34.9)!;

/// A `--dart-define` number, or NaN when absent or malformed (NaN makes
/// [GeoPoint.tryCreate] fall back to the default centre).
double _number(String raw) => parseCoordinate(raw) ?? double.nan;

/// A `--dart-define` zoom between 3 and 19, otherwise 7 (all of Israel).
double _zoom(String raw) {
  final value = parseCoordinate(raw);
  return value != null && value >= 3 && value <= 19 ? value : 7;
}
