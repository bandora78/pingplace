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

/** Serializes all platform mutations in this process, including Activity recreation. */
internal object GeofenceLifecycleCoordinator {
    enum class Kind { REGISTER, REMOVE, RESTORE, RETRY_REMOVAL }

    data class Completion(
        val generation: Long,
        val success: Boolean,
        val error: String?,
        val stale: Boolean,
    )

    private data class Request(
        val kind: Kind,
        val generation: Long,
        val action: ((Boolean, String?) -> Unit) -> Unit,
        val callback: (Completion) -> Unit,
    )

    private val lock = Any()
    private val queue = ArrayDeque<Request>()
    private var latestGeneration = 0L
    private var running = false

    fun submit(
        kind: Kind,
        action: ((Boolean, String?) -> Unit) -> Unit,
        callback: (Completion) -> Unit,
    ): Long {
        val request = synchronized(lock) {
            val generation = ++latestGeneration
            Request(kind, generation, action, callback).also(queue::addLast)
        }
        pump()
        return request.generation
    }

    private fun pump() {
        val request = synchronized(lock) {
            if (running || queue.isEmpty()) return
            running = true
            queue.removeFirst()
        }
        val current = synchronized(lock) { request.generation == latestGeneration }
        if (!current) {
            finish(request, false, "Operation superseded", true)
            return
        }
        var completed = false
        fun done(success: Boolean, error: String?) {
            synchronized(lock) {
                if (completed) return
                completed = true
            }
            finish(request, success, error, synchronized(lock) { request.generation != latestGeneration })
        }
        try {
            request.action(::done)
        } catch (error: Exception) {
            done(false, safePlatformFailure(request.kind))
        }
    }

    private fun finish(request: Request, success: Boolean, error: String?, stale: Boolean) {
        try {
            request.callback(Completion(request.generation, success, error, stale))
        } finally {
            synchronized(lock) { running = false }
            pump()
        }
    }

    private fun safePlatformFailure(kind: Kind): String =
        when (kind) {
            Kind.REGISTER, Kind.RESTORE -> "Geofence registration failed"
            Kind.REMOVE, Kind.RETRY_REMOVAL -> "Platform removal failed"
        }
}

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
    private const val REMOVAL_PENDING = "removal_pending"
    private const val GEOfENCE_ID = "pingplace-phase0-outer"

    data class Registration(
        val latitude: Double,
        val longitude: Double,
        val radius: Float,
    )

    fun registrationPreferences(context: Context) =
        context.getSharedPreferences(REGISTRATION_PREFS, Context.MODE_PRIVATE)

    internal fun desiredStore(context: Context) =
        DesiredRegistrationStore(AndroidDesiredRegistrationStorage(context))

    internal fun recordPersistenceFailure(context: Context, error: DesiredRegistrationStore.StoreException) {
        val message = "GEOFENCE_STATE_${error.failure.name}"
        android.util.Log.e("PingPlace", message)
        try { recordDiagnostic(context, message) } catch (_: Exception) { }
    }

    fun readRegistration(context: Context): Registration? =
        try {
            desiredStore(context).load()?.takeIf { it.desiredMonitoring }
                ?.let { Registration(it.latitude, it.longitude, it.radius) }
        } catch (error: DesiredRegistrationStore.StoreException) {
            recordPersistenceFailure(context, error)
            null
        }

    fun markRegistrationConfirmed(context: Context, confirmed: Boolean) {
        val committed = try {
            val editor = recoveryPreferences(context).edit().putBoolean(CONFIRMED, confirmed)
            if (confirmed) editor.putString(LAST_SUCCESS, Instant.now().toString())
            editor.commit()
        } catch (_: Exception) { false }
        if (!committed) throw DesiredRegistrationStore.StoreException(DesiredRegistrationStore.Failure.PERSISTENCE_FAILED)
    }

    fun isRegistrationConfirmed(context: Context): Boolean =
        readRegistration(context) != null && recoveryPreferences(context).getBoolean(CONFIRMED, false)

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
        val diagnostics = try { JSONArray(preferences.getString(DIAGNOSTICS, "[]")) } catch (_: Exception) { JSONArray() }
        diagnostics.put("${Instant.now()} $message")
        while (diagnostics.length() > MAX_DIAGNOSTICS) diagnostics.remove(0)
        preferences.edit().putString(DIAGNOSTICS, diagnostics.toString()).apply()
    }

    fun register(
        context: Context,
        latitude: Double,
        longitude: Double,
        radius: Float,
        reminderText: String?,
        callback: (Boolean, String?) -> Unit,
    ) {
        GeofenceLifecycleCoordinator.submit(GeofenceLifecycleCoordinator.Kind.REGISTER, { done ->
            try {
                desiredStore(context).register(latitude, longitude, radius, reminderText) { record ->
                    try {
                        markRegistrationConfirmed(context, false)
                        replacePlatformRegistration(context, targetRequest(record), done)
                    } catch (error: DesiredRegistrationStore.StoreException) {
                        recordPersistenceFailure(context, error)
                        done(false, error.message)
                    }
                }
            } catch (error: DesiredRegistrationStore.StoreException) {
                recordPersistenceFailure(context, error)
                done(false, error.message)
            }
        }) { completion ->
            if (completion.stale) {
                recordDiagnostic(context, "GEOFENCE_REGISTER_STALE generation=${completion.generation}")
                callback(false, "Operation superseded")
            } else if (!completion.success) {
                callback(false, completion.error ?: "Geofence registration failed")
            } else {
                try {
                    val desired = desiredStore(context).load()
                    if (desired == null || !desired.desiredMonitoring) {
                        callback(false, "Desired geofence monitoring is disabled")
                    } else if (!markRemovalPending(context, false)) {
                        callback(false, "Removal state persistence failed")
                    } else {
                        markRegistrationConfirmed(context, true)
                        persistTarget(context, targetRequest(desired))
                        callback(true, null)
                    }
                } catch (error: DesiredRegistrationStore.StoreException) {
                    recordPersistenceFailure(context, error)
                    callback(false, error.message)
                }
            }
        }
    }

    fun remove(context: Context, callback: (Boolean, String?) -> Unit) {
        GeofenceLifecycleCoordinator.submit(GeofenceLifecycleCoordinator.Kind.REMOVE, { done ->
            try {
                desiredStore(context).remove {
                    try {
                        markRegistrationConfirmed(context, false)
                        val pendingDurable = markRemovalPending(context, true)
                        removePlatform(context) { removed, error ->
                            if (!removed) {
                                done(false, if (pendingDurable) error ?: "Platform removal failed" else "Removal state persistence failed")
                            } else if (!markRemovalPending(context, false)) {
                                done(false, "Removal state persistence failed")
                            } else {
                                done(
                                    pendingDurable,
                                    if (pendingDurable) null else "Removal state persistence failed",
                                )
                            }
                        }
                    } catch (error: DesiredRegistrationStore.StoreException) {
                        recordPersistenceFailure(context, error)
                        done(false, error.message)
                    }
                }
            } catch (error: DesiredRegistrationStore.StoreException) {
                recordPersistenceFailure(context, error)
                done(false, error.message)
            }
        }) { completion ->
            if (completion.stale) {
                recordDiagnostic(context, "GEOFENCE_REMOVE_STALE generation=${completion.generation}")
                callback(false, "Operation superseded")
            } else callback(completion.success, completion.error)
        }
    }

    fun restore(context: Context, reason: String, callback: (Boolean, String?) -> Unit) {
        GeofenceLifecycleCoordinator.submit(GeofenceLifecycleCoordinator.Kind.RESTORE, { done ->
            val desired = try {
                desiredStore(context).load()
            } catch (error: DesiredRegistrationStore.StoreException) {
                recordPersistenceFailure(context, error)
                done(false, error.message)
                return@submit
            }
            if (desired == null) {
                done(false, "Desired geofence state is missing")
                return@submit
            }
            if (!desired.desiredMonitoring) {
                // Disabled is authoritative even when a crash occurred before the
                // removal tombstone was committed. Reconcile the platform regardless.
                val tombstoneDurable = markRemovalPending(context, true)
                removePlatform(context) { removed, error ->
                    if (!removed) {
                        done(false, if (tombstoneDurable) error ?: "Platform removal failed" else "Removal state persistence failed")
                    } else if (!markRemovalPending(context, false)) {
                        done(false, "Removal state persistence failed")
                    } else {
                        try {
                            markRegistrationConfirmed(context, false)
                            done(tombstoneDurable, if (tombstoneDurable) null else "Removal state persistence failed")
                        } catch (failure: DesiredRegistrationStore.StoreException) {
                            recordPersistenceFailure(context, failure)
                            done(false, failure.message)
                        }
                    }
                }
                return@submit
            }
            recoveryPreferences(context).edit()
                .putString(LAST_ATTEMPT, Instant.now().toString())
                .remove(LAST_FAILURE)
                .apply()
            recordDiagnostic(context, "GEOFENCE_RECOVERY_STARTED reason=$reason")
            try {
                markRegistrationConfirmed(context, false)
                replacePlatformRegistration(context, targetRequest(desired), done)
            } catch (error: DesiredRegistrationStore.StoreException) {
                recordPersistenceFailure(context, error)
                done(false, error.message)
            }
        }) { completion ->
            if (completion.stale) {
                recordDiagnostic(context, "GEOFENCE_RECOVERY_STALE generation=${completion.generation}")
                callback(false, "Operation superseded")
            } else if (!completion.success) {
                recoveryPreferences(context).edit()
                    .putString(LAST_FAILURE, "${Instant.now()} ${completion.error}")
                    .apply()
                recordDiagnostic(context, "GEOFENCE_RECOVERY_FAILED type=${completion.error ?: "Unknown"}")
                callback(false, completion.error ?: "Geofence recovery failed")
            } else {
                try {
                    val desired = desiredStore(context).load()
                    if (desired?.desiredMonitoring == true) {
                        if (!markRemovalPending(context, false)) {
                            callback(false, "Removal state persistence failed")
                            return@submit
                        }
                        markRegistrationConfirmed(context, true)
                        persistTarget(context, targetRequest(desired))
                    }
                    recordDiagnostic(context, "GEOFENCE_RECOVERY_COMPLETED reason=$reason")
                    callback(true, null)
                } catch (error: DesiredRegistrationStore.StoreException) {
                    recordPersistenceFailure(context, error)
                    callback(false, error.message)
                }
            }
        }
    }
    fun markRemovalPending(context: Context, pending: Boolean): Boolean {
        val committed = try {
            recoveryPreferences(context).edit().putBoolean(REMOVAL_PENDING, pending).commit()
        } catch (_: Exception) { false }
        if (!committed) {
            recordDiagnostic(context, "GEOFENCE_REMOVAL_STATE_PERSISTENCE_FAILED")
            return false
        }
        recordDiagnostic(context, if (pending) "GEOFENCE_REMOVAL_PENDING" else "GEOFENCE_REMOVAL_CONFIRMED")
        return true
    }

    fun isRemovalPending(context: Context): Boolean =
        recoveryPreferences(context).getBoolean(REMOVAL_PENDING, false)

    fun retryPendingRemoval(context: Context, callback: (Boolean, String?) -> Unit) {
        GeofenceLifecycleCoordinator.submit(GeofenceLifecycleCoordinator.Kind.RETRY_REMOVAL, { done ->
            if (!isRemovalPending(context)) {
                done(true, null)
                return@submit
            }
            removePlatform(context) { removed, error ->
                if (!removed) done(false, error ?: "Platform removal failed")
                else if (!markRemovalPending(context, false)) done(false, "Removal state persistence failed")
                else {
                    try {
                        markRegistrationConfirmed(context, false)
                        done(true, null)
                    } catch (failure: DesiredRegistrationStore.StoreException) {
                        recordPersistenceFailure(context, failure)
                        done(false, failure.message)
                    }
                }
            }
        }) { completion ->
            if (completion.stale) {
                recordDiagnostic(context, "GEOFENCE_REMOVAL_STALE generation=${completion.generation}")
                callback(false, "Operation superseded")
            } else if (!completion.success) {
                recordDiagnostic(context, "GEOFENCE_REMOVAL_RETRY_FAILED")
                callback(false, completion.error ?: "Platform removal failed")
            } else callback(true, null)
        }
    }

    private fun removePlatform(context: Context, callback: (Boolean, String?) -> Unit) {
        try {
            LocationServices.getGeofencingClient(context)
                .removeGeofences(GeofencePendingIntent.get(context))
                .addOnSuccessListener { callback(true, null) }
                .addOnFailureListener { callback(false, "Platform removal failed") }
        } catch (_: Exception) {
            callback(false, "Platform removal failed")
        }
    }
    private data class Target(val latitude: Double, val longitude: Double, val radius: Float)

    private fun targetRequest(record: DesiredRegistrationStore.Record) =
        Target(record.latitude, record.longitude, record.radius)

    private fun persistTarget(context: Context, target: Target) {
        context.getSharedPreferences(GeofenceEventBus.PREFS, Context.MODE_PRIVATE).edit()
            .putString("target_latitude", target.latitude.toString())
            .putString("target_longitude", target.longitude.toString())
            .apply()
    }

    private fun replacePlatformRegistration(
        context: Context,
        target: Target,
        done: (Boolean, String?) -> Unit,
    ) {
        val permissionFailure = locationPermissionFailure(context)
        if (permissionFailure != null) { done(false, permissionFailure); return }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            !(context.getSystemService(LocationManager::class.java)?.isLocationEnabled ?: false)
        ) { done(false, "Location services are disabled"); return }
        val geofence = Geofence.Builder().setRequestId(GEOfENCE_ID)
            .setCircularRegion(target.latitude, target.longitude, target.radius)
            .setExpirationDuration(Geofence.NEVER_EXPIRE)
            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT).build()
        val request = GeofencingRequest.Builder().setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
            .addGeofence(geofence).build()
        val client = LocationServices.getGeofencingClient(context)
        val pendingIntent = GeofencePendingIntent.get(context)
        try {
            client.removeGeofences(pendingIntent).addOnCompleteListener { removal ->
                if (!removal.isSuccessful) { done(false, "Geofence removal failed before registration"); return@addOnCompleteListener }
                try {
                    client.addGeofences(request, pendingIntent)
                        .addOnSuccessListener { done(true, null) }
                        .addOnFailureListener { done(false, "Geofence registration failed") }
                } catch (_: Exception) { done(false, "Geofence registration failed") }
            }
        } catch (_: Exception) { done(false, "Geofence removal failed before registration") }
    }

    private fun locationPermissionFailure(context: Context): String? {
        val foreground = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!foreground) return "Location permission is missing; grant foreground location first"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            return "Background location permission is missing; enable Allow all the time"
        }
        return null
    }

    private fun recoveryPreferences(context: Context) = context.getSharedPreferences(RECOVERY_PREFS, Context.MODE_PRIVATE)

    private fun readDiagnostics(preferences: android.content.SharedPreferences): List<String> = try {
        val json = JSONArray(preferences.getString(DIAGNOSTICS, "[]"))
        buildList { for (index in 0 until json.length()) add(json.getString(index)) }
    } catch (_: Exception) { emptyList() }
}
