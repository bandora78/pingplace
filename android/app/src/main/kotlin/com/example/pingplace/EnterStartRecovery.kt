package com.example.pingplace

/**
 * APP-10E: pure decisions for a geofence ENTER whose foreground-service start
 * Android refused, kept free of Android types so they are JVM tested.
 *
 * Android 12+ lets an app start a foreground service from the background
 * only inside a short exemption window that Google Play services grants with
 * each geofence transition broadcast. Build 20 spent that window on
 * diagnostics and SharedPreferences work before calling
 * startForegroundService; on 2026-11-04 the receiver thread stalled for 39 s
 * between two of those writes, and the start then failed with
 * ForegroundServiceStartNotAllowedException.
 *
 * Recovery never starts the service or GPS itself. It re-adds only the
 * affected place's geofence with INITIAL_TRIGGER_ENTER: if the device is
 * still inside, Google Play services sends a fresh ENTER transition, which
 * carries its own, platform-granted exemption window. If the device has left,
 * nothing is sent and the place keeps its normal registration.
 */
internal object EnterStartRecovery {
    /** One recovery per place in this window, so a blocked recovery cannot loop. */
    const val WINDOW_MS = 10 * 60 * 1000L

    /** How long the receiver keeps its broadcast open while the re-add reaches Google Play services. */
    const val RECEIVER_HOLD_MS = 8_000L

    enum class Decision {
        /** Re-add this place's geofence; a still-inside device gets a new ENTER. */
        REREGISTER,

        /** A recovery for this place was already requested in [WINDOW_MS]. */
        EXHAUSTED,

        /** The place is no longer desired (deleted or disabled): nothing to recover. */
        NOT_REGISTERED,
    }

    fun onBlocked(
        placeId: String?,
        desiredPlaceIds: Collection<String>,
        lastRecoveryAtMillis: Long?,
        nowMillis: Long,
    ): Decision = when {
        placeId == null || placeId !in desiredPlaceIds -> Decision.NOT_REGISTERED
        lastRecoveryAtMillis != null && nowMillis - lastRecoveryAtMillis in 0 until WINDOW_MS -> Decision.EXHAUSTED
        else -> Decision.REREGISTER
    }

    /**
     * A start that succeeded while a recovery for the place was pending in
     * the window is the recovered ENTER (or a genuine one; either is a valid
     * arrival check). The marker is cleared either way so a later blocked
     * start can recover again.
     */
    fun recoveredBy(lastRecoveryAtMillis: Long?, nowMillis: Long): Boolean =
        lastRecoveryAtMillis != null && nowMillis - lastRecoveryAtMillis in 0 until WINDOW_MS

    /** Native receiver log line. */
    fun blockedLine(placeId: String?, error: String, sinceReceiveMillis: Long, decision: Decision): String =
        "PRECISE_LOCATION_START_BLOCKED place=${placeId ?: "legacy"} error=$error " +
            "sinceReceive=${sinceReceiveMillis}ms recovery=${decision.name}"

    /**
     * Pipeline log line, shown under "Visit summaries" next to the place's
     * other outcomes. No visit was created: the ENTER never reached the
     * arrival engine, so it can never read as a verified arrival.
     */
    fun blockedSummaryLine(placeId: String, error: String, sinceReceiveMillis: Long, decision: Decision): String =
        "$placeId APPROACH_SUMMARY outcome=START_BLOCKED visit=none error=$error " +
            "sinceReceive=${sinceReceiveMillis}ms recovery=${decision.name}"

    /**
     * Order of work for one geofence callback. Every service start comes
     * first, while the exemption window is open; diagnostics and UI-queue
     * writes follow. Pure so the order is JVM tested.
     */
    sealed interface Step {
        data class StartVerification(val placeId: String) : Step
        data class QueueExit(val placeId: String) : Step
        data object Diagnostics : Step
        data object PublishToUi : Step
    }

    fun plan(type: String, routedPlaceIds: List<String>): List<Step> {
        val starts = routedPlaceIds.mapNotNull { placeId ->
            when (type) {
                "enter" -> Step.StartVerification(placeId)
                "exit" -> Step.QueueExit(placeId)
                else -> null
            }
        }
        return starts + Step.Diagnostics + Step.PublishToUi
    }
}
