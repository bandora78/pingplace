package com.example.pingplace

import org.json.JSONObject

/**
 * Reads an optional string from stored JSON.
 *
 * Android's `JSONObject.optString` returns the literal string "null" for a
 * JSON null. Builds up to 18 stored cleared fields as JSON null, so a cleared
 * visit ID came back as "null" and was reused for every later visit, which
 * then de-duplicated as one notification. Already-stored "null" values are
 * treated as absent too.
 */
internal fun JSONObject.optNullableString(key: String): String? {
    if (!has(key) || isNull(key)) return null
    val value = optString(key)
    return if (value.isEmpty() || value == "null") null else value
}

/** Pure encoding of the per-place detection runtime state (unit tested). */
internal object RuntimeStateCodec {
    fun encode(arguments: Map<*, *>): String = JSONObject().apply {
        put("state", arguments["state"] ?: "disarmed")
        putNullable("targetLatitude", arguments["targetLatitude"])
        putNullable("targetLongitude", arguments["targetLongitude"])
        putNullable("approachStartedAt", arguments["approachStartedAt"])
        putNullable("cooldownUntil", arguments["cooldownUntil"])
        put("exitObservedDuringCooldown", arguments["exitObservedDuringCooldown"] ?: false)
        putNullable("visitId", arguments["visitId"])
    }.toString()

    fun decode(serialized: String): Map<String, Any?> = try {
        val state = JSONObject(serialized)
        mapOf(
            "state" to (state.optNullableString("state") ?: "disarmed"),
            "targetLatitude" to state.optDouble("targetLatitude", Double.NaN).takeUnless { it.isNaN() },
            "targetLongitude" to state.optDouble("targetLongitude", Double.NaN).takeUnless { it.isNaN() },
            "approachStartedAt" to state.optNullableString("approachStartedAt"),
            "cooldownUntil" to state.optNullableString("cooldownUntil"),
            "exitObservedDuringCooldown" to state.optBoolean("exitObservedDuringCooldown", false),
            "visitId" to state.optNullableString("visitId"),
        )
    } catch (_: Exception) {
        emptyMap()
    }

    private fun JSONObject.putNullable(key: String, value: Any?) {
        put(key, value ?: JSONObject.NULL)
    }
}
