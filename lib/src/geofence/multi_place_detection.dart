import '../domain/smart_arrival_detection.dart';
import '../persistence/place.dart';

typedef PlaceNotification = Future<void> Function(Place place, Reminder reminder);

final class MultiPlaceDetectionCoordinator {
  MultiPlaceDetectionCoordinator({
    required Iterable<Place> places,
    required Iterable<Reminder> reminders,
    required this.notify,
  }) {
    replacePlaces(places, reminders);
  }

  final PlaceNotification notify;
  final Map<String, SmartArrivalDetectionEngine> _engines = {};
  final Map<String, Place> _places = {};
  final Map<String, List<Reminder>> _reminders = {};
  final Map<String, String> _lastNotificationVisit = {};

  void replacePlaces(Iterable<Place> places, Iterable<Reminder> reminders) {
    final next = {for (final place in places) place.id: place};
    _places
      ..clear()
      ..addAll(next);
    _reminders
      ..clear()
      ..addEntries(next.keys.map((id) => MapEntry(id, <Reminder>[])));
    for (final reminder in reminders) {
      _reminders[reminder.placeId]?.add(reminder);
    }
    _engines.removeWhere((id, _) => !next.containsKey(id));
    for (final place in next.values) {
      _engines[place.id] ??= SmartArrivalDetectionEngine(
        SmartArrivalConfig(
          target: place.target,
          outerRadius: place.outerRadius,
          innerRadius: place.innerRadius,
          rearmRadius: place.rearmRadius,
          cooldownDuration: place.cooldown,
          approachTimeout: place.approachTimeout,
          maxAcceptedAccuracy: place.maxAcceptedAccuracy,
        ),
      );
    }
  }

  Set<String> get placeIds => _engines.keys.toSet();

  DetectionState stateFor(String placeId) =>
      _engines[placeId]?.state ?? DetectionState.disarmed;

  Future<void> handle(String placeId, DetectionEvent event) async {
    final place = _places[placeId];
    final engine = _engines[placeId];
    if (place == null || !place.enabled || engine == null) return;
    final effects = engine.dispatch(event).effects;
    if (!effects.any((effect) =>
        effect.type == DetectionEffectType.notificationRequested)) {
      return;
    }
    final visit = engine.visitId;
    if (visit == null || _lastNotificationVisit[placeId] == visit) return;
    _lastNotificationVisit[placeId] = visit;
    for (final reminder in _reminders[placeId] ?? const <Reminder>[]) {
      await notify(place, reminder);
    }
  }
}