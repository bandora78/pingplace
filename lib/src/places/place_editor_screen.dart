import 'package:flutter/material.dart';

import 'coordinates.dart';
import 'map/flutter_map_surface.dart';
import 'map/map_config.dart';
import 'map/place_map_surface.dart';
import 'map_location_picker_screen.dart';
import 'place_manager.dart';

/// Add or edit one place. Returns true from the route when the place was
/// saved (and registered with Android when enabled).
final class PlaceEditorScreen extends StatefulWidget {
  const PlaceEditorScreen({
    required this.manager,
    this.existing,
    this.mapSurface,
    this.mapConfig,
    super.key,
  });

  final PlaceManager manager;
  final ManagedPlace? existing;

  /// Map used by the location picker; defaults to [FlutterMapSurface].
  final PlaceMapSurface? mapSurface;
  final MapConfig? mapConfig;

  @override
  State<PlaceEditorScreen> createState() => _PlaceEditorScreenState();
}

final class _PlaceEditorScreenState extends State<PlaceEditorScreen> {
  late final TextEditingController name;
  late final TextEditingController reminder;
  late final TextEditingController latitude;
  late final TextEditingController longitude;
  late final TextEditingController radius;
  late final TextEditingController pasted;
  late bool enabled;
  bool saving = false;
  bool mapOpen = false;
  String? error;
  String? pasteError;

  bool get isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final place = widget.existing?.place;
    name = TextEditingController(text: place?.name ?? '');
    reminder = TextEditingController(text: widget.existing?.reminderText ?? '');
    latitude = TextEditingController(text: place?.latitude.toString() ?? '');
    longitude = TextEditingController(text: place?.longitude.toString() ?? '');
    radius = TextEditingController(
      text: (place?.outerRadius ?? 300).round().toString(),
    );
    pasted = TextEditingController();
    enabled = place?.enabled ?? true;
  }

  @override
  void dispose() {
    name.dispose();
    reminder.dispose();
    latitude.dispose();
    longitude.dispose();
    radius.dispose();
    pasted.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final parsedLatitude = double.tryParse(latitude.text.trim());
    final parsedLongitude = double.tryParse(longitude.text.trim());
    final parsedRadius = double.tryParse(radius.text.trim());
    if (parsedLatitude == null ||
        parsedLongitude == null ||
        parsedRadius == null) {
      setState(() => error = 'נא להזין קואורדינטות ורדיוס תקינים');
      return;
    }
    final draft = PlaceDraft(
      name: name.text,
      latitude: parsedLatitude,
      longitude: parsedLongitude,
      radius: parsedRadius,
      reminderText: reminder.text,
      enabled: enabled,
    );
    final invalid = draft.validate();
    if (invalid != null) {
      setState(() => error = placeErrorMessage(invalid));
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    final result = isEdit
        ? await widget.manager.update(widget.existing!.place.id, draft)
        : await widget.manager.add(draft);
    if (!mounted) return;
    if (result.succeeded) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      saving = false;
      error = placeOutcomeMessage(result);
    });
  }

  GeoPoint? get _saved {
    final place = widget.existing?.place;
    return place == null
        ? null
        : GeoPoint.tryCreate(place.latitude, place.longitude);
  }

  /// Writes a chosen position into the coordinate fields. Values equal to
  /// the fields' current values leave the typed text untouched, so an
  /// unchanged selection is a no-op for Save.
  void _applyPoint(GeoPoint point) {
    final currentLatitude = parseCoordinate(latitude.text);
    final currentLongitude = parseCoordinate(longitude.text);
    if (currentLatitude == point.latitude &&
        currentLongitude == point.longitude) {
      return;
    }
    latitude.text = editorText(point.latitude);
    longitude.text = editorText(point.longitude);
  }

  /// Opens the map picker. It only fills the editor's fields: nothing is
  /// saved or registered until the user presses Save.
  Future<void> _openMap() async {
    if (mapOpen || saving) return;
    final config = widget.mapConfig ?? MapConfig.current;
    final editorRadius = double.tryParse(radius.text.trim());
    final place = widget.existing?.place;
    final radii = previewRadii(
      editorRadius:
          editorRadius != null &&
              editorRadius >= PlaceDraft.minRadius &&
              editorRadius <= PlaceDraft.maxRadius
          ? editorRadius
          : null,
      savedOuterRadius: place?.outerRadius,
      savedInnerRadius: place?.innerRadius,
    );
    setState(() => mapOpen = true);
    GeoPoint? chosen;
    try {
      chosen = await Navigator.of(context).push<GeoPoint>(
        MaterialPageRoute(
          builder: (_) => MapLocationPickerScreen(
            surface: widget.mapSurface ?? FlutterMapSurface(config: config),
            radii: radii,
            initial: initialMapPoint(
              latitudeText: latitude.text,
              longitudeText: longitude.text,
              saved: _saved,
            ),
            original: _saved,
            defaultCenter: config.defaultCenter,
            defaultZoom: config.defaultZoom,
            placeZoom: config.placeZoom,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => mapOpen = false);
    }
    final point = chosen;
    if (!mounted || point == null) return;
    setState(() {
      _applyPoint(point);
      pasteError = null;
    });
  }

  void _applyPasted() {
    final result = parseCoordinatePair(pasted.text);
    setState(() {
      final point = result.point;
      if (point == null) {
        pasteError = pasteErrorMessage(result.error!);
        return;
      }
      _applyPoint(point);
      pasteError = null;
      pasted.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(isEdit ? 'עריכת מקום' : 'מקום חדש')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              key: const Key('place-name'),
              controller: name,
              decoration: const InputDecoration(
                labelText: 'שם המקום',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('place-reminder'),
              controller: reminder,
              decoration: const InputDecoration(
                labelText: 'תזכורת',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              // Latitude left, longitude right in every locale: the same
              // order as Google Maps' "lat, lng" text, never mirrored by RTL.
              textDirection: TextDirection.ltr,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('place-latitude'),
                    controller: latitude,
                    textDirection: TextDirection.ltr,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'קו רוחב (Latitude)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('place-longitude'),
                    controller: longitude,
                    textDirection: TextDirection.ltr,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'קו אורך (Longitude)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('place-open-map'),
              onPressed: saving || mapOpen ? null : _openMap,
              icon: const Icon(Icons.map_outlined),
              label: const Text('בחר מיקום במפה'),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('place-paste-coordinates'),
                    controller: pasted,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: 'הדבקת קואורדינטות',
                      helperText:
                          'קו רוחב, קו אורך\n'
                          'לדוגמה: ${ltr('31.732600, 34.757743')}',
                      helperMaxLines: 2,
                      errorText: pasteError,
                      errorMaxLines: 3,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: TextButton(
                    key: const Key('place-apply-pasted'),
                    onPressed: saving ? null : _applyPasted,
                    child: const Text('החלה'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('place-radius'),
              controller: radius,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'רדיוס התראה במטרים',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              key: const Key('place-enabled'),
              contentPadding: EdgeInsets.zero,
              title: const Text('מעקב פעיל'),
              value: enabled,
              onChanged: saving
                  ? null
                  : (value) => setState(() => enabled = value),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                key: const Key('place-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('place-save'),
              onPressed: saving ? null : _save,
              child: Text(saving ? 'שומר…' : 'שמירה'),
            ),
          ],
        ),
      ),
    );
  }
}

String placeErrorMessage(String code) => switch (code) {
  'PLACE_NAME_REQUIRED' => 'נא להזין שם למקום',
  'REMINDER_TEXT_REQUIRED' => 'נא להזין טקסט לתזכורת',
  'LATITUDE_OUT_OF_RANGE' => 'קו רוחב חייב להיות בין ‎-90 ל-90',
  'LONGITUDE_OUT_OF_RANGE' => 'קו אורך חייב להיות בין ‎-180 ל-180',
  'RADIUS_OUT_OF_RANGE' =>
    'רדיוס חייב להיות בין ${PlaceDraft.minRadius.round()} ל-${PlaceDraft.maxRadius.round()} מטרים',
  _ => code,
};

String pasteErrorMessage(CoordinatePasteError error) => switch (error) {
  CoordinatePasteError.empty => 'נא להדביק קו רוחב וקו אורך',
  CoordinatePasteError.unsupportedLink =>
    'קישורים אינם נתמכים. בגוגל מפות לחצו על הנקודה והעתיקו את המספרים '
        '(קו רוחב, קו אורך).',
  CoordinatePasteError.malformed =>
    'יש להדביק שני מספרים עשרוניים מופרדים בפסיק: קו רוחב, קו אורך',
  CoordinatePasteError.latitudeOutOfRange =>
    'המספר הראשון הוא קו הרוחב וחייב להיות בין ‎-90 ל-90',
  CoordinatePasteError.longitudeOutOfRange =>
    'המספר השני הוא קו האורך וחייב להיות בין ‎-180 ל-180',
};

String placeOutcomeMessage(PlaceOperationResult result) =>
    switch (result.outcome) {
      PlaceOperationOutcome.saved => 'נשמר',
      PlaceOperationOutcome.invalid => placeErrorMessage(result.detail ?? ''),
      PlaceOperationOutcome.notFound => 'המקום כבר לא קיים',
      PlaceOperationOutcome.persistFailed => 'השמירה נכשלה. לא בוצע שינוי.',
      PlaceOperationOutcome.rolledBack =>
        'Android דחה את רישום המקומות. השינוי בוטל והמקומות הקודמים שוחזרו. '
            'בדקו הרשאת מיקום ברקע ושירותי מיקום.',
      PlaceOperationOutcome.rollbackFailed =>
        'Android דחה את הרישום וגם השחזור לא אושר. יש לנסות שוב את הרישום.',
      PlaceOperationOutcome.registrationFailed =>
        'רישום המקומות ב-Android נכשל. בדקו הרשאות ונסו שוב.',
    };
