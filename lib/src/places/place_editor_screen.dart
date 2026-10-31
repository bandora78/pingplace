import 'package:flutter/material.dart';

import 'place_manager.dart';

/// Add or edit one place. Returns true from the route when the place was
/// saved (and registered with Android when enabled).
final class PlaceEditorScreen extends StatefulWidget {
  const PlaceEditorScreen({required this.manager, this.existing, super.key});

  final PlaceManager manager;
  final ManagedPlace? existing;

  @override
  State<PlaceEditorScreen> createState() => _PlaceEditorScreenState();
}

final class _PlaceEditorScreenState extends State<PlaceEditorScreen> {
  late final TextEditingController name;
  late final TextEditingController reminder;
  late final TextEditingController latitude;
  late final TextEditingController longitude;
  late final TextEditingController radius;
  late bool enabled;
  bool saving = false;
  String? error;

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
    enabled = place?.enabled ?? true;
  }

  @override
  void dispose() {
    name.dispose();
    reminder.dispose();
    latitude.dispose();
    longitude.dispose();
    radius.dispose();
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
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('place-latitude'),
                    controller: latitude,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'קו רוחב',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: const Key('place-longitude'),
                    controller: longitude,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'קו אורך',
                      border: OutlineInputBorder(),
                    ),
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
