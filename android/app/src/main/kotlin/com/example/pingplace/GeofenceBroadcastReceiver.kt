package com.example.pingplace

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

class GeofenceBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent)
        if (event == null) {
            val message = "Invalid geofencing intent"
            GeofenceRecovery.recordBackgroundEvent(context, "error", message)
            GeofenceEventBus.publish(context, "error", message)
            if (!GeofenceEventBus.isAttached()) {
                PreciseLocationService.sendBackgroundEvent(context, "error", null, message, null, null)
            }
            return
        }
        if (event.hasError()) {
            val message = "GeofencingEvent error ${event.errorCode}"
            GeofenceRecovery.recordBackgroundEvent(context, "error", message)
            GeofenceEventBus.publish(context, "error", message)
            if (!GeofenceEventBus.isAttached()) {
                PreciseLocationService.sendBackgroundEvent(context, "error", null, message, null, null)
            }
            return
        }
        val type = when (event.geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> "enter"
            Geofence.GEOFENCE_TRANSITION_EXIT -> "exit"
            else -> "error"
        }
        val error = if (type == "error") {
            "Unsupported geofence transition ${event.geofenceTransition}"
        } else {
            null
        }
        GeofenceRecovery.recordBackgroundEvent(context, type, error)
        GeofenceEventBus.publish(context, type, error)
        if (type == "enter") {
            val preferences = context.getSharedPreferences(GeofenceEventBus.PREFS, Context.MODE_PRIVATE)
            val latitude = preferences.getString("target_latitude", null)?.toDoubleOrNull()
            val longitude = preferences.getString("target_longitude", null)?.toDoubleOrNull()
            if (latitude == null || longitude == null) {
                GeofenceEventBus.publish(context, "error", "Target coordinates are not persisted")
            } else if (!GeofenceEventBus.isAttached()) {
                PreciseLocationService.startFromGeofence(context, latitude, longitude)
            }
        } else if (type == "exit" && !GeofenceEventBus.isAttached()) {
            PreciseLocationService.sendBackgroundEvent(context, "exit", null, null, null, null)
        }
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
    fun publish(context: Context, type: String, error: String?) {
        val safeError = if (type == "error" && error.isNullOrBlank()) "Missing geofence event detail" else error
        val event = PendingGeofenceEvent(type, Instant.now().toString(), safeError)
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
                            error = item.optString("error").ifEmpty { null },
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
                },
            )
        }
        return json.toString()
    }

    private data class PendingGeofenceEvent(
        val type: String,
        val timestamp: String,
        val error: String?,
    ) {
        fun toPayload(): Map<String, Any?> = mapOf(
            "type" to type,
            "timestamp" to timestamp,
            "error" to error,
        )
    }
}

