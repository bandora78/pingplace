package com.example.pingplace

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

object LocationEventBus {
    private const val PREFS = "pingplace_location"
    private const val PENDING_EVENTS = "pending_events"
    private const val MAX_PENDING_EVENTS = 32
    private var sink: ((Map<String, Any?>) -> Unit)? = null

    @Synchronized
    fun attach(context: Context, newSink: (Map<String, Any?>) -> Unit) {
        sink = newSink
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val queue = readQueue(preferences.getString(PENDING_EVENTS, null))
        while (queue.isNotEmpty()) {
            val event = queue.removeAt(0)
            newSink(event.toPayload())
            preferences.edit().putString(PENDING_EVENTS, encode(queue)).apply()
        }
        if (queue.isEmpty()) preferences.edit().remove(PENDING_EVENTS).apply()
    }

    @Synchronized
    fun detach() {
        sink = null
    }

    @Synchronized
    fun publish(context: Context, payload: Map<String, Any?>) {
        val currentSink = sink
        if (currentSink != null) {
            currentSink(payload)
            return
        }
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val queue = readQueue(preferences.getString(PENDING_EVENTS, null))
        if (queue.size == MAX_PENDING_EVENTS) queue.removeAt(0)
        queue.add(PendingLocationEvent.fromPayload(payload))
        preferences.edit().putString(PENDING_EVENTS, encode(queue)).apply()
    }

    private fun readQueue(serialized: String?): MutableList<PendingLocationEvent> {
        if (serialized.isNullOrEmpty()) return mutableListOf()
        return try {
            val json = JSONArray(serialized)
            buildList {
                for (index in 0 until json.length()) {
                    val item = json.getJSONObject(index)
                    add(
                        PendingLocationEvent(
                            type = item.getString("type"),
                            latitude = item.numberOrNull("latitude"),
                            longitude = item.numberOrNull("longitude"),
                            accuracy = item.numberOrNull("accuracy"),
                            timestamp = item.getString("timestamp"),
                            error = if (item.isNull("error")) null else item.optString("error"),
                        ),
                    )
                }
            }.toMutableList()
        } catch (_: Exception) {
            mutableListOf()
        }
    }

    private fun encode(queue: List<PendingLocationEvent>): String {
        val json = JSONArray()
        queue.forEach { event ->
            json.put(
                JSONObject().apply {
                    put("type", event.type)
                    put("latitude", event.latitude ?: JSONObject.NULL)
                    put("longitude", event.longitude ?: JSONObject.NULL)
                    put("accuracy", event.accuracy ?: JSONObject.NULL)
                    put("timestamp", event.timestamp)
                    put("error", event.error ?: JSONObject.NULL)
                },
            )
        }
        return json.toString()
    }

    private data class PendingLocationEvent(
        val type: String,
        val latitude: Double?,
        val longitude: Double?,
        val accuracy: Double?,
        val timestamp: String,
        val error: String?,
    ) {
        fun toPayload(): Map<String, Any?> = mapOf(
            "type" to type,
            "latitude" to latitude,
            "longitude" to longitude,
            "accuracy" to accuracy,
            "timestamp" to timestamp,
            "error" to error,
        )

        companion object {
            fun fromPayload(payload: Map<String, Any?>) = PendingLocationEvent(
                type = payload["type"] as String? ?: "error",
                latitude = (payload["latitude"] as Number?)?.toDouble(),
                longitude = (payload["longitude"] as Number?)?.toDouble(),
                accuracy = (payload["accuracy"] as Number?)?.toDouble(),
                timestamp = payload["timestamp"] as String? ?: "",
                error = payload["error"] as String?,
            )
        }
    }
}

private fun JSONObject.numberOrNull(name: String): Double? =
    if (isNull(name)) null else optDouble(name)
