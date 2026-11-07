package com.example.pingplace

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * APP-10E: pure decisions for starting verification from a geofence
 * callback, and for an ENTER whose start Android refused. Free of Android
 * types so every rule here is JVM tested.
 *
 * Android 12+ lets an app start a foreground service from the background
 * only under an exemption; receiving a geofence transition is one, and it is
 * short-lived. In the Build 20 field log the receiver wrote its first line at
 * 19:39:41.004 and its next at 19:40:20.366; startForegroundService then
 * failed with ForegroundServiceStartNotAllowedException. What delayed the
 * thread between those two lines is not established by that log.
 *
 * Build 21 issues one start per callback, before any storage access; the
 * service validates the place IDs against the persisted configuration only
 * after it is in the foreground.
 *
 * Recovery never starts the service or GPS itself. It re-adds only the
 * affected place's geofence with INITIAL_TRIGGER_ENTER. Google Play services
 * documents that this triggers ENTER when the device is already inside at the
 * time the geofence is added; that delivery, like every geofence transition,
 * is best effort (it depends on Play services knowing the location).
 */
internal object EnterStartRecovery {
    /** One recovery per place in this window, so a blocked recovery cannot loop. */
    const val WINDOW_MS = 10 * 60 * 1000L

    /**
     * How long the receiver keeps its broadcast open for the re-add result.
     * Well below the broadcast timeout, so it can never cause an ANR.
     */
    const val RECEIVER_HOLD_MS = 8_000L

    enum class Decision {
        /** Re-add this place's geofence; a still-inside device gets a new ENTER. */
        REREGISTER,

        /** A recovery for this place was already requested in [WINDOW_MS]. */
        EXHAUSTED,

        /** The place is no longer desired (deleted or disabled), or is the legacy geofence. */
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
     * Checked again when the re-add actually runs (it is serialized behind
     * other registration work): the place must still be desired and the
     * last registration must have been confirmed as applied, including it.
     * A re-add can therefore never revive a deleted or disabled place, nor
     * add a place to a registration that failed.
     */
    fun mayReRegister(
        placeId: String,
        desiredPlaceIds: Collection<String>,
        registrationConfirmed: Boolean,
        appliedPlaceIds: Collection<String>?,
    ): Boolean =
        placeId in desiredPlaceIds && registrationConfirmed && (appliedPlaceIds == null || placeId in appliedPlaceIds)

    /**
     * A start that succeeded while a recovery for the place was pending in
     * the window is the recovered ENTER (or a genuine one; either is a valid
     * arrival check). The marker is cleared either way so a later blocked
     * start can recover again.
     */
    fun recoveredBy(lastRecoveryAtMillis: Long?, nowMillis: Long): Boolean =
        lastRecoveryAtMillis != null && nowMillis - lastRecoveryAtMillis in 0 until WINDOW_MS

    /** Where the start was refused: by startForegroundService in the receiver, or by startForeground in the service. */
    enum class Stage { START, PROMOTION }

    /** Native receiver log line. */
    fun blockedLine(placeId: String?, error: String, sinceReceiveMillis: Long, decision: Decision, stage: Stage = Stage.START): String =
        "PRECISE_LOCATION_START_BLOCKED place=${placeId ?: "legacy"} stage=${stage.name} error=$error " +
            "sinceReceive=${sinceReceiveMillis}ms recovery=${decision.name}"

    /**
     * Pipeline log line, shown under "Visit summaries" next to the place's
     * other outcomes. No visit was created: the ENTER never reached the
     * arrival engine, so it can never read as a verified arrival.
     */
    fun blockedSummaryLine(
        placeId: String,
        error: String,
        sinceReceiveMillis: Long,
        decision: Decision,
        stage: Stage = Stage.START,
    ): String =
        "$placeId APPROACH_SUMMARY outcome=START_BLOCKED visit=none stage=${stage.name} error=$error " +
            "sinceReceive=${sinceReceiveMillis}ms recovery=${decision.name}"

    /**
     * Order of work for one geofence callback. A single service start for
     * every place in the callback comes first, before any storage access;
     * diagnostics and UI-queue writes follow.
     */
    sealed interface Step {
        data class StartVerification(val placeIds: List<String>) : Step
        data class QueueExits(val placeIds: List<String>) : Step
        data object Diagnostics : Step
        data object PublishToUi : Step
    }

    fun plan(type: String, placeIds: List<String>): List<Step> {
        val start = when (type) {
            "enter" -> listOf(Step.StartVerification(placeIds))
            "exit" -> listOf(Step.QueueExits(placeIds))
            else -> emptyList()
        }
        return start + Step.Diagnostics + Step.PublishToUi
    }

    /** Receiver timing for one callback, all relative to receiver entry. */
    data class ReceiverTiming(
        val type: String,
        val places: Int,
        val parseMillis: Long,
        val startInvokedAtMillis: Long?,
        val startReturnedAtMillis: Long?,
        val startResult: String?,
        val triggerAgeMillis: Long?,
    )

    fun timingLine(timing: ReceiverTiming): String = buildString {
        append("GEOFENCE_RECEIVER_TIMING type=").append(timing.type)
        append(" places=").append(timing.places)
        append(" parse=").append(timing.parseMillis).append("ms")
        if (timing.startInvokedAtMillis != null) {
            append(" startInvoked=+").append(timing.startInvokedAtMillis).append("ms")
            append(" startReturned=+").append(timing.startReturnedAtMillis ?: -1).append("ms")
            append(" start=").append(timing.startResult ?: "ACCEPTED")
        }
        if (timing.triggerAgeMillis != null) append(" triggerAge=").append(timing.triggerAgeMillis).append("ms")
    }

    /** One place a geofence start resolved to, after the service reads the configuration. */
    data class Resolved(val placeId: String?, val target: MultiPlaceGeofenceRegistration.Target?, val latitude: Double, val longitude: Double)

    data class Resolution(val resolved: List<Resolved>, val unknown: List<String>, val legacyTargetMissing: Boolean)

    /**
     * Validates request IDs from the platform against the persisted
     * configuration. Only a registered place (or the legacy geofence with
     * persisted coordinates) is verified; anything else is reported and
     * never gets GPS.
     */
    fun resolve(
        placeIds: List<String>,
        targets: List<MultiPlaceGeofenceRegistration.Target>,
        legacyTarget: Pair<Double, Double>?,
    ): Resolution {
        val resolved = mutableListOf<Resolved>()
        val unknown = mutableListOf<String>()
        var legacyMissing = false
        placeIds.distinct().forEach { placeId ->
            val target = targets.firstOrNull { it.placeId == placeId }
            when {
                target != null -> resolved += Resolved(placeId, target, target.latitude, target.longitude)
                placeId == PlaceDiagnostics.LEGACY_ID && legacyTarget != null ->
                    resolved += Resolved(null, null, legacyTarget.first, legacyTarget.second)
                placeId == PlaceDiagnostics.LEGACY_ID -> legacyMissing = true
                else -> unknown += placeId
            }
        }
        return Resolution(resolved, unknown, legacyMissing)
    }

    /**
     * Holds a broadcast open (goAsync) until [expected] completions arrive
     * or the timeout fires, whichever is first; [release] runs exactly once.
     * Completions after release, duplicates beyond [expected], and
     * completions from any thread are safe.
     */
    class ReceiverHold(private val expected: Int, private val release: (reason: String) -> Unit) {
        private val remaining = AtomicInteger(expected)
        private val released = AtomicBoolean(false)

        val isReleased: Boolean get() = released.get()

        fun complete() {
            if (remaining.decrementAndGet() <= 0) releaseOnce("COMPLETED")
        }

        fun timeout() = releaseOnce("TIMEOUT")

        private fun releaseOnce(reason: String) {
            if (released.compareAndSet(false, true)) release(reason)
        }

        init {
            require(expected > 0)
        }
    }
}
