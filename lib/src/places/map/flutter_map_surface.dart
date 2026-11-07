import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../coordinates.dart';
import 'map_config.dart';
import 'place_map_surface.dart';

/// Production map: flutter_map with raster tiles from [MapConfig].
///
/// Network use: tiles for the visible area only, while the picker is open.
/// No location request, no background download, no prefetching. Tiles are
/// cached on the device (bounded by [MapConfig.maxCacheBytes], expiring per
/// HTTP headers) as the tile usage policy asks.
final class FlutterMapSurface implements PlaceMapSurface {
  FlutterMapSurface({MapConfig? config, this.tileProvider})
    : config = config ?? MapConfig.current;

  final MapConfig config;

  /// Overrides the network tile provider (tests).
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context, PlaceMapView view) {
    final theme = Theme.of(context);
    final selected = view.selected;
    final original = view.original;
    return FlutterMap(
      options: MapOptions(
        initialCenter: _latLng(view.center),
        initialZoom: view.zoom,
        minZoom: config.minZoom,
        maxZoom: config.maxZoom,
        // Pan and pinch-zoom; no rotation, so north stays up.
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onTap: (_, point) {
          final tapped = GeoPoint.tryCreate(point.latitude, point.longitude);
          if (tapped != null) view.onTap(tapped);
        },
      ),
      children: [
        TileLayer(
          urlTemplate: config.tileUrlTemplate,
          userAgentPackageName: config.userAgentPackageName,
          maxNativeZoom: 19,
          tileProvider:
              tileProvider ??
              NetworkTileProvider(
                cachingProvider: BuiltInMapCachingProvider.getOrCreateInstance(
                  maxCacheSize: config.maxCacheBytes,
                ),
              ),
          errorTileCallback: (_, _, _) => view.onTileError(),
        ),
        if (selected != null)
          CircleLayer(
            key: const Key('map-radius-circles'),
            circles: [
              CircleMarker(
                point: _latLng(selected),
                radius: view.radii.outer,
                useRadiusInMeter: true,
                color: Colors.blue.withValues(alpha: 0.12),
                borderColor: Colors.blue.shade700,
                borderStrokeWidth: 2,
              ),
              CircleMarker(
                point: _latLng(selected),
                radius: view.radii.inner,
                useRadiusInMeter: true,
                color: Colors.green.withValues(alpha: 0.25),
                borderColor: Colors.green.shade800,
                borderStrokeWidth: 2,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            if (original != null && original != selected)
              Marker(
                key: const Key('map-original-marker'),
                point: _latLng(original),
                width: 36,
                height: 36,
                alignment: Alignment.topCenter,
                child: Icon(
                  Icons.location_on,
                  size: 36,
                  color: theme.disabledColor,
                ),
              ),
            if (selected != null)
              Marker(
                key: const Key('map-selected-marker'),
                point: _latLng(selected),
                width: 44,
                height: 44,
                alignment: Alignment.topCenter,
                child: Icon(
                  Icons.location_on,
                  size: 44,
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
        SimpleAttributionWidget(source: Text(config.attribution)),
      ],
    );
  }
}

LatLng _latLng(GeoPoint point) => LatLng(point.latitude, point.longitude);
