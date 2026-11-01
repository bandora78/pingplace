package com.example.pingplace

internal enum class RecoveryPath { MULTI_PLACE, LEGACY }

/**
 * Chooses which registration owns the platform geofences.
 *
 * Once the place list has been registered (multi-place mode), it is the only
 * source of geofences. Legacy single-target operations replace or remove
 * registrations through removeGeofences(PendingIntent), which removes every
 * geofence sharing that PendingIntent, including all places. They must
 * therefore never run in multi-place mode, neither at boot, nor as a startup
 * fallback, nor from a UI call.
 */
internal object RecoveryPolicy {
    fun path(multiPlaceManaged: Boolean): RecoveryPath =
        if (multiPlaceManaged) RecoveryPath.MULTI_PLACE else RecoveryPath.LEGACY

    fun legacyOperationAllowed(multiPlaceManaged: Boolean): Boolean = !multiPlaceManaged

    /** A failed multi-place restore is retried by the next app start, never by legacy recovery. */
    fun legacyFallbackAfterMultiFailure(multiPlaceManaged: Boolean): Boolean = !multiPlaceManaged

    const val LEGACY_DISABLED_ERROR = "LEGACY_REGISTRATION_DISABLED"
    const val LEGACY_DISABLED_MESSAGE =
        "Places are managed by the place list; legacy single-target registration is disabled"
}
