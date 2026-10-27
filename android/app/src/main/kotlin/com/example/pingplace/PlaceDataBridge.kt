package com.example.pingplace

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

object PlaceDataBridge {
    const val CHANNEL = "pingplace/places"
    private const val PREFS = "pingplace_places"
    private const val STATE = "state"

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        when (call.method) {
            "loadState" -> result.success(preferences.getString(STATE, null))
            "saveState" -> {
                val serialized = call.arguments as? String
                if (serialized == null) {
                    result.error("INVALID_ARGUMENT", "Place state must be JSON", null)
                    return
                }
                try {
                    val json = JSONObject(serialized)
                    if (json.optInt("schemaVersion", -1) != 1 ||
                        !json.has("places") ||
                        !json.has("reminders")
                    ) {
                        result.error("INVALID_ARGUMENT", "Unsupported place state", null)
                        return
                    }
                    result.success(preferences.edit().putString(STATE, serialized).commit())
                } catch (_: Exception) {
                    result.error("INVALID_ARGUMENT", "Place state must be valid JSON", null)
                }
            }
            else -> result.notImplemented()
        }
    }
}
