import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'coordinates.dart';
import 'map/place_map_surface.dart';

/// Lets the user choose a position on a map (APP-11).
///
/// Pops with the confirmed [GeoPoint], or null on cancel or back. It never
/// saves, registers or changes a place: the editor's Save button remains the
/// only way a location change is committed.
final class MapLocationPickerScreen extends StatefulWidget {
  const MapLocationPickerScreen({
    required this.surface,
    required this.radii,
    required this.defaultCenter,
    required this.defaultZoom,
    required this.placeZoom,
    this.initial,
    this.original,
    super.key,
  });

  final PlaceMapSurface surface;
  final PreviewRadii radii;

  /// Selection the picker starts with (the editor's current coordinates).
  final GeoPoint? initial;

  /// Saved location of the place being edited, shown as a reference marker.
  final GeoPoint? original;

  /// Viewport used when there is neither [initial] nor [original].
  final GeoPoint defaultCenter;
  final double defaultZoom;

  /// Zoom used when opening on a place.
  final double placeZoom;

  @override
  State<MapLocationPickerScreen> createState() =>
      _MapLocationPickerScreenState();
}

final class _MapLocationPickerScreenState
    extends State<MapLocationPickerScreen> {
  GeoPoint? selected;
  bool tilesFailed = false;

  @override
  void initState() {
    super.initState();
    selected = widget.initial ?? widget.original;
  }

  void _select(GeoPoint point) {
    if (!mounted) return;
    setState(() => selected = point);
  }

  void _tileError() {
    if (!mounted || tilesFailed) return;
    void mark() {
      if (mounted && !tilesFailed) setState(() => tilesFailed = true);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => mark());
    } else {
      mark();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final start = widget.initial ?? widget.original;
    final point = selected;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('בחירת מיקום במפה')),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: widget.surface.build(
                      context,
                      PlaceMapView(
                        center: start ?? widget.defaultCenter,
                        zoom: start == null
                            ? widget.defaultZoom
                            : widget.placeZoom,
                        selected: point,
                        original: widget.original,
                        radii: widget.radii,
                        onTap: _select,
                        onTileError: _tileError,
                      ),
                    ),
                  ),
                  if (tilesFailed)
                    Positioned(
                      top: 8,
                      left: 8,
                      right: 8,
                      child: Material(
                        key: const Key('map-tiles-failed'),
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'לא ניתן לטעון את המפה (אין חיבור לאינטרנט או '
                            'שגיאה אצל ספק המפה). אפשר לחזור ולהזין קו רוחב '
                            'וקו אורך ידנית בעורך.',
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _legend(
                      key: const Key('map-legend-outer'),
                      color: Colors.blue.shade700,
                      text:
                          'כחול: אזור הגישה (${_meters(widget.radii.outer)}) — '
                          'תצוגה גאומטרית בלבד, לא זמן ההתראה',
                    ),
                    _legend(
                      key: const Key('map-legend-inner'),
                      color: Colors.green.shade800,
                      text:
                          'ירוק: סף ההגעה (${_meters(widget.radii.inner)}) — '
                          'ההתראה רק לאחר אימות הגעה לתוכו',
                    ),
                    if (widget.original != null)
                      _legend(
                        color: theme.disabledColor,
                        text: 'סמן אפור: המיקום השמור',
                      ),
                    const SizedBox(height: 8),
                    if (point == null)
                      const Text(
                        'הקישו על המפה כדי לבחור מיקום. אפשר להגדיל ולהזיז '
                        'את המפה לפני הבחירה.',
                        key: Key('map-no-selection'),
                      )
                    else ...[
                      _coordinate(
                        'קו רוחב (Latitude)',
                        point.latitude,
                        const Key('map-selected-latitude'),
                      ),
                      _coordinate(
                        'קו אורך (Longitude)',
                        point.longitude,
                        const Key('map-selected-longitude'),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: const Key('map-cancel'),
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('ביטול'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            key: const Key('map-confirm'),
                            onPressed: point == null
                                ? null
                                : () => Navigator.of(context).pop(point),
                            child: const Text('אישור מיקום'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend({Key? key, required Color color, required String text}) =>
      Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(Icons.circle, size: 12, color: color),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      );

  Widget _coordinate(String label, double value, Key key) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text('$label: '),
      Text(
        displayCoordinate(value),
        key: key,
        textDirection: TextDirection.ltr,
        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      ),
    ],
  );
}

String _meters(double value) => '${value.round()} מ׳';
