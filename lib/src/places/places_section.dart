import 'dart:async';

import 'package:flutter/material.dart';

import 'coordinates.dart';
import 'map/place_map_surface.dart';
import 'place_editor_screen.dart';
import 'place_manager.dart';

/// The user's saved places: list, add, edit, delete and per-place monitoring.
final class PlacesSection extends StatefulWidget {
  const PlacesSection({required this.manager, this.mapSurface, super.key});

  final PlaceManager manager;

  /// Map used by the editor's location picker; null uses the production map.
  final PlaceMapSurface? mapSurface;

  @override
  State<PlacesSection> createState() => _PlacesSectionState();
}

final class _PlacesSectionState extends State<PlacesSection> {
  PlaceManager get manager => widget.manager;

  @override
  void initState() {
    super.initState();
    manager.addListener(_refresh);
  }

  @override
  void dispose() {
    manager.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _openEditor([ManagedPlace? existing]) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PlaceEditorScreen(
          manager: manager,
          existing: existing,
          mapSurface: widget.mapSurface,
        ),
      ),
    );
  }

  Future<void> _toggle(ManagedPlace item, bool enabled) async {
    final result = await manager.setEnabled(item.place.id, enabled);
    _report(result);
  }

  Future<void> _confirmDelete(ManagedPlace item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('מחיקת מקום'),
          content: Text(
            'למחוק את "${item.place.name}"? התזכורת והמעקב למקום זה יוסרו. '
            'מקומות אחרים לא יושפעו.',
          ),
          actions: [
            TextButton(
              key: const Key('cancel-delete'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('ביטול'),
            ),
            FilledButton(
              key: const Key('confirm-delete'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('מחיקה'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    _report(await manager.delete(item.place.id));
  }

  void _report(PlaceOperationResult result) {
    if (!mounted || result.succeeded) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(placeOutcomeMessage(result))));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('המקומות שלי', style: theme.textTheme.titleLarge),
                ),
                FilledButton.icon(
                  key: const Key('add-place'),
                  onPressed: manager.loaded ? () => _openEditor() : null,
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: const Text('הוספת מקום'),
                ),
              ],
            ),
            if (manager.loadFailure != null) ...[
              const SizedBox(height: 8),
              Text(
                'טעינת המקומות נכשלה: ${manager.loadFailure}',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            if (manager.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                manager.lastError!,
                key: const Key('places-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: const Key('retry-registration'),
                  onPressed: manager.busy
                      ? null
                      : () => unawaited(
                          manager.retryRegistration().then(_report),
                        ),
                  child: const Text('ניסיון רישום חוזר'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (!manager.loaded)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (manager.places.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'עדיין אין מקומות. הוסיפו מקום כדי לקבל תזכורת בהגעה.',
                ),
              )
            else
              for (final item in manager.places) _placeTile(context, item),
          ],
        ),
      ),
    );
  }

  Widget _placeTile(BuildContext context, ManagedPlace item) {
    final place = item.place;
    final theme = Theme.of(context);
    final (statusText, statusColor) = switch (item.registration) {
      PlaceRegistrationState.registered => (
        'פעיל · מאושר ע״י Android',
        Colors.green.shade700,
      ),
      PlaceRegistrationState.pending => (
        'ממתין לאישור Android',
        theme.colorScheme.tertiary,
      ),
      PlaceRegistrationState.disabled => ('מעקב כבוי', theme.disabledColor),
      PlaceRegistrationState.unknown => (
        'מצב הרישום לא ידוע',
        theme.colorScheme.error,
      ),
    };
    return Card(
      key: Key('place-tile-${place.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(place.name, style: theme.textTheme.titleMedium),
                ),
                Switch(
                  key: Key('place-switch-${place.id}'),
                  value: place.enabled,
                  onChanged: manager.busy
                      ? null
                      : (value) => unawaited(_toggle(item, value)),
                ),
              ],
            ),
            if (item.reminderText.isNotEmpty) Text(item.reminderText),
            Text(
              '${displayPair(place.latitude, place.longitude, decimals: 5)} · '
              'רדיוס ${place.outerRadius.round()} מ׳',
              style: theme.textTheme.bodySmall,
            ),
            Text(
              statusText,
              key: Key('place-status-${place.id}'),
              style: theme.textTheme.bodySmall?.copyWith(color: statusColor),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  key: Key('place-edit-${place.id}'),
                  onPressed: manager.busy ? null : () => _openEditor(item),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('עריכה'),
                ),
                TextButton.icon(
                  key: Key('place-delete-${place.id}'),
                  onPressed: manager.busy ? null : () => _confirmDelete(item),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('מחיקה'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
