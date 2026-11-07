package com.example.pingplace

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

class GeofenceBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val receivedAt = SystemClock.elapsedRealtime()
        val receivedAtWall = System.currentTimeMillis()
        val event = GeofencingEvent.fromIntent(intent)
        if (event == null) {
            publishFailure(context, "Invalid geofencing intent")
            return
        }
        if (event.hasError()) {
            publishFailure(context, "GeofencingEvent error ${event.errorCode}")
            return
        }
        val type = when (event.geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> "enter"
            Geofence.GEOFENCE_TRANSITION_EXIT -> "exit"
            else -> "error"
        }
        val error = if (type == "error") "Unsupported geofence transition ${event.geofenceTransition}" else null
        val ids = event.triggeringGeofences.orEmpty().mapNotNull { it.requestId }.distinct()
        if (ids.isEmpty()) {
            publishFailure(context, error ?: "Geofence transition contained no request IDs")
            return
        }
        val parsedAt = SystemClock.elapsedRealtime()
        var start: GeofenceStartAttempt? = null
        // APP-10E: the start-from-background exemption that comes with this
        // broadcast is short. One start carries every place of this callback
        // and happens before any SharedPreferences read or write. The request
        // IDs come from the platform event; the service validates them
        // against the persisted configuration once it is in the foreground.
        EnterStartRecovery.plan(type, ids).forEach { step ->
            when (step) {
                is EnterStartRecovery.Step.StartVerification ->
                    start = PreciseLocationService.startFromGeofence(context, step.placeIds, receivedAt)
                is EnterStartRecovery.Step.QueueExits ->
                    start = PreciseLocationService.sendExitEvents(context, step.placeIds, receivedAt)
                EnterStartRecovery.Step.Diagnostics ->
                    recordDiagnostics(context, event, type, error, ids, receivedAt, receivedAtWall, parsedAt, start)
                EnterStartRecovery.Step.PublishToUi -> {
                    val refused = start?.failure != null
                    ids.forEach { placeId ->
                        GeofenceEventBus.publish(context, type, error, placeId.takeUnless { it == PlaceDiagnostics.LEGACY_ID })
                    }
                    if (refused) {
                        ids.forEach { placeId ->
                            GeofenceEventBus.publish(
                                context,
                                "error",
                                if (type == "enter") "Unable to start background precise location"
                                else "Unable to start background event processing",
                                placeId.takeUnless { it == PlaceDiagnostics.LEGACY_ID },
                            )
                        }
                    }
                }
            }
        }
    }

    private fun recordDiagnostics(
        context: Context,
        event: GeofencingEvent,
        type: String,
        error: String?,
        ids: List<String>,
        receivedAt: Long,
        receivedAtWall: Long,
        parsedAt: Long,
        start: GeofenceStartAttempt?,
    ) {
        val desiredIds = MultiPlaceGeofenceRegistration.desiredPlaceIds(context)
        val triggerAge = event.triggeringLocation?.time?.takeIf { it > 0 }?.let { receivedAtWall - it }
        GeofenceRecovery.recordDiagnostic(context, PlaceDiagnostics.transition(type, ids, desiredIds.toSet(), triggerAge))
        GeofenceRecovery.recordDiagnostic(
            context,
            EnterStartRecovery.timingLine(
                EnterStartRecovery.ReceiverTiming(
                    type = type,
                    places = ids.size,
                    parseMillis = parsedAt - receivedAt,
                    startInvokedAtMillis = start?.let { it.invokedAt - receivedAt },
                    startReturnedAtMillis = start?.let { it.returnedAt - receivedAt },
                    startResult = start?.failure,
                    triggerAgeMillis = triggerAge,
                ),
            ),
        )
        ids.forEach { GeofenceRecovery.recordBackgroundEvent(context, type, error) }
        ids.filter { it !in desiredIds && it != PlaceDiagnostics.LEGACY_ID }.forEach {
            GeofenceRecovery.recordDiagnostic(context, "GEOFENCE_${type.uppercase()}_UNKNOWN_PLACE id=$it")
        }
        val failure = start?.failure
        if (failure == null) {
            if (type == "enter") ids.forEach { placeId ->
                if (EnterRecoveryStore.consumeIfRecovered(context, placeId)) {
                    GeofenceRecovery.recordDiagnostic(context, "ENTER_RECOVERY_DELIVERED place=$placeId")
                }
            }
            return
        }
        if (type != "enter") {
            // A refused EXIT is reported; the place re-arms from its stored
            // cooldown at its next ENTER (COOLDOWN_ELAPSED_WHILE_STOPPED).
            GeofenceRecovery.recordDiagnostic(
                context,
                "BACKGROUND_EVENT_START_BLOCKED type=$type places=${ids.joinToString(",", "[", "]")} error=$failure",
            )
            return
        }
        val recoveries = EnterRecovery.recordBlocked(
            context,
            ids.map { it.takeUnless { id -> id == PlaceDiagnostics.LEGACY_ID } },
            failure,
            EnterStartRecovery.Stage.START,
            SystemClock.elapsedRealtime() - receivedAt,
            desiredIds,
        )
        if (recoveries.isEmpty()) return
        // Keep this process at receiver priority until each re-add has been
        // answered, at most RECEIVER_HOLD_MS; on 2026-11-04 the process was
        // killed 0.3 s after the blocked start.
        val pending = goAsync()
        val handler = Handler(Looper.getMainLooper())
        val holdStart = SystemClock.elapsedRealtime()
        var timeout: Runnable? = null
        val hold = EnterStartRecovery.ReceiverHold(recoveries.size) { reason ->
            timeout?.let(handler::removeCallbacks)
            GeofenceRecovery.recordDiagnostic(
                context,
                "ENTER_RECOVERY_RECEIVER_RELEASED reason=$reason after=${SystemClock.elapsedRealtime() - holdStart}ms",
            )
            pending?.finish()
        }
        timeout = Runnable { hold.timeout() }.also { handler.postDelayed(it, EnterStartRecovery.RECEIVER_HOLD_MS) }
        EnterRecovery.request(context, recoveries, receivedAt) { hold.complete() }
    }

    private fun publishFailure(context: Context, message: String) {
        GeofenceRecovery.recordBackgroundEvent(context, "error", message)
        GeofenceEventBus.publish(context, "error", message)
        if (!GeofenceEventBus.isAttached()) {
            PreciseLocationService.sendBackgroundEvent(context, "error", null, message, null, null, null)
        }
    }
}

/**
 * Logging and re-registration for an ENTER whose verification Android
 * refused, shared by the receiver (startForegroundService refused) and the
 * service (startForeground refused).
 */
internal object EnterRecovery {
    /** Logs the refused start for each place; returns the places to re-register. */
    fun recordBlocked(
        context: Context,
        placeIds: List<String?>,
        failure: String,
        stage: EnterStartRecovery.Stage,
        sinceReceive: Long,
        desiredIds: List<String> = MultiPlaceGeofenceRegistration.desiredPlaceIds(context),
    ): List<String> {
        val now = System.currentTimeMillis()
        return placeIds.distinct().mapNotNull { placeId ->
            val decision = EnterStartRecovery.onBlocked(
                placeId,
                desiredIds,
                placeId?.let { EnterRecoveryStore.lastRecoveryAt(context, it) },
                now,
            )
            GeofenceRecovery.recordDiagnostic(
                context,
                EnterStartRecovery.blockedLine(placeId, failure, sinceReceive, decision, stage),
            )
            if (placeId != null) {
                PreciseLocationService.recordPipelineDiagnostic(
                    context,
                    EnterStartRecovery.blockedSummaryLine(placeId, failure, sinceReceive, decision, stage),
                )
            }
            if (decision == EnterStartRecovery.Decision.REREGISTER && placeId != null) {
                // Persisted (commit) before the request: after process death
                // the limit still holds, so a recovery can never loop.
                EnterRecoveryStore.markRequested(context, placeId, now)
                placeId
            } else null
        }
    }

    /**
     * Re-adds only these places' geofences with INITIAL_TRIGGER_ENTER. No
     * service, GPS or other place is touched; [onEach] runs once per place
     * when the re-add is answered, on the main thread.
     */
    fun request(context: Context, placeIds: List<String>, receivedAt: Long, onEach: () -> Unit) {
        placeIds.forEach { placeId ->
            val requestedAt = SystemClock.elapsedRealtime()
            GeofenceRecovery.recordDiagnostic(
                context,
                "ENTER_RECOVERY_REQUESTED place=$placeId sinceReceive=${requestedAt - receivedAt}ms",
            )
            MultiPlaceGeofenceRegistration.recoverEnter(context, placeId) { success, reason ->
                val after = SystemClock.elapsedRealtime() - requestedAt
                GeofenceRecovery.recordDiagnostic(
                    context,
                    if (success) "ENTER_RECOVERY_REREGISTERED place=$placeId initialTrigger=ENTER after=${after}ms"
                    else "ENTER_RECOVERY_FAILED place=$placeId reason=${reason ?: "unknown"} after=${after}ms",
                )
                onEach()
            }
        }
    }
}

/** Per-place time of the last blocked-start recovery request. */
internal object EnterRecoveryStore {
    private const val PREFS = "pingplace_enter_recovery"

    fun lastRecoveryAt(context: Context, placeId: String): Long? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(placeId, -1L).takeIf { it > 0 }

    fun markRequested(context: Context, placeId: String, atMillis: Long) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putLong(placeId, atMillis).commit()
    }

    /** True if a recovery for [placeId] was pending in its window; the marker is cleared either way. */
    fun consumeIfRecovered(context: Context, placeId: String): Boolean {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val last = preferences.getLong(placeId, -1L).takeIf { it > 0 } ?: return false
        preferences.edit().remove(placeId).apply()
        return EnterStartRecovery.recoveredBy(last, System.currentTimeMillis())
    }
}

object GeofenceEventBus {
    const val PREFS = "pingplace_geofence"
    private const val PENDING_EVENTS = "pending_events"
    private const val MAX_PENDING_EVENTS = 32
    private var sink: ((Map<String, Any?>) -> Unit)? = null

    @Synchronized
    fun isAttached(): Boolean = sink != null

    @Synchronized
    fun attach(context: Context, newSink: (Map<String, Any?>) -> Unit) {
        sink = newSink
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val queue = readQueue(preferences.getString(PENDING_EVENTS, null))
        while (queue.isNotEmpty()) {
            val event = queue.removeAt(0)
            val payload = event.toPayload()
            newSink(payload)
            // Remove only after the event has been handed to Flutter. If the sink
            // throws, the event remains persisted for the next attachment.
            preferences.edit().putString(PENDING_EVENTS, encode(queue)).apply()
        }
        if (queue.isEmpty()) {
            preferences.edit().remove(PENDING_EVENTS).apply()
        }
    }

    @Synchronized
    fun detach() {
        sink = null
    }

    @Synchronized
    fun publish(context: Context, type: String, error: String?, placeId: String? = null) {
        val safeError = if (type == "error" && error.isNullOrBlank()) "Missing geofence event detail" else error
        val event = PendingGeofenceEvent(type, Instant.now().toString(), safeError, placeId)
        val currentSink = sink
        if (currentSink != null) {
            currentSink(event.toPayload())
            return
        }
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val queue = readQueue(preferences.getString(PENDING_EVENTS, null))
        if (queue.size == MAX_PENDING_EVENTS) {
            queue.removeAt(0)
        }
        queue.add(event)
        preferences.edit().putString(PENDING_EVENTS, encode(queue)).apply()
    }

    private fun readQueue(serialized: String?): MutableList<PendingGeofenceEvent> {
        if (serialized.isNullOrEmpty()) return mutableListOf()
        return try {
            val json = JSONArray(serialized)
            buildList {
                for (index in 0 until json.length()) {
                    val item = json.getJSONObject(index)
                    add(
                        PendingGeofenceEvent(
                            type = item.getString("type"),
                            timestamp = item.getString("timestamp"),
                            error = item.optNullableString("error"),
                            placeId = item.optNullableString("placeId"),
                        ),
                    )
                }
            }.toMutableList()
        } catch (_: Exception) {
            mutableListOf()
        }
    }

    private fun encode(queue: List<PendingGeofenceEvent>): String {
        val json = JSONArray()
        queue.forEach { event ->
            json.put(
                JSONObject().apply {
                    put("type", event.type)
                    put("timestamp", event.timestamp)
                    put("error", event.error ?: JSONObject.NULL)
                    put("placeId", event.placeId ?: JSONObject.NULL)
                },
            )
        }
        return json.toString()
    }

    private data class PendingGeofenceEvent(
        val type: String,
        val timestamp: String,
        val error: String?,
        val placeId: String?,
    ) {
        fun toPayload(): Map<String, Any?> = mapOf(
            "type" to type,
            "timestamp" to timestamp,
            "error" to error,
            "placeId" to placeId,
        )
    }
}

