package com.example.pingplace

import android.content.Context
import org.json.JSONObject

/** The durable desired geofence configuration. Runtime detection state is separate. */
object RegistrationRecordStore {
    const val SCHEMA_VERSION = 1
    private const val KEY = "registration_record"
    private const val DEFAULT_REMINDER = "עצור בתחנת דלק יעד"

    enum class State {
        CONFIGURED,
        REGISTRATION_PENDING,
        REGISTRATION_CONFIRMED,
        RECOVERY_REQUIRED,
        RECOVERY_BLOCKED,
    }

    data class Record(
        val registration: GeofenceRecovery.Registration,
        val reminderText: String,
        val desiredMonitoring: Boolean,
        val state: State,
        val recoveryGeneration: Long,
    )

    enum class ReadFailure { MISSING, CORRUPT, UNSUPPORTED_SCHEMA }

    data class ReadResult(
        val record: Record?,
        val failure: ReadFailure? = null,
    )

    fun readResult(context: Context): ReadResult {
        val serialized = GeofenceRecovery.registrationPreferences(context).getString(KEY, null)
            ?: return ReadResult(null, ReadFailure.MISSING)
        return parseResult(serialized)
    }

    fun read(context: Context): Record? = readResult(context).record

    fun readFailure(context: Context): ReadFailure? = readResult(context).failure

    fun recordKeyPresent(context: Context): Boolean =
        GeofenceRecovery.registrationPreferences(context).contains(KEY)

    fun defaultReminder(): String = DEFAULT_REMINDER

    fun desiredDisabled(context: Context): Record? {
        val current = read(context) ?: return null
        return current.copy(
            desiredMonitoring = false,
            state = State.CONFIGURED,
            recoveryGeneration = current.recoveryGeneration + 1L,
        ).also { persist(context, it) }
    }

    fun configure(
        context: Context,
        registration: GeofenceRecovery.Registration,
        reminderText: String,
    ): Record {
        validate(registration)
        val previous = read(context)
        return Record(
            registration = registration,
            reminderText = reminderText.trim().ifEmpty { DEFAULT_REMINDER },
            desiredMonitoring = true,
            state = State.CONFIGURED,
            recoveryGeneration = (previous?.recoveryGeneration ?: 0L) + 1L,
        ).also { persist(context, it) }
    }

    fun updateState(context: Context, state: State, generation: Long? = null): Record? {
        val current = read(context) ?: return null
        return current.copy(
            state = state,
            recoveryGeneration = generation ?: current.recoveryGeneration,
        ).also { persist(context, it) }
    }

    fun persist(context: Context, record: Record) {
        validate(record.registration)
        val json = JSONObject().apply {
            put("schemaVersion", SCHEMA_VERSION)
            put("latitude", record.registration.latitude)
            put("longitude", record.registration.longitude)
            put("radius", record.registration.radius.toDouble())
            put("reminderText", record.reminderText)
            put("desiredMonitoring", record.desiredMonitoring)
            put("state", record.state.name)
            put("recoveryGeneration", record.recoveryGeneration)
        }
        // commit makes the desired record durable before add/remove is called.
        check(
            GeofenceRecovery.registrationPreferences(context).edit()
                .putString(KEY, json.toString())
                .commit(),
        ) { "Unable to commit persisted geofence registration record" }
    }

    fun validate(registration: GeofenceRecovery.Registration) {
        require(registration.latitude.isFinite() && registration.latitude in -90.0..90.0)
        require(registration.longitude.isFinite() && registration.longitude in -180.0..180.0)
        require(registration.radius.isFinite() && registration.radius > 0f)
    }

    private fun parseResult(serialized: String): ReadResult = try {
        val json = JSONObject(serialized)
        val schema = json.optInt("schemaVersion", -1)
        if (schema != SCHEMA_VERSION) return ReadResult(null, ReadFailure.UNSUPPORTED_SCHEMA)
        val registration = GeofenceRecovery.Registration(
            json.getDouble("latitude"),
            json.getDouble("longitude"),
            json.getDouble("radius").toFloat(),
        )
        validate(registration)
        ReadResult(
            Record(
                registration = registration,
                reminderText = json.optString("reminderText", DEFAULT_REMINDER).ifBlank { DEFAULT_REMINDER },
                desiredMonitoring = json.getBoolean("desiredMonitoring"),
                state = State.valueOf(json.getString("state")),
                recoveryGeneration = json.getLong("recoveryGeneration"),
            ),
        )
    } catch (_: Exception) {
        ReadResult(null, ReadFailure.CORRUPT)
    }
}
