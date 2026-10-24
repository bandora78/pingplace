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

    internal fun desiredStore(context: Context) =
        DesiredRegistrationStore(AndroidDesiredRegistrationStorage(context))

    internal fun recordPersistenceFailure(
        context: Context,
        error: DesiredRegistrationStore.StoreException,
    ) {
        val message = "GEOFENCE_STATE_${error.failure.name}"
        android.util.Log.e("PingPlace", message)
        try {
            recordDiagnostic(context, message)
        } catch (_: Exception) {
            // Logcat remains available even when preference-backed diagnostics fail.
        }
    }

    fun readRegistration(context: Context): Registration? =
        try {
            desiredStore(context)
                .load()
                ?.takeIf { it.desiredMonitoring }
                ?.let { Registration(it.latitude, it.longitude, it.radius) }
        } catch (error: DesiredRegistrationStore.StoreException) {
            recordPersistenceFailure(context, error)
            null
        }

    fun markRegistrationConfirmed(context: Context, confirmed: Boolean) {
        val committed =
            try {
                val editor = recoveryPreferences(context).edit().putBoolean(CONFIRMED, confirmed)
                if (confirmed) editor.putString(LAST_SUCCESS, Instant.now().toString())
                editor.commit()
            } catch (_: Exception) {
                false
            }
        if (!committed) {
            throw DesiredRegistrationStore.StoreException(
                DesiredRegistrationStore.Failure.PERSISTENCE_FAILED
            )
        }
    }

    fun isRegistrationConfirmed(context: Context): Boolean =
        readRegistration(context) != null &&
            recoveryPreferences(context).getBoolean(CONFIRMED, false)

    fun status(context: Context): Map<String, Any?> {
        val preferences = recoveryPreferences(context)
        return mapOf(
            "registrationConfirmed" to isRegistrationConfirmed(context),
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
        editor.apply()
        recordDiagnostic(context, if (error == null) "BACKGROUND_EVENT_RECEIVED $type" else "BACKGROUND_EVENT_FAILED $error")
    }

    fun recordDiagnostic(context: Context, message: String) {
        val preferences = recoveryPreferences(context)
        val diagnostics = try {
            JSONArray(preferences.getString(DIAGNOSTICS, "[]"))
        } catch (_: Exception) {
            JSONArray()
        }
        diagnostics.put("${Instant.now()} $message")
        while (diagnostics.length() > MAX_DIAGNOSTICS) diagnostics.remove(0)
        preferences.edit().putString(DIAGNOSTICS, diagnostics.toString()).apply()
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
        val previouslyConfirmed = preferences.getBoolean(CONFIRMED, false)
        val startedAt = Instant.now().toString()
        val diagnosticPrefix = if (reason == "boot") "BOOT_RECOVERY" else "GEOFENCE_RECOVERY"
        preferences
            .edit()
            .putString(LAST_ATTEMPT, startedAt)
            .remove(LAST_FAILURE)
            .putBoolean(CONFIRMED, false)
            .apply()
        recordDiagnostic(context, "${diagnosticPrefix}_STARTED reason=$reason")

        val callbackCompleted = AtomicBoolean(false)
        fun finish(success: Boolean, error: String?) {
            if (!callbackCompleted.compareAndSet(false, true)) return
            synchronized(lock) { inFlight = false }
            if (success) {
                try {
                    markRegistrationConfirmed(context, true)
                } catch (failure: DesiredRegistrationStore.StoreException) {
                    recordPersistenceFailure(context, failure)
                    callback(false, failure.message)
                    return
                }
                recordDiagnostic(context, "${diagnosticPrefix}_COMPLETED reason=$reason")
                recordDiagnostic(context, "GEOFENCE_RESTORED")
            } else {
                val message = error ?: "Unknown geofence recovery failure"
                preferences.edit().putString(LAST_FAILURE, "${Instant.now()} $message").apply()
                recordDiagnostic(context, "${diagnosticPrefix}_FAILED $message")
            }
            callback(success, error)
        }

        try {
            desiredStore(context).restore ready@{ desired ->
                val registration = Registration(desired.latitude, desired.longitude, desired.radius)
                context
                    .getSharedPreferences(GeofenceEventBus.PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putString("target_latitude", registration.latitude.toString())
                    .putString("target_longitude", registration.longitude.toString())
                    .apply()
                val permissionFailure = locationPermissionFailure(context)
                if (permissionFailure != null) {
                    finish(false, permissionFailure)
                    return@ready
                }
                if (
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                        !(context.getSystemService(LocationManager::class.java)?.isLocationEnabled
                            ?: false)
                ) {
                    finish(false, "Location services are disabled")
                    return@ready
                }

                val geofence =
                    Geofence.Builder()
                        .setRequestId(GEOfENCE_ID)
                        .setCircularRegion(
                            registration.latitude,
                            registration.longitude,
                            registration.radius,
                        )
                        .setExpirationDuration(Geofence.NEVER_EXPIRE)
                        .setTransitionTypes(
                            Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT
                        )
                        .build()
                val request =
                    GeofencingRequest.Builder()
                        .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
                        .addGeofence(geofence)
                        .build()
                val pendingIntent = GeofencePendingIntent.get(context)
                val client = LocationServices.getGeofencingClient(context)
                fun addRegistration() {
                    try {
                        client
                            .addGeofences(request, pendingIntent)
                            .addOnSuccessListener { finish(true, null) }
                            .addOnFailureListener { error ->
                                finish(
                                    false,
                                    "Geofence registration failed: ${error.message ?: error}",
                                )
                            }
                    } catch (error: Exception) {
                        finish(false, "Geofence registration failed: ${error.message ?: error}")
                    }
                }
                if (!previouslyConfirmed) {
                    recordDiagnostic(context, "GEOFENCE_REMOVE_SKIPPED_NO_CONFIRMED_REGISTRATION")
                    addRegistration()
                    return@ready
                }
                try {
                    client.removeGeofences(pendingIntent).addOnCompleteListener { removalTask ->
                        if (!removalTask.isSuccessful) {
                            val error =
                                removalTask.exception?.message ?: "Unknown geofence removal failure"
                            finish(
                                false,
                                "Geofence removal failed; registration was not replaced: $error",
                            )
                            return@addOnCompleteListener
                        }
                        addRegistration()
                    }
                } catch (error: Exception) {
                    finish(
                        false,
                        "Geofence removal failed; registration was not replaced: ${error.message ?: error}",
                    )
                }
            }
        } catch (error: DesiredRegistrationStore.StoreException) {
            recordPersistenceFailure(context, error)
            finish(false, error.message)
        }
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

    private fun readDiagnostics(preferences: android.content.SharedPreferences): List<String> = try {
        val json = JSONArray(preferences.getString(DIAGNOSTICS, "[]"))
        buildList { for (index in 0 until json.length()) add(json.getString(index)) }
    } catch (_: Exception) {
        emptyList()
    }
}
