package com.example.pingplace

import java.time.Instant
import java.util.Locale

/**
 * Pure formatting and classification for multi-place field diagnostics.
 * Kept free of Android APIs so it is covered by JVM unit tests.
 */
internal object PlaceDiagnostics {
    /** Receiver entry for one platform transition: what Android delivered and how it was routed. */
    fun transition(type: String, ids: List<String>, registeredIds: Set<String>): String {
        val matched = ids.filter { it in registeredIds }
        val legacy = ids.filter { it == LEGACY_ID }
        val unknown = ids.filter { it !in registeredIds && it != LEGACY_ID }
        return buildString {
            append("GEOFENCE_TRANSITION ").append(type)
            append(" ids=").append(ids.joinToString(",", "[", "]"))
            append(" places=").append(matched.joinToString(",", "[", "]"))
            if (legacy.isNotEmpty()) append(" legacy=true")
            if (unknown.isNotEmpty()) append(" UNKNOWN=").append(unknown.joinToString(",", "[", "]"))
        }
    }

    /** The exact geofence set handed to Android, so field reports can be matched to the configuration. */
    fun registration(source: String, targets: List<MultiPlaceGeofenceRegistration.Target>): String =
        if (targets.isEmpty()) "MULTI_GEOFENCE_APPLIED source=$source count=0"
        else "MULTI_GEOFENCE_APPLIED source=$source count=${targets.size} " +
            targets.joinToString(" ") { target ->
                // ~100 m precision: enough to recognise the place, no exact location in logs.
                String.format(
                    Locale.ROOT,
                    "%s@%.3f,%.3f/r%.0f",
                    target.placeId,
                    target.latitude,
                    target.longitude,
                    target.radius,
                )
            }

    fun registrationFailed(source: String, error: String?): String =
        "MULTI_GEOFENCE_RECONCILE_FAILED source=$source reason=${error ?: "unknown"}"

    data class ExitRecord(val reason: Int, val timestampMillis: Long, val description: String?)

    // android.app.ApplicationExitInfo reason codes (API 30+), mirrored so this
    // stays testable on the JVM.
    const val REASON_EXIT_SELF = 1
    const val REASON_SIGNALED = 2
    const val REASON_LOW_MEMORY = 3
    const val REASON_CRASH = 4
    const val REASON_CRASH_NATIVE = 5
    const val REASON_ANR = 6
    const val REASON_INITIALIZATION_FAILURE = 7
    const val REASON_PERMISSION_CHANGE = 8
    const val REASON_EXCESSIVE_RESOURCE_USAGE = 9
    const val REASON_USER_REQUESTED = 10
    const val REASON_USER_STOPPED = 11
    const val REASON_DEPENDENCY_DIED = 12
    const val REASON_OTHER = 13
    const val REASON_FREEZER = 14
    const val REASON_PACKAGE_STATE_CHANGE = 15
    const val REASON_PACKAGE_UPDATED = 16

    fun reasonName(reason: Int): String = when (reason) {
        REASON_EXIT_SELF -> "EXIT_SELF"
        REASON_SIGNALED -> "SIGNALED"
        REASON_LOW_MEMORY -> "LOW_MEMORY"
        REASON_CRASH -> "CRASH"
        REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        REASON_ANR -> "ANR"
        REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        REASON_USER_REQUESTED -> "FORCE_STOPPED"
        REASON_USER_STOPPED -> "USER_STOPPED"
        REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        REASON_OTHER -> "OTHER"
        REASON_FREEZER -> "FREEZER"
        REASON_PACKAGE_STATE_CHANGE -> "PACKAGE_STATE_CHANGE"
        REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
        else -> "UNKNOWN_$reason"
    }

    /**
     * Exits after which Android drops every geofence and alarm of the app until
     * it is started again. On Xiaomi/HyperOS, "clear all" in recents and some
     * battery policies force-stop apps, which looks like geofencing silently
     * stopped working.
     */
    fun geofencesCleared(reason: Int): Boolean =
        reason == REASON_USER_REQUESTED || reason == REASON_USER_STOPPED || reason == REASON_PERMISSION_CHANGE

    /** New exit records since [sinceMillis], oldest first, as diagnostic lines. */
    fun exitDiagnostics(records: List<ExitRecord>, sinceMillis: Long): List<String> =
        records.filter { it.timestampMillis > sinceMillis }
            .sortedBy { it.timestampMillis }
            .map { record ->
                val base = "APP_PROCESS_EXIT reason=${reasonName(record.reason)} at=${Instant.ofEpochMilli(record.timestampMillis)}" +
                    (record.description?.takeIf { it.isNotBlank() }?.let { " detail=$it" } ?: "")
                if (geofencesCleared(record.reason)) "$base GEOFENCES_CLEARED_BY_ANDROID re-registered at next app start"
                else base
            }

    const val LEGACY_ID = "pingplace-phase0-outer"
}
