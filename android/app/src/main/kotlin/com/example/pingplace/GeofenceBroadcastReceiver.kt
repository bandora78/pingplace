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
import java.util.concurrent.atomic.AtomicBoolean

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
        val targets = MultiPlaceGeofenceRegistration.targets(context)
        val desiredIds = targets.map { it.placeId }
        val blocked = mutableListOf<Pair<String?, String>>()
        val started = mutableListOf<String>()
        val unknown = mutableListOf<String>()
        var legacyTargetMissing = false
        // APP-10E: the start-from-background exemption that comes with this
        // broadcast is short. Every service start happens before any
        // diagnostics or UI-queue write; Build 20 lost an ENTER when the
        // thread stalled 39 s between those writes and the start after them.
        EnterStartRecovery.plan(type, ids).forEach { step ->
            when (step) {
                is EnterStartRecovery.Step.StartVerification -> {
                    val placeId = step.placeId
                    val target = targets.firstOrNull { it.placeId == placeId }
                    if (target != null) {
                        val failure = PreciseLocationService.startFromGeofence(context, target)
                        if (failure == null) started += placeId else blocked += placeId to failure
                    } else if (placeId == PlaceDiagnostics.LEGACY_ID) {
                        val preferences = context.getSharedPreferences(GeofenceEventBus.PREFS, Context.MODE_PRIVATE)
                        val latitude = preferences.getString("target_latitude", null)?.toDoubleOrNull()
                        val longitude = preferences.getString("target_longitude", null)?.toDoubleOrNull()
                        if (latitude != null && longitude != null) {
                            PreciseLocationService.startFromGeofence(context, latitude, longitude, null)
                                ?.let { blocked += null to it }
                        } else legacyTargetMissing = true
                    } else unknown += placeId
                }
                is EnterStartRecovery.Step.QueueExit -> {
                    val placeId = step.placeId
                    PreciseLocationService.sendBackgroundEvent(
                        context, "exit", null, null, null, null,
                        placeId.takeUnless { it == PlaceDiagnostics.LEGACY_ID },
                        targets.firstOrNull { it.placeId == placeId },
                    )
                }
                EnterStartRecovery.Step.Diagnostics -> {
                    val triggerAge = event.triggeringLocation?.time?.takeIf { it > 0 }?.let { receivedAtWall - it }
                    GeofenceRecovery.recordDiagnostic(
                        context,
                        PlaceDiagnostics.transition(type, ids, desiredIds.toSet(), triggerAge),
                    )
                    ids.forEach { GeofenceRecovery.recordBackgroundEvent(context, type, error) }
                    started.forEach { placeId ->
                        if (EnterRecoveryStore.consumeIfRecovered(context, placeId)) {
                            GeofenceRecovery.recordDiagnostic(context, "ENTER_RECOVERY_DELIVERED place=$placeId")
                        }
                    }
                    unknown.forEach { GeofenceRecovery.recordDiagnostic(context, "GEOFENCE_ENTER_UNKNOWN_PLACE id=$it") }
                    val recoveries = blocked.mapNotNull { (placeId, failure) ->
                        recordBlockedStart(context, placeId, failure, SystemClock.elapsedRealtime() - receivedAt, desiredIds)
                    }
                    if (recoveries.isNotEmpty()) requestRecoveries(context, recoveries)
                }
                EnterStartRecovery.Step.PublishToUi -> {
                    ids.forEach { placeId ->
                        GeofenceEventBus.publish(context, type, error, placeId.takeUnless { it == PlaceDiagnostics.LEGACY_ID })
                    }
                    unknown.forEach { GeofenceEventBus.publish(context, "error", "Unknown place registration", it) }
                    if (legacyTargetMissing) {
                        GeofenceEventBus.publish(context, "error", "Target coordinates are not persisted", null)
                    }
                    blocked.forEach { (placeId, _) ->
                        GeofenceEventBus.publish(context, "error", "Unable to start background precise location", placeId)
                    }
                }
            }
        }
    }

    /**
     * An ENTER whose verification could not start: logged in both logs as an
     * outcome that is never a verified arrival. Returns the place to recover,
     * at most once per place in [EnterStartRecovery.WINDOW_MS].
     */
    private fun recordBlockedStart(
        context: Context,
        placeId: String?,
        failure: String,
        sinceReceive: Long,
        desiredIds: List<String>,
    ): String? {
        val now = System.currentTimeMillis()
        val decision = EnterStartRecovery.onBlocked(
            placeId,
            desiredIds,
            placeId?.let { EnterRecoveryStore.lastRecoveryAt(context, it) },
            now,
        )
        GeofenceRecovery.recordDiagnostic(context, EnterStartRecovery.blockedLine(placeId, failure, sinceReceive, decision))
        if (placeId != null) {
            PreciseLocationService.recordPipelineDiagnostic(
                context,
                EnterStartRecovery.blockedSummaryLine(placeId, failure, sinceReceive, decision),
            )
        }
        if (decision != EnterStartRecovery.Decision.REREGISTER || placeId == null) return null
        EnterRecoveryStore.markRequested(context, placeId, now)
        return placeId
    }

    /**
     * Re-adds only these places' geofences with INITIAL_TRIGGER_ENTER. No
     * service, GPS or other place is touched here: a device still inside gets
     * a new, platform-issued ENTER; a device that has left gets nothing.
     */
    private fun requestRecoveries(context: Context, placeIds: List<String>) {
        // Keep this process at receiver priority until the re-adds reach
        // Google Play services; on 2026-11-04 the process was killed 0.3 s
        // after the blocked start.
        val pending = goAsync()
        val finished = AtomicBoolean(false)
        val handler = Handler(Looper.getMainLooper())
        val finish = Runnable { if (finished.compareAndSet(false, true)) pending?.finish() }
        handler.postDelayed(finish, EnterStartRecovery.RECEIVER_HOLD_MS)
        var remaining = placeIds.size
        placeIds.forEach { placeId ->
            MultiPlaceGeofenceRegistration.recoverEnter(context, placeId) { success, reason ->
                GeofenceRecovery.recordDiagnostic(
                    context,
                    if (success) "ENTER_RECOVERY_REREGISTERED place=$placeId initialTrigger=ENTER"
                    else "ENTER_RECOVERY_FAILED place=$placeId reason=${reason ?: "unknown"}",
                )
                if (--remaining == 0) {
                    handler.removeCallbacks(finish)
                    finish.run()
                }
            }
        }
    }

    private fun publishFailure(context: Context, message: String) {
        GeofenceRecovery.recordBackgroundEvent(context, "error", message)
        GeofenceEventBus.publish(context, "error", message)
        if (!GeofenceEventBus.isAttached()) {
            PreciseLocationService.sendBackgroundEvent(context, "error", null, message, null, null, null)
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

