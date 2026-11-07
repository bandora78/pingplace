import 'package:flutter/material.dart';

import 'place_manager.dart';

/// Text, icon and colour for one place's Android registration state.
///
/// Only [PlaceRegistrationState.registered] reads as active: it is the one
/// state Android has confirmed.
({String text, IconData icon, Color color}) registrationPresentation(
  PlaceRegistrationState state,
  ThemeData theme,
) => switch (state) {
  PlaceRegistrationState.registered => (
    text: 'פעיל · מאושר ע״י Android',
    icon: Icons.check_circle_outline,
    color: Colors.green.shade700,
  ),
  PlaceRegistrationState.pending => (
    text: 'ממתין לאישור Android',
    icon: Icons.schedule,
    color: theme.colorScheme.tertiary,
  ),
  PlaceRegistrationState.disabled => (
    text: 'מעקב כבוי',
    icon: Icons.pause_circle_outline,
    color: theme.colorScheme.onSurfaceVariant,
  ),
  PlaceRegistrationState.unknown => (
    text: 'מצב הרישום לא ידוע',
    icon: Icons.help_outline,
    color: theme.colorScheme.error,
  ),
};

enum _CardAction { edit, delete }

/// One saved place on the home screen (APP-12). Presentation only: every
/// action is a callback to the parent, which owns the PlaceManager calls.
///
/// The tappable content area, the switch and the menu are siblings, so a tap
/// on the switch or the menu never opens the editor.
final class PlaceCard extends StatelessWidget {
  const PlaceCard({
    required this.item,
    required this.interactive,
    required this.inFlight,
    required this.onOpen,
    required this.onToggle,
    required this.onDelete,
    super.key,
  });

  final ManagedPlace item;

  /// False while PlaceManager is busy: every control is disabled.
  final bool interactive;

  /// True while an operation started from this card is running.
  final bool inFlight;
  final VoidCallback onOpen;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final place = item.place;
    final theme = Theme.of(context);
    final status = registrationPresentation(item.registration, theme);
    return Card(
      key: Key('place-tile-${place.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: InkWell(
              key: Key('place-edit-${place.id}'),
              onTap: interactive ? onOpen : null,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      place.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    if (item.reminderText.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.reminderText,
                        key: Key('place-reminder-${place.id}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        SizedBox.square(
                          dimension: 18,
                          child: inFlight
                              ? CircularProgressIndicator(
                                  key: Key('place-progress-${place.id}'),
                                  strokeWidth: 2,
                                )
                              : Icon(
                                  status.icon,
                                  key: Key('place-status-icon-${place.id}'),
                                  size: 18,
                                  color: status.color,
                                ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              status.text,
                              key: Key('place-status-${place.id}'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: status.color,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Semantics(
              label: 'מעקב עבור ${place.name}',
              child: Switch(
                key: Key('place-switch-${place.id}'),
                // Always the stored value: no optimistic change.
                value: place.enabled,
                onChanged: interactive ? onToggle : null,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: PopupMenuButton<_CardAction>(
              key: Key('place-menu-${place.id}'),
              enabled: interactive,
              tooltip: 'פעולות נוספות עבור ${place.name}',
              icon: const Icon(Icons.more_vert),
              onSelected: (action) => switch (action) {
                _CardAction.edit => onOpen(),
                _CardAction.delete => onDelete(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  key: Key('place-menu-edit-${place.id}'),
                  value: _CardAction.edit,
                  child: const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.edit_outlined),
                    title: Text('עריכה'),
                  ),
                ),
                PopupMenuItem(
                  key: Key('place-delete-${place.id}'),
                  value: _CardAction.delete,
                  child: const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline),
                    title: Text('מחיקה'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
