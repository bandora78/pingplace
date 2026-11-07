import 'package:flutter_test/flutter_test.dart';
import 'package:pingplace/src/geofence/geofence_service.dart';
import 'package:pingplace/src/home/home_status.dart';
import 'package:pingplace/src/notification/notification_service.dart';
import 'package:pingplace/src/places/place_manager.dart';

const _registered = PlaceRegistrationState.registered;
const _pending = PlaceRegistrationState.pending;
const _disabled = PlaceRegistrationState.disabled;
const _unknown = PlaceRegistrationState.unknown;

HomeStatus _status({
  bool initialized = true,
  GeofencePermissionStatus location =
      GeofencePermissionStatus.backgroundAllowed,
  NotificationPermissionStatus notifications =
      NotificationPermissionStatus.allowed,
  bool loaded = true,
  List<PlaceRegistrationState> places = const [_registered],
  bool statusKnown = true,
  String? persistenceFailure,
  String? loadFailure,
  String? operationError,
  bool permissionReadFailed = false,
}) => homeStatusFor(
  controllerInitialized: initialized,
  locationPermission: location,
  notificationPermission: notifications,
  placesLoaded: loaded,
  places: places,
  registrationStatusKnown: statusKnown,
  persistenceFailure: persistenceFailure,
  loadFailure: loadFailure,
  operationError: operationError,
  permissionReadFailed: permissionReadFailed,
);

void main() {
  group('startup', () {
    test('no permission conclusion before the controller initializes', () {
      // The controller's permission fields default to denied until read.
      final s = _status(
        initialized: false,
        location: GeofencePermissionStatus.denied,
        notifications: NotificationPermissionStatus.denied,
      );
      expect(s.kind, HomeStatusKind.checking);
      expect(s.title, 'בודק מצב המעקב…');
      expect(s.action, HomeStatusAction.none);
    });

    test('places not loaded yet is still checking', () {
      expect(_status(loaded: false).kind, HomeStatusKind.checking);
    });
  });

  group('failures come first', () {
    test('a persistence setup failure beats everything after startup', () {
      final s = _status(
        persistenceFailure: 'Place persistence initialization failed: x',
        location: GeofencePermissionStatus.denied,
      );
      expect(s.kind, HomeStatusKind.setupFailed);
      expect(s.tone, HomeStatusTone.error);
    });

    test(
      'a startup registration failure is tracked by the manager instead',
      () {
        // Copied into the persistence field at startup; a later successful
        // retry clears PlaceManager.lastError, so it must not stick here.
        final s = _status(
          persistenceFailure: 'PLACE_REGISTRATION_FAILED: rejected',
        );
        expect(s.kind, HomeStatusKind.active);
      },
    );

    test('a load failure offers a read-only reload', () {
      final s = _status(loadFailure: 'PLACE_LOAD_FAILED: io');
      expect(s.kind, HomeStatusKind.loadFailed);
      expect(s.action, HomeStatusAction.reloadPlaces);
    });

    test('a failed permission read is never shown as monitoring', () {
      final s = _status(permissionReadFailed: true);
      expect(s.kind, HomeStatusKind.permissionUnknown);
      expect(s.tone, isNot(HomeStatusTone.success));
    });

    test('an operation error beats every optimistic state', () {
      final s = _status(operationError: 'ENABLE p1 REGISTRATION_FAILED');
      expect(s.kind, HomeStatusKind.operationFailed);
      expect(s.tone, HomeStatusTone.error);
    });
  });

  group('permissions', () {
    test('missing location permission', () {
      final s = _status(location: GeofencePermissionStatus.denied);
      expect(s.kind, HomeStatusKind.locationPermissionMissing);
      expect(s.title, 'נדרשת הרשאת מיקום');
      expect(s.action, HomeStatusAction.grantLocation);
    });

    test('foreground-only location needs background access', () {
      final s = _status(location: GeofencePermissionStatus.foregroundOnly);
      expect(s.kind, HomeStatusKind.backgroundPermissionMissing);
      expect(s.action, HomeStatusAction.grantLocation);
    });

    test('missing or unavailable notifications', () {
      for (final value in [
        NotificationPermissionStatus.denied,
        NotificationPermissionStatus.unavailable,
      ]) {
        final s = _status(notifications: value);
        expect(s.kind, HomeStatusKind.notificationPermissionMissing);
        expect(s.title, 'נדרשת הרשאת התראות');
        expect(s.action, HomeStatusAction.enableNotifications);
      }
    });

    test('permission problems come before an operation error', () {
      expect(
        _status(
          location: GeofencePermissionStatus.foregroundOnly,
          operationError: 'x',
        ).kind,
        HomeStatusKind.backgroundPermissionMissing,
      );
    });

    test('granting the permissions recovers to active', () {
      expect(
        _status(location: GeofencePermissionStatus.denied).kind,
        HomeStatusKind.locationPermissionMissing,
      );
      expect(
        _status(notifications: NotificationPermissionStatus.denied).kind,
        HomeStatusKind.notificationPermissionMissing,
      );
      expect(_status().kind, HomeStatusKind.active);
    });

    test('permissions are required even with every place confirmed', () {
      final s = _status(
        places: [_registered, _registered],
        notifications: NotificationPermissionStatus.denied,
      );
      expect(s.kind, isNot(HomeStatusKind.active));
    });
  });

  group('places', () {
    test('no places is neutral, never active', () {
      final s = _status(places: const []);
      expect(s.kind, HomeStatusKind.noPlaces);
      expect(s.tone, HomeStatusTone.neutral);
    });

    test('all places disabled is neutral, never active', () {
      final s = _status(places: [_disabled, _disabled]);
      expect(s.kind, HomeStatusKind.allDisabled);
      expect(s.title, 'כל המקומות כבויים');
      expect(s.tone, HomeStatusTone.neutral);
    });

    test('active only when every enabled place is confirmed', () {
      final s = _status(places: [_registered, _disabled, _registered]);
      expect(s.kind, HomeStatusKind.active);
      expect(s.title, 'המעקב פעיל');
      expect(s.tone, HomeStatusTone.success);
      expect(s.confirmedPlaces, 2);
      expect(s.enabledPlaces, 2);
    });

    test('registered and pending is partial, with an exact count', () {
      final s = _status(places: [_registered, _pending, _registered]);
      expect(s.kind, HomeStatusKind.partial);
      expect(s.title, 'חלק מהמקומות עדיין לא פעילים');
      expect(s.detail, '2 מתוך 3 מקומות פעילים');
      expect(s.confirmedPlaces, 2);
    });

    test('registered and unknown is partial', () {
      final s = _status(places: [_registered, _unknown]);
      expect(s.kind, HomeStatusKind.partial);
      expect(s.tone, HomeStatusTone.warning);
    });

    test('all pending waits for Android', () {
      final s = _status(places: [_pending, _pending, _disabled]);
      expect(s.kind, HomeStatusKind.pending);
      expect(s.title, 'ממתין להפעלת המעקב');
      expect(s.detail, '0 מתוך 2 מקומות פעילים');
    });

    test('unknown registration cannot be verified', () {
      final s = _status(places: [_unknown, _pending], statusKnown: false);
      expect(s.kind, HomeStatusKind.registrationUnknown);
      expect(s.title, 'לא ניתן לאמת את מצב המעקב');
    });

    test('an enabled but unconfirmed place is never shown as monitored', () {
      for (final places in [
        [_pending],
        [_unknown],
        [_registered, _pending],
        [_registered, _unknown],
      ]) {
        for (final known in [true, false]) {
          final s = _status(places: places, statusKnown: known);
          expect(s.kind, isNot(HomeStatusKind.active), reason: '$places');
          expect(s.tone, isNot(HomeStatusTone.success), reason: '$places');
        }
      }
    });
  });
}
