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

    fun read(context: Context): Record? {
        val serialized = GeofenceRecovery.registrationPreferences(context).getString(KEY, null) ?: return null
        return parse(serialized)
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
        GeofenceRecovery.registrationPreferences(context).edit().putString(KEY, json.toString()).commit()
    }

    fun validate(registration: GeofenceRecovery.Registration) {
        require(registration.latitude.isFinite() && registration.latitude in -90.0..90.0)
        require(registration.longitude.isFinite() && registration.longitude in -180.0..180.0)
        require(registration.radius.isFinite() && registration.radius > 0f)
    }

    private fun parse(serialized: String): Record? = try {
        val json = JSONObject(serialized)
        if (json.optInt("schemaVersion", -1) != SCHEMA_VERSION) return null
        val registration = GeofenceRecovery.Registration(
            json.getDouble("latitude"),
            json.getDouble("longitude"),
            json.getDouble("radius").toFloat(),
        )
        validate(registration)
        Record(
            registration = registration,
            reminderText = json.optString("reminderText", DEFAULT_REMINDER).ifBlank { DEFAULT_REMINDER },
            desiredMonitoring = json.optBoolean("desiredMonitoring", false),
            state = State.valueOf(json.getString("state")),
            recoveryGeneration = json.getLong("recoveryGeneration"),
        )
    } catch (_: Exception) {
        null
    }
}
