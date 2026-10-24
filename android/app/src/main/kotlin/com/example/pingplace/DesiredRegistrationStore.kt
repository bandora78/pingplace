package com.example.pingplace

import org.json.JSONObject
import org.json.JSONTokener

/** Desired configuration only. Visit/cooldown state and platform confirmation live elsewhere. */
internal class DesiredRegistrationStore(private val storage: Storage) {
    interface Storage {
        fun current(): Map<String, *>

        fun legacy(): List<Map<String, *>>

        fun runtime(): Map<String, *>

        fun commitRecord(serialized: String): Boolean
    }

    data class Record(
        val latitude: Double,
        val longitude: Double,
        val radius: Float,
        val reminderText: String,
        val desiredMonitoring: Boolean = true,
    )

    enum class Failure {
        MISSING,
        CORRUPT,
        UNSUPPORTED_SCHEMA,
        READ_FAILED,
        PERSISTENCE_FAILED,
        DISABLED,
    }

    // Error messages deliberately contain no stored values or parser exception details.
    class StoreException(val failure: Failure) :
        IllegalStateException("Desired geofence state: ${failure.name}")

    fun load(): Record? {
        val current = read { storage.current() }
        if (current.containsKey(KEY)) {
            val serialized = current[KEY] as? String ?: fail(Failure.CORRUPT)
            return decode(serialized)
        }
        // A present but invalid source is not silently replaced by an older target.
        // Never combine coordinates from different namespaces or key layouts.
        for (source in listOf(current) + read { storage.legacy() }) {
            val prefix =
                when {
                    listOf("latitude", "longitude", "radius").any(source::containsKey) -> ""
                    listOf("geofence_latitude", "geofence_longitude", "geofence_radius")
                        .any(source::containsKey) -> "geofence_"
                    else -> continue
                }
            fun number(key: String): Double =
                when (val value = source[prefix + key]) {
                    is String -> value.toDoubleOrNull() ?: fail(Failure.CORRUPT)
                    is Number -> value.toDouble()
                    else -> fail(Failure.CORRUPT)
                }
            val record =
                Record(
                    latitude = number("latitude"),
                    longitude = number("longitude"),
                    radius = number("radius").toFloat(),
                    reminderText = legacyReminder(source),
                )
            validate(record)
            persist(record)
            return record
        }
        return null
    }

    fun register(
        latitude: Double,
        longitude: Double,
        radius: Float,
        reminderText: String?,
        platform: (Record) -> Unit,
    ) {
        val previous = load()
        val record =
            Record(
                latitude,
                longitude,
                radius,
                reminderText ?: previous?.reminderText ?: legacyReminder(emptyMap<String, Any>()),
            )
        persist(record)
        platform(record)
    }

    fun remove(platform: () -> Unit) {
        val record = load() ?: fail(Failure.MISSING)
        // Keep the disabled configuration authoritative over untouched legacy data.
        // This is not a tombstone, and no automatic removal retry is scheduled.
        persist(record.copy(desiredMonitoring = false))
        platform()
    }

    fun restore(platform: (Record) -> Unit) {
        val record = load() ?: fail(Failure.MISSING)
        if (!record.desiredMonitoring) fail(Failure.DISABLED)
        // commit() can fail after publishing an in-memory value in SharedPreferences.
        // Recommit before every recovery mutation; a cached read is not proof of durability.
        persist(record)
        platform(record)
    }

    private fun legacyReminder(source: Map<String, *>): String {
        for (values in listOf(read { storage.runtime() }, source)) {
            for (key in listOf("reminder_text", "reminderText")) {
                if (values.containsKey(key)) return values[key] as? String ?: fail(Failure.CORRUPT)
            }
        }
        return DEFAULT_REMINDER
    }

    private fun persist(record: Record) {
        validate(record)
        val serialized =
            JSONObject()
                .apply {
                    put("schemaVersion", SCHEMA_VERSION)
                    put("latitude", record.latitude)
                    put("longitude", record.longitude)
                    put("radius", record.radius.toDouble())
                    put("reminderText", record.reminderText)
                    put("desiredMonitoring", record.desiredMonitoring)
                }
                .toString()
        val committed =
            try {
                storage.commitRecord(serialized) && storage.current()[KEY] == serialized
            } catch (_: Exception) {
                false
            }
        if (!committed) fail(Failure.PERSISTENCE_FAILED)
    }

    private fun decode(serialized: String): Record {
        try {
            val parser = JSONTokener(serialized)
            val json = parser.nextValue() as? JSONObject ?: fail(Failure.CORRUPT)
            if (parser.nextClean() != '\u0000') fail(Failure.CORRUPT)
            val schema = json.opt("schemaVersion")
            if (schema !is Int && schema !is Long) fail(Failure.CORRUPT)
            if ((schema as Number).toLong() != SCHEMA_VERSION.toLong())
                fail(Failure.UNSUPPORTED_SCHEMA)
            fun number(key: String): Double =
                (json.get(key) as? Number)?.toDouble() ?: fail(Failure.CORRUPT)
            return Record(
                    number("latitude"),
                    number("longitude"),
                    number("radius").toFloat(),
                    json.get("reminderText") as? String ?: fail(Failure.CORRUPT),
                    json.get("desiredMonitoring") as? Boolean ?: fail(Failure.CORRUPT),
                )
                .also(::validate)
        } catch (error: StoreException) {
            throw error
        } catch (_: Exception) {
            fail(Failure.CORRUPT)
        }
    }

    private fun validate(record: Record) {
        if (
            !record.latitude.isFinite() ||
                record.latitude !in -90.0..90.0 ||
                !record.longitude.isFinite() ||
                record.longitude !in -180.0..180.0 ||
                !record.radius.isFinite() ||
                record.radius <= 0f
        )
            fail(Failure.CORRUPT)
    }

    private fun <T> read(block: () -> T): T =
        try {
            block()
        } catch (_: Exception) {
            fail(Failure.READ_FAILED)
        }

    private fun fail(failure: Failure): Nothing = throw StoreException(failure)

    companion object {
        const val KEY = "registration_record"
        const val SCHEMA_VERSION = 1
        const val DEFAULT_REMINDER = "עצור בתחנת דלק יעד"
    }
}
