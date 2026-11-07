import 'dart:async';

import 'package:flutter/material.dart';

import '../build_info.dart';
import '../geofence/development_geofence_controller.dart';
import '../geofence/geofence_service.dart';
import '../places/place_manager.dart';
import '../places/places_section.dart';
import '../simulation/development_simulation_screen.dart';
import 'home_status.dart';

/// Production home screen (APP-12): overall monitoring status, the user's
/// place cards, and the version footer that opens Developer Mode.
final class PingPlaceHomeScreen extends StatefulWidget {
  const PingPlaceHomeScreen({
    required this.controller,
    required this.placeManager,
    super.key,
  });

  /// Permission, notification and developer diagnostics.
  final DevelopmentGeofenceController controller;

  /// The user's places (APP-10): the only source of geofence registrations.
  final PlaceManager placeManager;

  @override
  State<PingPlaceHomeScreen> createState() => _PingPlaceHomeScreenState();
}

final class _PingPlaceHomeScreenState extends State<PingPlaceHomeScreen>
    with WidgetsBindingObserver {
  int _developerTapCount = 0;

  /// A banner action (permission request, settings, reload) is running.
  bool _actionRunning = false;

  /// The read-only resume refresh is running; further resumes are ignored.
  bool _resumeRefreshRunning = false;

  DevelopmentGeofenceController get controller => widget.controller;
  PlaceManager get manager => widget.placeManager;

  @override
  void initState() {
    super.initState();
    controller.addListener(_refresh);
    manager.addListener(_refresh);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    manager.removeListener(_refresh);
    controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshOnResume());
  }

  /// Owner decision 3: on returning to the foreground, re-read permissions
  /// and Android's registration status. Read-only: no permission prompt, no
  /// registration, no database write. Skipped while startup is still
  /// running, while a banner action runs (its own flow refreshes), while a
  /// previous resume refresh runs, and while PlaceManager is busy (every
  /// operation ends with the same reload).
  Future<void> _refreshOnResume() async {
    if (_resumeRefreshRunning || _actionRunning || !controller.initialized) {
      return;
    }
    _resumeRefreshRunning = true;
    try {
      await controller.refreshPermission();
      await controller.refreshNotificationPermission();
      if (mounted && manager.loaded && !manager.busy) {
        await manager.refresh();
      }
    } catch (_) {
      // Each call above records its own failure; nothing is shown as success.
    } finally {
      _resumeRefreshRunning = false;
    }
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_actionRunning) return;
    setState(() => _actionRunning = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _actionRunning = false);
    }
  }

  /// The existing location permission flow: request, then retry a rejected
  /// registration once background access is granted.
  Future<void> _grantLocation() async {
    await controller.requestPermission();
    if (controller.permission == GeofencePermissionStatus.backgroundAllowed &&
        manager.lastError != null) {
      await manager.retryRegistration();
    }
  }

  void _openDeveloperMode() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DevelopmentSimulationScreen(
          realGeofence: controller,
          placeManager: manager,
        ),
      ),
    );
  }

  void _onVersionTap() {
    _developerTapCount++;
    if (_developerTapCount >= 7) {
      _developerTapCount = 0;
      _openDeveloperMode();
    }
  }

  HomeStatus get _status => homeStatusFor(
    controllerInitialized: controller.initialized,
    locationPermission: controller.permission,
    notificationPermission: controller.notificationPermission,
    placesLoaded: manager.loaded,
    places: [for (final item in manager.places) item.registration],
    registrationStatusKnown: manager.registrationStatusKnown,
    persistenceFailure: controller.persistenceInitializationFailure,
    loadFailure: manager.loadFailure,
    operationError: manager.lastError,
    permissionReadFailed:
        controller.locationPermissionReadFailed ||
        controller.notificationPermissionReadFailed,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('PingPlace')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _StatusBanner(
              status: _status,
              busy: _actionRunning,
              onGrantLocation: () => unawaited(_runAction(_grantLocation)),
              onRequestNotifications: () => unawaited(
                _runAction(controller.requestNotificationPermission),
              ),
              onNotificationSettings: () =>
                  unawaited(_runAction(controller.openNotificationSettings)),
              onReload: () => unawaited(_runAction(manager.refresh)),
            ),
            if (controller.lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                controller.lastError!,
                key: const Key('home-controller-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 20),
            PlacesSection(manager: manager),
            const SizedBox(height: 24),
            GestureDetector(
              key: const Key('developer-mode-gesture'),
              onLongPress: _openDeveloperMode,
              onTap: _onVersionTap,
              child: Semantics(
                label: 'גרסת האפליקציה. הקשה חוזרת פותחת מצב מפתח',
                child: DefaultTextStyle.merge(
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(BuildInfo.current.versionLabel),
                      Text(
                        BuildInfo.current.commitLabel,
                        textDirection: TextDirection.ltr,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.status,
    required this.busy,
    required this.onGrantLocation,
    required this.onRequestNotifications,
    required this.onNotificationSettings,
    required this.onReload,
  });

  final HomeStatus status;
  final bool busy;
  final VoidCallback onGrantLocation;
  final VoidCallback onRequestNotifications;
  final VoidCallback onNotificationSettings;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final (background, foreground, icon) = switch (status.tone) {
      HomeStatusTone.success => (
        Colors.green.shade50,
        Colors.green.shade900,
        Icons.verified_outlined,
      ),
      HomeStatusTone.warning => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        Icons.warning_amber_outlined,
      ),
      HomeStatusTone.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.error_outline,
      ),
      HomeStatusTone.neutral => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        status.kind == HomeStatusKind.checking
            ? Icons.hourglass_empty
            : Icons.info_outline,
      ),
    };
    final actions = switch (status.action) {
      HomeStatusAction.none => const <Widget>[],
      HomeStatusAction.grantLocation => [
        FilledButton(
          key: const Key('home-status-action'),
          onPressed: busy ? null : onGrantLocation,
          child: const Text('מתן הרשאת מיקום'),
        ),
      ],
      HomeStatusAction.enableNotifications => [
        FilledButton(
          key: const Key('home-status-action'),
          onPressed: busy ? null : onRequestNotifications,
          child: const Text('הפעלת התראות'),
        ),
        // Android stops showing the prompt after repeated refusals; the
        // system settings page is then the only way to allow them.
        OutlinedButton(
          key: const Key('home-status-settings'),
          onPressed: busy ? null : onNotificationSettings,
          child: const Text('הגדרות התראות'),
        ),
      ],
      HomeStatusAction.reloadPlaces => [
        FilledButton(
          key: const Key('home-status-action'),
          onPressed: busy ? null : onReload,
          child: const Text('ניסיון חוזר'),
        ),
      ],
    };
    return Card(
      key: const Key('home-status'),
      margin: EdgeInsets.zero,
      color: background,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    icon,
                    key: const Key('home-status-icon'),
                    color: foreground,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status.title,
                          key: const Key('home-status-title'),
                          style: textTheme.titleMedium?.copyWith(
                            color: foreground,
                          ),
                        ),
                        if (status.detail != null)
                          Text(
                            status.detail!,
                            key: const Key('home-status-detail'),
                            style: textTheme.bodyMedium?.copyWith(
                              color: foreground,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
