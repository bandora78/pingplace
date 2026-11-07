import 'dart:async';

import 'package:flutter/material.dart';

import 'map/place_map_surface.dart';
import 'place_card.dart';
import 'place_editor_screen.dart';
import 'place_manager.dart';

/// The user's saved places (APP-12): add action, errors with the existing
/// retry, and one [PlaceCard] per place. Not scrollable itself; the home
/// screen's single list scrolls it.
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

  /// Places whose toggle or delete started from this section is running.
  /// Presentation only; cleared in `finally`, so it cannot go stale.
  final Set<String> _inFlight = {};
  bool _editorOpen = false;

  bool get _interactive => !manager.busy && _inFlight.isEmpty;

  Future<void> _openEditor([ManagedPlace? existing]) async {
    if (_editorOpen) return;
    _editorOpen = true;
    try {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PlaceEditorScreen(
            manager: manager,
            existing: existing,
            mapSurface: widget.mapSurface,
          ),
        ),
      );
    } finally {
      _editorOpen = false;
    }
  }

  /// Runs one mutation for [placeId]. Refused while PlaceManager is busy or
  /// another card operation runs, so rapid repeated taps dispatch once.
  Future<void> _run(
    String placeId,
    Future<PlaceOperationResult> Function() operation,
  ) async {
    if (!_interactive) return;
    setState(() => _inFlight.add(placeId));
    PlaceOperationResult? result;
    try {
      result = await operation();
    } finally {
      if (mounted) {
        setState(() => _inFlight.remove(placeId));
      } else {
        _inFlight.remove(placeId);
      }
    }
    _report(result);
  }

  Future<void> _toggle(ManagedPlace item, bool enabled) =>
      _run(item.place.id, () => manager.setEnabled(item.place.id, enabled));

  Future<void> _confirmDelete(ManagedPlace item) async {
    if (!_interactive) return;
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
    if (confirmed != true || !mounted) return;
    // Another operation may have started while the dialog was open.
    if (!_interactive) {
      _showMessage('פעולה אחרת מתבצעת כעת. המקום לא נמחק, נסו שוב.');
      return;
    }
    await _run(item.place.id, () => manager.delete(item.place.id));
  }

  void _report(PlaceOperationResult? result) {
    if (result == null || result.succeeded) return;
    _showMessage(placeOutcomeMessage(result));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('המקומות שלי', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('add-place'),
          onPressed: manager.loaded ? () => _openEditor() : null,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: const Icon(Icons.add_location_alt_outlined),
          label: const Text('הוספת מקום חדש'),
        ),
        if (manager.loadFailure != null) ...[
          const SizedBox(height: 8),
          Text(
            'טעינת המקומות נכשלה: ${manager.loadFailure}',
            key: const Key('places-load-error'),
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
              onPressed: _interactive
                  ? () => unawaited(_run('', manager.retryRegistration))
                  : null,
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
          Padding(
            key: const Key('places-empty'),
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              children: [
                Icon(
                  Icons.place_outlined,
                  size: 40,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 8),
                const Text(
                  'עדיין אין מקומות. הוסיפו מקום כדי לקבל תזכורת בהגעה.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else
          for (final item in manager.places)
            PlaceCard(
              item: item,
              interactive: _interactive,
              inFlight: _inFlight.contains(item.place.id),
              onOpen: () => unawaited(_openEditor(item)),
              onToggle: (value) => unawaited(_toggle(item, value)),
              onDelete: () => unawaited(_confirmDelete(item)),
            ),
      ],
    );
  }
}
