/// Overall monitoring status shown at the top of the home screen (APP-12).
///
/// Pure derivation from state that the controller and [PlaceManager] already
/// own: no Flutter, no platform calls. Problems are reported before anything
/// optimistic, and success is reported only when every required permission is
/// granted and Android has confirmed every enabled place. A place being
/// enabled is never treated as being monitored.
library;

import '../geofence/geofence_service.dart';
import '../notification/notification_service.dart';
import '../places/place_manager.dart';

enum HomeStatusKind {
  /// Startup reads have not finished; no permission or registration
  /// conclusion is drawn yet.
  checking,

  /// Place persistence failed to initialize (for example a failed migration).
  setupFailed,

  /// The stored places could not be read.
  loadFailed,

  /// A permission read on resume failed, so the shown permission is not
  /// current.
  permissionUnknown,

  /// No location permission at all.
  locationPermissionMissing,

  /// Foreground-only location: geofences cannot run in the background.
  backgroundPermissionMissing,

  /// Notifications are not allowed, so a confirmed arrival cannot be shown.
  notificationPermissionMissing,

  /// The last place operation or registration did not complete.
  operationFailed,

  noPlaces,
  allDisabled,

  /// Android's registration status could not be read, or it is unknown for
  /// every enabled place.
  registrationUnknown,

  /// No enabled place is confirmed yet; all are waiting for Android.
  pending,

  /// Some enabled places are confirmed and some are not.
  partial,

  /// Every enabled place is confirmed by Android and permissions are valid.
  active,
}

enum HomeStatusTone { neutral, success, warning, error }

/// The recovery the banner may offer. Each maps to an existing explicit
/// operation; none re-registers geofences on its own except the existing
/// location-permission flow, which retries registration after a grant.
enum HomeStatusAction { none, reloadPlaces, grantLocation, enableNotifications }

final class HomeStatus {
  const HomeStatus({
    required this.kind,
    required this.tone,
    required this.title,
    this.detail,
    this.action = HomeStatusAction.none,
    this.confirmedPlaces = 0,
    this.enabledPlaces = 0,
  });

  final HomeStatusKind kind;
  final HomeStatusTone tone;
  final String title;
  final String? detail;
  final HomeStatusAction action;

  /// Enabled places Android has confirmed ([PlaceRegistrationState.registered]).
  final int confirmedPlaces;
  final int enabledPlaces;
}

/// Prefix of PlaceManager's own registration failure. At startup the app
/// copies that failure into the controller's persistence-initialization
/// field; it is then tracked live by `PlaceManager.lastError` (and cleared by
/// a successful retry), so only other values there are setup failures.
const _registrationFailurePrefix = 'PLACE_REGISTRATION_FAILED';

HomeStatus homeStatusFor({
  required bool controllerInitialized,
  required GeofencePermissionStatus locationPermission,
  required NotificationPermissionStatus notificationPermission,
  required bool placesLoaded,
  required List<PlaceRegistrationState> places,
  required bool registrationStatusKnown,
  String? persistenceFailure,
  String? loadFailure,
  String? operationError,
  bool permissionReadFailed = false,
}) {
  final enabled = places
      .where((state) => state != PlaceRegistrationState.disabled)
      .toList();
  final confirmed = enabled
      .where((state) => state == PlaceRegistrationState.registered)
      .length;
  final unknown = enabled
      .where((state) => state == PlaceRegistrationState.unknown)
      .length;
  HomeStatus status(
    HomeStatusKind kind,
    HomeStatusTone tone,
    String title, {
    String? detail,
    HomeStatusAction action = HomeStatusAction.none,
  }) => HomeStatus(
    kind: kind,
    tone: tone,
    title: title,
    detail: detail,
    action: action,
    confirmedPlaces: confirmed,
    enabledPlaces: enabled.length,
  );

  if (!controllerInitialized || !placesLoaded) {
    return status(
      HomeStatusKind.checking,
      HomeStatusTone.neutral,
      'בודק מצב המעקב…',
    );
  }
  if (persistenceFailure != null &&
      !persistenceFailure.startsWith(_registrationFailurePrefix)) {
    return status(
      HomeStatusKind.setupFailed,
      HomeStatusTone.error,
      'טעינת המקומות השמורים נכשלה',
      detail: 'המעקב לא הופעל. הפרטים זמינים במצב מפתח.',
    );
  }
  if (loadFailure != null) {
    return status(
      HomeStatusKind.loadFailed,
      HomeStatusTone.error,
      'לא ניתן לטעון את המקומות',
      detail: 'מצב המעקב לא ידוע.',
      action: HomeStatusAction.reloadPlaces,
    );
  }
  if (permissionReadFailed) {
    return status(
      HomeStatusKind.permissionUnknown,
      HomeStatusTone.warning,
      'לא ניתן לאמת את מצב המעקב',
      detail: 'בדיקת ההרשאות נכשלה.',
      action: HomeStatusAction.grantLocation,
    );
  }
  switch (locationPermission) {
    case GeofencePermissionStatus.denied:
      return status(
        HomeStatusKind.locationPermissionMissing,
        HomeStatusTone.error,
        'נדרשת הרשאת מיקום',
        detail: 'בלי הרשאת מיקום לא תתקבל תזכורת בהגעה.',
        action: HomeStatusAction.grantLocation,
      );
    case GeofencePermissionStatus.foregroundOnly:
      return status(
        HomeStatusKind.backgroundPermissionMissing,
        HomeStatusTone.error,
        'נדרשת הרשאת מיקום גם ברקע',
        detail: 'יש לבחור "לאפשר כל הזמן" כדי לקבל תזכורת כשהאפליקציה סגורה.',
        action: HomeStatusAction.grantLocation,
      );
    case GeofencePermissionStatus.backgroundAllowed:
      break;
  }
  if (notificationPermission != NotificationPermissionStatus.allowed) {
    return status(
      HomeStatusKind.notificationPermissionMissing,
      HomeStatusTone.error,
      'נדרשת הרשאת התראות',
      detail: 'בלי הרשאת התראות התזכורת לא תוצג.',
      action: HomeStatusAction.enableNotifications,
    );
  }
  if (operationError != null) {
    return status(
      HomeStatusKind.operationFailed,
      HomeStatusTone.error,
      'פעולה על המקומות לא הושלמה',
      detail: 'ייתכן שהמעקב אינו מעודכן. הפרטים מופיעים מתחת ל"המקומות שלי".',
    );
  }
  if (places.isEmpty) {
    return status(
      HomeStatusKind.noPlaces,
      HomeStatusTone.neutral,
      'עדיין אין מקומות במעקב',
    );
  }
  if (enabled.isEmpty) {
    return status(
      HomeStatusKind.allDisabled,
      HomeStatusTone.neutral,
      'כל המקומות כבויים',
    );
  }
  final ofTotal = '$confirmed מתוך ${enabled.length} מקומות פעילים';
  if (confirmed == enabled.length && registrationStatusKnown) {
    return status(
      HomeStatusKind.active,
      HomeStatusTone.success,
      'המעקב פעיל',
      detail: enabled.length == 1
          ? 'מקום אחד במעקב'
          : '${enabled.length} מקומות במעקב',
    );
  }
  if (confirmed > 0) {
    return status(
      HomeStatusKind.partial,
      HomeStatusTone.warning,
      'חלק מהמקומות עדיין לא פעילים',
      detail: ofTotal,
    );
  }
  if (!registrationStatusKnown || unknown > 0) {
    return status(
      HomeStatusKind.registrationUnknown,
      HomeStatusTone.warning,
      'לא ניתן לאמת את מצב המעקב',
      detail: ofTotal,
    );
  }
  return status(
    HomeStatusKind.pending,
    HomeStatusTone.warning,
    'ממתין להפעלת המעקב',
    detail: ofTotal,
  );
}
