package com.example.pingplace

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import org.json.JSONArray
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean

object GeofenceRecovery {
    const val REGISTRATION_PREFS = "pingplace_registration"
    private const val RECOVERY_PREFS = "pingplace_recovery"
    private const val DIAGNOSTICS = "diagnostics"
    private const val MAX_DIAGNOSTICS = 100
    private const val CONFIRMED = "registration_confirmed"
    private const val LAST_ATTEMPT = "last_recovery_attempt"
    private const val LAST_SUCCESS = "last_recovery_success"
    private const val LAST_FAILURE = "last_recovery_failure"
    private const val LAST_BACKGROUND_EVENT = "last_background_event"
    private const val LAST_BACKGROUND_FAILURE = "last_background_failure"
    private const val GEOfENCE_ID = "pingplace-phase0-outer"
    private val lock = Any()
    private var inFlight = false

    data class Registration(
        val latitude: Double,
        val longitude: Double,
        val radius: Float,
    )

    fun registrationPreferences(context: Context) =
        context.getSharedPreferences(REGISTRATION_PREFS, Context.MODE_PRIVATE)

    fun readRegistration(context: Context): Registration? {
        val stored = RegistrationRecordStore.readResult(context)
        stored.record?.let { return it.registration }
        // A present but invalid record is not treated as missing and is never
        // silently replaced by legacy data.
        if (stored.failure != RegistrationRecordStore.ReadFailure.MISSING) return null
        val current = registrationPreferences(context)
        val currentRegistration = parseRegistration(current)
        if (currentRegistration != null) return currentRegistration

        // Preserve registrations written by the pre-Task-07 Activity preferences.
        val legacyNames = listOf(
            "MainActivity_preferences",
            "com.example.pingplace.MainActivity_preferences",
        )
        for (name in legacyNames) {
            val legacy = context.getSharedPreferences(name, Context.MODE_PRIVATE)
            val registration = parseRegistration(legacy) ?: continue
            writeRegistration(context, registration)
            return registration
        }
        return null
    }

    fun writeRegistration(context: Context, registration: Registration) {
        RegistrationRecordStore.configure(context, registration, "עצור בתחנת דלק יעד")
    }

    fun clearRegistration(context: Context) {
        check(registrationPreferences(context).edit().clear().commit()) {
            "Unable to clear persisted geofence registration record"
        }
        check(context.getSharedPreferences("MainActivity_preferences", Context.MODE_PRIVATE).edit().clear().commit()) {
            "Unable to clear legacy geofence registration record"
        }
    }

    fun markRegistrationConfirmed(context: Context, confirmed: Boolean) {
        RegistrationRecordStore.updateState(
            context,
            if (confirmed) RegistrationRecordStore.State.REGISTRATION_CONFIRMED
            else RegistrationRecordStore.State.CONFIGURED,
        )
        recoveryPreferences(context).edit().putBoolean(CONFIRMED, confirmed).commit()
        if (confirmed) recoveryPreferences(context).edit().putString(LAST_SUCCESS, Instant.now().toString()).commit()
    }

    fun isRegistrationConfirmed(context: Context): Boolean =
        RegistrationRecordStore.read(context)?.state == RegistrationRecordStore.State.REGISTRATION_CONFIRMED

    fun status(context: Context): Map<String, Any?> {
        val preferences = recoveryPreferences(context)
        return mapOf(
            "registrationConfirmed" to isRegistrationConfirmed(context),
            "registrationState" to RegistrationRecordStore.read(context)?.state?.name,
            "desiredMonitoring" to (RegistrationRecordStore.read(context)?.desiredMonitoring == true),
            "recoveryGeneration" to RegistrationRecordStore.read(context)?.recoveryGeneration,
            "schemaVersion" to RegistrationRecordStore.read(context)?.let { RegistrationRecordStore.SCHEMA_VERSION },
            "reminderText" to RegistrationRecordStore.read(context)?.reminderText,
            "registrationRecordFailure" to RegistrationRecordStore.readFailure(context)?.name,
            "lastRecoveryAttempt" to preferences.getString(LAST_ATTEMPT, null),
            "lastRecoverySuccess" to preferences.getString(LAST_SUCCESS, null),
            "lastRecoveryFailure" to preferences.getString(LAST_FAILURE, null),
            "lastBackgroundEvent" to preferences.getString(LAST_BACKGROUND_EVENT, null),
            "lastBackgroundFailure" to preferences.getString(LAST_BACKGROUND_FAILURE, null),
            "diagnostics" to readDiagnostics(preferences),
        )
    }

    fun recordBackgroundEvent(context: Context, type: String, error: String?) {
        val preferences = recoveryPreferences(context)
        val timestamp = Instant.now().toString()
        val editor = preferences.edit().putString(LAST_BACKGROUND_EVENT, timestamp)
        if (error != null) editor.putString(LAST_BACKGROUND_FAILURE, "$timestamp $error")
        editor.commit()
        recordDiagnostic(context, if (error == null) "BACKGROUND_EVENT_RECEIVED $type" else "BACKGROUND_EVENT_FAILED $error")
    }

    fun recordDiagnostic(context: Context, message: String): Boolean {
        val preferences = recoveryPreferences(context)
        val diagnostics = try {
            JSONArray(preferences.getString(DIAGNOSTICS, "[]"))
        } catch (_: Exception) {
            JSONArray()
        }
        diagnostics.put("${Instant.now()} $message")
        while (diagnostics.length() > MAX_DIAGNOSTICS) diagnostics.remove(0)
        val committed = preferences.edit().putString(DIAGNOSTICS, diagnostics.toString()).commit()
        if (!committed) {
            android.util.Log.e("PingPlace", "Unable to persist geofence diagnostic: $message")
        }
        return committed
    }

    fun restore(
        context: Context,
        reason: String,
        callback: (success: Boolean, error: String?) -> Unit,
    ) {
        synchronized(lock) {
            if (inFlight) {
                recordDiagnostic(context, "GEOFENCE_RECOVERY_ALREADY_RUNNING")
                callback(false, "A geofence recovery is already running")
                return
            }
            inFlight = true
        }
        val preferences = recoveryPreferences(context)
        val startedAt = Instant.now().toString()
        val diagnosticPrefix = if (reason == "boot") "BOOT_RECOVERY" else "GEOFENCE_RECOVERY"
        val callbackCompleted = AtomicBoolean(false)
        var pendingRecord: RegistrationRecordStore.Record? = null
        fun finish(success: Boolean, error: String?) {
            if (!callbackCompleted.compareAndSet(false, true)) return
            synchronized(lock) { inFlight = false }
            val record = RegistrationRecordStore.read(context)
            val expected = pendingRecord
            if (expected != null && (record == null || !sameDesired(record, expected))) {
                recordDiagnostic(context, "${diagnosticPrefix}_STALE_CALLBACK_IGNORED generation=${expected.recoveryGeneration}")
                if (record != null && !record.desiredMonitoring) {
                    try {
                        LocationServices.getGeofencingClient(context)
                            .removeGeofences(GeofencePendingIntent.get(context))
                            .addOnSuccessListener { recordDiagnostic(context, "GEOFENCE_STALE_CALLBACK_CLEANUP_COMPLETED") }
                            .addOnFailureListener { cleanupError ->
                                recordDiagnostic(context, "GEOFENCE_STALE_CALLBACK_CLEANUP_FAILED ${cleanupError.message ?: cleanupError}")
                            }
                    } catch (cleanupError: Exception) {
                        recordDiagnostic(context, "GEOFENCE_STALE_CALLBACK_CLEANUP_FAILED ${cleanupError.message ?: cleanupError}")
                    }
                }
                callback(false, "Registration changed while recovery was in flight")
                return
            }
            try {
                if (success) {
                    val timestamp = Instant.now().toString()
                    if (record == null || expected == null) throw IllegalStateException("Missing active registration generation")
                    RegistrationRecordStore.persist(
                        context,
                        record.copy(state = RegistrationRecordStore.State.REGISTRATION_CONFIRMED),
                    )
                    check(preferences.edit().putBoolean(CONFIRMED, true).putString(LAST_SUCCESS, timestamp).commit()) {
                        "Unable to persist geofence recovery success"
                    }
                    recordDiagnostic(context, "${diagnosticPrefix}_COMPLETED reason=$reason")
                    recordDiagnostic(context, "GEOFENCE_RESTORED")
                } else {
                    val message = error ?: "Unknown geofence recovery failure"
                    val blocked = message.contains("permission", ignoreCase = true) ||
                        message.contains("disabled", ignoreCase = true)
                    if (record != null && expected != null) {
                        RegistrationRecordStore.persist(
                            context,
                            record.copy(
                                state = if (blocked) RegistrationRecordStore.State.RECOVERY_BLOCKED
                                else RegistrationRecordStore.State.RECOVERY_REQUIRED,
                            ),
                        )
                    }
                    check(preferences.edit().putBoolean(CONFIRMED, false)
                        .putString(LAST_FAILURE, "${Instant.now()} $message").commit()) {
                        "Unable to persist geofence recovery failure"
                    }
                    recordDiagnostic(context, "${diagnosticPrefix}_FAILED $message")
                }
            } catch (persistenceError: Exception) {
                recordDiagnostic(context, "${diagnosticPrefix}_PERSISTENCE_FAILED ${persistenceError.message ?: persistenceError}")
                callback(false, "Geofence recovery state could not be persisted: ${persistenceError.message ?: persistenceError}")
                return
            }
            callback(success, error)
        }

        val stored = RegistrationRecordStore.readResult(context)
        if (stored.failure == RegistrationRecordStore.ReadFailure.CORRUPT ||
            stored.failure == RegistrationRecordStore.ReadFailure.UNSUPPORTED_SCHEMA
        ) {
            recordDiagnostic(context, "REGISTRATION_RECORD_${stored.failure.name}")
            finish(false, "Saved geofence configuration is ${stored.failure.name}")
            return
        }
        val saved = stored.record ?: readRegistration(context)?.let {
            RegistrationRecordStore.configure(context, it, "עצור בתחנת דלק יעד")
        }
        if (saved == null || !saved.desiredMonitoring) {
            finish(false, "No saved geofence configuration")
            return
        }
        val pending = saved.copy(
            state = RegistrationRecordStore.State.REGISTRATION_PENDING,
            recoveryGeneration = saved.recoveryGeneration + 1L,
        )
        // The desired state is committed before any platform API call.
        try {
            RegistrationRecordStore.persist(context, pending)
            check(preferences.edit().putString(LAST_ATTEMPT, startedAt).remove(LAST_FAILURE).putBoolean(CONFIRMED, false).commit()) {
                "Unable to persist geofence recovery attempt"
            }
        } catch (persistenceError: Exception) {
            recordDiagnostic(context, "${diagnosticPrefix}_PERSISTENCE_FAILED ${persistenceError.message ?: persistenceError}")
            finish(false, "Geofence recovery state could not be persisted: ${persistenceError.message ?: persistenceError}")
            return
        }
        pendingRecord = pending
        if (!recordDiagnostic(context, "${diagnosticPrefix}_STARTED reason=$reason")) {
            finish(false, "Geofence recovery diagnostics could not be persisted")
            return
        }
        val registration = pending.registration
        try {
            check(context.getSharedPreferences(GeofenceEventBus.PREFS, Context.MODE_PRIVATE).edit()
                .putString("target_latitude", registration.latitude.toString())
                .putString("target_longitude", registration.longitude.toString())
                .commit()) { "Unable to persist geofence target handoff" }
        } catch (persistenceError: Exception) {
            recordDiagnostic(context, "${diagnosticPrefix}_PERSISTENCE_FAILED ${persistenceError.message ?: persistenceError}")
            finish(false, "Geofence target handoff could not be persisted: ${persistenceError.message ?: persistenceError}")
            return
        }
        val permissionFailure = locationPermissionFailure(context)
        if (permissionFailure != null) {
            finish(false, permissionFailure)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            !(context.getSystemService(LocationManager::class.java)?.isLocationEnabled ?: false)
        ) {
            finish(false, "Location services are disabled")
            return
        }

        val geofence = Geofence.Builder()
            .setRequestId(GEOfENCE_ID)
            .setCircularRegion(registration.latitude, registration.longitude, registration.radius)
            .setExpirationDuration(Geofence.NEVER_EXPIRE)
            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT)
            .build()
        val request = GeofencingRequest.Builder()
            .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
            .addGeofence(geofence)
            .build()
        val pendingIntent = GeofencePendingIntent.get(context)
        val client = LocationServices.getGeofencingClient(context)
        fun addRegistration(removalError: String? = null) {
            val current = RegistrationRecordStore.read(context)
            if (current == null || !current.desiredMonitoring || !sameDesired(current, pending)) {
                finish(false, "Registration changed before geofence mutation")
                return
            }
            try {
                client.addGeofences(request, pendingIntent)
                    .addOnSuccessListener { finish(true, null) }
                    .addOnFailureListener { error ->
                        finish(false, "Geofence registration failed${if (removalError != null) " after removal failure" else ""}: ${error.message ?: error}")
                    }
            } catch (error: Exception) {
                finish(false, "Geofence registration failed: ${error.message ?: error}")
            }
        }
        try {
            client.removeGeofences(pendingIntent).addOnCompleteListener { removalTask ->
                if (!removalTask.isSuccessful) {
                    val error = removalTask.exception?.message ?: "Unknown geofence removal failure"
                    // A missing old registration is normal after reboot. Record
                    // the failure, but let addGeofences establish the desired state.
                    recordDiagnostic(context, "GEOFENCE_REMOVE_FAILED_BEFORE_RECONCILE $error")
                    addRegistration(error)
                } else {
                    addRegistration()
                }
            }
        } catch (error: Exception) {
            recordDiagnostic(context, "GEOFENCE_REMOVE_FAILED_BEFORE_RECONCILE ${error.message ?: error}")
            addRegistration(error.message)
        }
    }

    /** Disables desired monitoring before removing the platform geofence. */
    fun remove(context: Context, callback: (success: Boolean, error: String?) -> Unit) {
        val stored = RegistrationRecordStore.readResult(context)
        if (stored.failure == RegistrationRecordStore.ReadFailure.CORRUPT ||
            stored.failure == RegistrationRecordStore.ReadFailure.UNSUPPORTED_SCHEMA
        ) {
            recordDiagnostic(context, "REGISTRATION_RECORD_${stored.failure.name}")
            callback(false, "Saved geofence configuration is ${stored.failure.name}")
            return
        }
        try {
            if (stored.record != null) RegistrationRecordStore.desiredDisabled(context)
        } catch (persistenceError: Exception) {
            recordDiagnostic(context, "GEOFENCE_REMOVE_PERSISTENCE_FAILED ${persistenceError.message ?: persistenceError}")
            callback(false, "Removal was not attempted because desired state could not be persisted")
            return
        }
        synchronized(lock) {
            if (inFlight) {
                recordDiagnostic(context, "GEOFENCE_REMOVE_WAITING_FOR_RECOVERY")
                callback(false, "Geofence recovery is still running; retry removal")
                return
            }
        }
        try {
            LocationServices.getGeofencingClient(context)
                .removeGeofences(GeofencePendingIntent.get(context))
                .addOnSuccessListener {
                    try {
                        clearRegistration(context)
                        callback(true, null)
                    } catch (persistenceError: Exception) {
                        recordDiagnostic(context, "GEOFENCE_REMOVE_CLEAR_FAILED ${persistenceError.message ?: persistenceError}")
                        callback(false, "Geofence removed but saved disabled state could not be cleared")
                    }
                }
                .addOnFailureListener { error ->
                    recordDiagnostic(context, "GEOFENCE_REMOVE_FAILED ${error.message ?: error}")
                    callback(false, error.message ?: "Geofence removal failed")
                }
        } catch (error: Exception) {
            recordDiagnostic(context, "GEOFENCE_REMOVE_FAILED ${error.message ?: error}")
            callback(false, error.message ?: "Geofence removal failed")
        }
    }

    private fun parseRegistration(preferences: android.content.SharedPreferences): Registration? {
        val latitude = preferences.getString("latitude", null)?.toDoubleOrNull()
            ?: preferences.getString("geofence_latitude", null)?.toDoubleOrNull()
        val longitude = preferences.getString("longitude", null)?.toDoubleOrNull()
            ?: preferences.getString("geofence_longitude", null)?.toDoubleOrNull()
        val radius = preferences.getString("radius", null)?.toFloatOrNull()
            ?: preferences.getString("geofence_radius", null)?.toFloatOrNull()
        if (latitude == null || longitude == null || radius == null ||
            !latitude.isFinite() || latitude < -90.0 || latitude > 90.0 ||
            !longitude.isFinite() || longitude < -180.0 || longitude > 180.0 || radius <= 0f
        ) return null
        return Registration(latitude, longitude, radius)
    }

    private fun locationPermissionFailure(context: Context): String? {
        val hasForeground =
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!hasForeground) return "Location permission is missing; grant foreground location first"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return "Background location permission is missing; enable Allow all the time"
        }
        return null
    }

    private fun recoveryPreferences(context: Context) =
        context.getSharedPreferences(RECOVERY_PREFS, Context.MODE_PRIVATE)

    private fun sameDesired(
        left: RegistrationRecordStore.Record,
        right: RegistrationRecordStore.Record,
    ): Boolean = left.registration == right.registration &&
        left.reminderText == right.reminderText &&
        left.desiredMonitoring == right.desiredMonitoring &&
        left.recoveryGeneration == right.recoveryGeneration

    private fun readDiagnostics(preferences: android.content.SharedPreferences): List<String> = try {
        val json = JSONArray(preferences.getString(DIAGNOSTICS, "[]"))
        buildList { for (index in 0 until json.length()) add(json.getString(index)) }
    } catch (_: Exception) {
        emptyList()
    }
}
