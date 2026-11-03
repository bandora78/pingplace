package com.example.pingplace

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** APP-10C: a cleared visit ID must never come back as the string "null". */
class RuntimeStateCodecTest {
    @Test
    fun clearedFieldsRoundTripAsAbsent() {
        val decoded = RuntimeStateCodec.decode(
            RuntimeStateCodec.encode(
                mapOf(
                    "state" to "armed",
                    "targetLatitude" to 32.0,
                    "targetLongitude" to 34.8,
                    "approachStartedAt" to null,
                    "cooldownUntil" to null,
                    "exitObservedDuringCooldown" to false,
                    "visitId" to null,
                ),
            ),
        )
        assertEquals("armed", decoded["state"])
        assertNull(decoded["visitId"])
        assertNull(decoded["approachStartedAt"])
        assertNull(decoded["cooldownUntil"])
    }

    @Test
    fun valuesAlreadyStoredAsTheStringNullAreAbsent() {
        // State written by Build 18 on the field-test phone after Android's
        // optString had turned a JSON null into "null" and Dart saved it back.
        val stored = """{"state":"armed","targetLatitude":32.0,"targetLongitude":34.8,""" +
            """"approachStartedAt":"null","cooldownUntil":"null",""" +
            """"exitObservedDuringCooldown":false,"visitId":"null"}"""
        val decoded = RuntimeStateCodec.decode(stored)
        assertNull(decoded["visitId"])
        assertNull(decoded["approachStartedAt"])
        assertNull(decoded["cooldownUntil"])
        assertEquals(32.0, decoded["targetLatitude"])
    }

    @Test
    fun realValuesArePreserved() {
        val decoded = RuntimeStateCodec.decode(
            RuntimeStateCodec.encode(
                mapOf(
                    "state" to "cooldown",
                    "targetLatitude" to 31.66512,
                    "targetLongitude" to 34.78123,
                    "approachStartedAt" to "2026-11-03T14:25:42.000Z",
                    "cooldownUntil" to "2026-11-03T14:36:02.997Z",
                    "exitObservedDuringCooldown" to true,
                    "visitId" to "visit-1793715942000000",
                ),
            ),
        )
        assertEquals("cooldown", decoded["state"])
        assertEquals("visit-1793715942000000", decoded["visitId"])
        assertEquals("2026-11-03T14:36:02.997Z", decoded["cooldownUntil"])
        assertEquals("2026-11-03T14:25:42.000Z", decoded["approachStartedAt"])
        assertEquals(true, decoded["exitObservedDuringCooldown"])
        assertEquals(31.66512, decoded["targetLatitude"])
    }

    @Test
    fun corruptStateDecodesToEmpty() {
        assertEquals(emptyMap<String, Any?>(), RuntimeStateCodec.decode("{not json"))
    }

    @Test
    fun optNullableStringTreatsNullEmptyAndMissingAsAbsent() {
        val json = JSONObject()
            .put("jsonNull", JSONObject.NULL)
            .put("literal", "null")
            .put("empty", "")
            .put("value", "place-2")
        assertNull(json.optNullableString("jsonNull"))
        assertNull(json.optNullableString("literal"))
        assertNull(json.optNullableString("empty"))
        assertNull(json.optNullableString("missing"))
        assertEquals("place-2", json.optNullableString("value"))
    }
}
