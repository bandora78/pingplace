import 'background_arrival_session.dart';
import '../domain/smart_arrival_detection.dart';
import '../notification/notification_service.dart';
import '../runtime/arrival_runtime_store.dart';

/// Production headless router. Each stable place ID gets its own session and
/// persistence namespace; location samples are routed by the native service.
final class MultiPlaceBackgroundArrivalSession {
  MultiPlaceBackgroundArrivalSession({
    required this.onDiagnostic,
    required this.onCommand,
    ArrivalRuntimeStore? runtimeStore,
    NotificationService? notificationService,
    DateTime Function()? clock,
  }) : runtimeStore = runtimeStore ?? MethodChannelArrivalRuntimeStore(),
       notificationService =
           notificationService ?? MethodChannelNotificationService(),
       _clock = clock ?? DateTime.now;

  final void Function(String message) onDiagnostic;
  final Future<void> Function(String command) onCommand;
  final ArrivalRuntimeStore runtimeStore;
  final NotificationService notificationService;
  final DateTime Function() _clock;
  final Map<String, BackgroundArrivalSession> _sessions = {};
  Future<void> _tail = Future<void>.value();
  static const _legacy = '__legacy__';

  void dispose() {
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
  }

  Future<void> handleEvent(Map<Object?, Object?> payload) {
    final previous = _tail;
    final next = previous.then((_) => _handleEvent(payload));
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _handleEvent(Map<Object?, Object?> payload) async {
    final rawId = payload['placeId'];
    final placeId = rawId is String && rawId.trim().isNotEmpty ? rawId : _legacy;
    var session = _sessions[placeId];
    if (session == null) {
      if (placeId != _legacy && payload['type'] != 'enter') {
        onDiagnostic('BACKGROUND_EVENT_IGNORED unknown place id');
        return;
      }
      final targetLatitude = (payload['targetLatitude'] as num?)?.toDouble();
      final targetLongitude = (payload['targetLongitude'] as num?)?.toDouble();
      final config = targetLatitude != null && targetLongitude != null
          ? SmartArrivalConfig(
              target: TargetLocation(
                latitude: targetLatitude,
                longitude: targetLongitude,
              ),
              innerRadius: (payload['innerRadius'] as num?)?.toDouble() ?? 80,
              rearmRadius: (payload['rearmRadius'] as num?)?.toDouble() ?? 350,
              cooldownDuration: Duration(
                seconds: (payload['cooldownSeconds'] as num?)?.toInt() ?? 600,
              ),
              approachTimeout: Duration(
                seconds:
                    (payload['approachTimeoutSeconds'] as num?)?.toInt() ?? 600,
              ),
              maxAcceptedAccuracy:
                  (payload['maxAcceptedAccuracy'] as num?)?.toDouble() ?? 50,
            )
          : null;
      session = BackgroundArrivalSession(
        onDiagnostic: (message) => onDiagnostic('$placeId $message'),
        onCommand: onCommand,
        runtimeStore: _runtimeFor(placeId),
        notificationService: _notificationsFor(placeId),
        config: config,
        clock: _clock,
      );
      _sessions[placeId] = session;
    }
    await session.handleEvent(payload);
  }

  ArrivalRuntimeStore _runtimeFor(String placeId) {
    final store = runtimeStore;
    if (store is! PerPlaceArrivalRuntimeStore || placeId == _legacy) return store;
    return _PlaceRuntimeAdapter(store as PerPlaceArrivalRuntimeStore, placeId);
  }

  NotificationService _notificationsFor(String placeId) {
    if (placeId == _legacy) return notificationService;
    return _PlaceNotificationAdapter(notificationService, placeId);
  }
}

final class _PlaceRuntimeAdapter implements ArrivalRuntimeStore {
  _PlaceRuntimeAdapter(this.store, this.placeId);
  final PerPlaceArrivalRuntimeStore store;
  final String placeId;

  @override
  Future<DetectionRuntimeSnapshot?> load() => store.loadForPlace(placeId);
  @override
  Future<void> save(DetectionRuntimeSnapshot snapshot) =>
      store.saveForPlace(placeId, snapshot);
  @override
  Future<void> clear() => store.clearForPlace(placeId);
  @override
  Future<String> loadReminderText() => store.loadReminderTextForPlace(placeId);
  @override
  Future<void> saveReminderText(String value) async {}
}

final class _PlaceNotificationAdapter implements NotificationService {
  _PlaceNotificationAdapter(this.delegate, this.placeId);
  final NotificationService delegate;
  final String placeId;

  @override
  Future<NotificationStatus> status() => delegate.status();
  @override
  Future<void> requestPermission() => delegate.requestPermission();
  @override
  Future<void> openSettings() => delegate.openSettings();
  @override
  Future<void> resetTest() => delegate.resetTest();
  @override
  Future<NotificationDeliveryResult> deliver({
    required String visitId,
    required String reminderText,
  }) => delegate.deliver(
    visitId: '$placeId:$visitId',
    reminderText: reminderText,
  );
}
