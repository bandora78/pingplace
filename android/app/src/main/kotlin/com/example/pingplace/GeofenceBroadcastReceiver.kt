package com.example.pingplace

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import java.time.Instant

class GeofenceBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent)
        if (event == null) {
            GeofenceEventBus.publish(context, "enter", "Invalid geofencing intent")
            return
        }
        if (event.hasError()) {
            GeofenceEventBus.publish(context, "enter", "${event.errorCode}")
            return
        }
        val type = when (event.geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> "enter"
            Geofence.GEOFENCE_TRANSITION_EXIT -> "exit"
            else -> "enter"
        }
        GeofenceEventBus.publish(context, type, null)
    }
}

object GeofenceEventBus {
    private const val PREFS = "pingplace_geofence"
    private const val PENDING_EVENT = "pending_event"
    private var sink: ((Map<String, Any?>) -> Unit)? = null

    fun attach(context: Context, newSink: (Map<String, Any?>) -> Unit) {
        sink = newSink
        val pending = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(PENDING_EVENT, null)
        if (pending != null) {
            val parts = pending.split("|", limit = 3)
            if (parts.size == 3) {
                newSink(mapOf("type" to parts[0], "timestamp" to parts[1], "error" to parts[2].ifEmpty { null }))
            }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(PENDING_EVENT).apply()
        }
    }

    fun detach() {
        sink = null
    }

    fun publish(context: Context, type: String, error: String?) {
        val timestamp = Instant.now().toString()
        val payload = mapOf<String, Any?>("type" to type, "timestamp" to timestamp, "error" to error)
        val currentSink = sink
        if (currentSink != null) {
            currentSink(payload)
        } else {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(PENDING_EVENT, "$type|$timestamp|${error ?: ""}")
                .apply()
        }
    }
}
