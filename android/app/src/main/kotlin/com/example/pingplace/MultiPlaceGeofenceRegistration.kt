package com.example.pingplace

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import androidx.core.content.ContextCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import org.json.JSONArray
import org.json.JSONObject

/**
 * Durable, serialized reconciliation for the APP-09 registrations.
 * The requested set is committed before the platform mutation, and every
 * later request reconciles the platform from the newest committed set. This
 * makes an older callback unable to become the final platform state.
 */
object MultiPlaceGeofenceRegistration {
    private const val PREFS = "pingplace_multi_geofences"
    private const val REQUESTS = "requests"
    private const val MODE = "multi_mode"
    private const val CONFIRMED = "registration_confirmed"
    private const val LEGACY_ID = "pingplace-phase0-outer"
    private const val MAX_GEOFENCES = 100

    data class Target(
        val placeId: String,
        val latitude: Double,
        val longitude: Double,
        val radius: Float,
        val innerRadius: Float = 80f,
        val rearmRadius: Float = 350f,
        val cooldownSeconds: Long = 600,
        val approachTimeoutSeconds: Long = 600,
        val maxAcceptedAccuracy: Float = 50f,
        val reminderText: String? = null,
    )

    fun register(context: Context, targets: List<Target>, callback: (Boolean, String?) -> Unit) {
        submit(context, targets, persist = true, callback)
    }

    fun restore(context: Context, callback: (Boolean, String?) -> Unit) {
        val desired = read(context)
        if (desired == null) {
            GeofenceRecovery.recordDiagnostic(context, "MULTI_GEOFENCE_DESIRED_STATE_CORRUPT")
            callback(false, "Multi-place desired state is corrupt")
            return
        }
        submit(context, desired, persist = false, callback)
    }

    fun target(context: Context, placeId: String): Target? = read(context)?.firstOrNull { it.placeId == placeId }

    fun desiredPlaceIds(context: Context): List<String> = read(context)?.map { it.placeId } ?: emptyList()

    fun hasDesired(context: Context): Boolean = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(MODE, false)

    fun isMultiMode(context: Context): Boolean = hasDesired(context)

    private fun submit(
        context: Context,
        targets: List<Target>,
        persist: Boolean,
        callback: (Boolean, String?) -> Unit,
    ) {
        GeofenceLifecycleCoordinator.submit(GeofenceLifecycleCoordinator.Kind.MULTI_RECONCILE, { done ->
            val stored = read(context)
            if (stored == null) {
                done(false, "Multi-place desired state is corrupt")
                return@submit
            }
            val previous = stored.map { it.placeId }
            if (persist && stored == targets && context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(CONFIRMED, false)) {
                done(true, null)
                return@submit
            }
            val desired = if (persist) {
                if (!write(context, targets)) {
                    done(false, "Multi-place desired state persistence failed")
                    return@submit
                }
                targets
            } else targets
            reconcile(context, desired, previous, done)
        }) { completion ->
            if (completion.stale) {
                GeofenceRecovery.recordDiagnostic(context, "MULTI_GEOFENCE_RECONCILE_STALE generation=${completion.generation}")
                callback(false, "Operation superseded")
            } else {
                if (completion.success) {
                    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(CONFIRMED, true).commit()
                } else {
                    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(CONFIRMED, false).commit()
                }
                callback(completion.success, completion.error)
            }
        }
    }

    private fun reconcile(context: Context, targets: List<Target>, previous: List<String>, done: (Boolean, String?) -> Unit) {
        val validation = validate(context, targets)
        if (validation != null) { done(false, validation); return }
        val client = LocationServices.getGeofencingClient(context)
        val pendingIntent = GeofencePendingIntent.get(context)
        val removeIds = (previous + targets.map { it.placeId }).distinct()
        val afterRemoval = {
            if (targets.isEmpty()) {
                client.removeGeofences(listOf(LEGACY_ID))
                    .addOnSuccessListener { done(true, null) }
                    .addOnFailureListener { done(false, "Legacy geofence removal failed") }
            } else {
                val request = GeofencingRequest.Builder()
                    .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
                    .addGeofences(targets.map { target ->
                        Geofence.Builder()
                            .setRequestId(target.placeId)
                            .setCircularRegion(target.latitude, target.longitude, target.radius)
                            .setExpirationDuration(Geofence.NEVER_EXPIRE)
                            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT)
                            .build()
                    }).build()
                try {
                    client.addGeofences(request, pendingIntent)
                        .addOnSuccessListener {
                            // Removal of the legacy request happens only after all
                            // replacement requests have been accepted.
                            client.removeGeofences(listOf(LEGACY_ID))
                                .addOnSuccessListener { done(true, null) }
                                .addOnFailureListener { done(false, "Legacy geofence removal failed") }
                        }
                        .addOnFailureListener { done(false, "Multi-place geofence registration failed") }
                } catch (_: Exception) { done(false, "Multi-place geofence registration failed") }
            }
        }
        try {
            if (removeIds.isEmpty()) afterRemoval()
            else client.removeGeofences(removeIds).addOnCompleteListener { result ->
                if (result.isSuccessful) afterRemoval()
                else done(false, "Multi-place geofence removal failed")
            }
        } catch (_: Exception) { done(false, "Multi-place geofence removal failed") }
    }

    private fun validate(context: Context, targets: List<Target>): String? {
        if (targets.size > MAX_GEOFENCES) return "Too many enabled places for Android geofencing limit"
        if (targets.map { it.placeId }.toSet().size != targets.size) return "Duplicate place ID"
        for (target in targets) {
            if (target.placeId.isBlank() || !target.latitude.isFinite() || target.latitude !in -90.0..90.0 ||
                !target.longitude.isFinite() || target.longitude !in -180.0..180.0 ||
                !target.radius.isFinite() || target.radius <= 0f) return "Invalid place geofence configuration"
        }
        val foreground = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!foreground) return "Location permission is missing"
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) != PackageManager.PERMISSION_GRANTED) return "Background location permission is missing"
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P &&
            !(context.getSystemService(LocationManager::class.java)?.isLocationEnabled ?: false)) return "Location services are disabled"
        return null
    }

    private fun write(context: Context, targets: List<Target>): Boolean = try {
        val json = JSONArray()
        targets.forEach { target -> json.put(JSONObject().apply {
            put("placeId", target.placeId); put("latitude", target.latitude)
            put("longitude", target.longitude); put("radius", target.radius.toDouble())
            put("innerRadius", target.innerRadius.toDouble()); put("rearmRadius", target.rearmRadius.toDouble())
            put("cooldownSeconds", target.cooldownSeconds); put("approachTimeoutSeconds", target.approachTimeoutSeconds)
            put("maxAcceptedAccuracy", target.maxAcceptedAccuracy.toDouble()); put("reminderText", target.reminderText ?: "")
        }) }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(MODE, true).putBoolean(CONFIRMED, false).putString(REQUESTS, json.toString()).commit()
    } catch (_: Exception) { false }

    private fun read(context: Context): List<Target>? = try {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(REQUESTS, null) ?: return emptyList()
        val json = JSONArray(raw)
        buildList { for (index in 0 until json.length()) {
            val item = json.getJSONObject(index)
            add(Target(
                item.getString("placeId"), item.getDouble("latitude"), item.getDouble("longitude"), item.getDouble("radius").toFloat(),
                item.optDouble("innerRadius", 80.0).toFloat(), item.optDouble("rearmRadius", 350.0).toFloat(),
                item.optLong("cooldownSeconds", 600L), item.optLong("approachTimeoutSeconds", 600L),
                item.optDouble("maxAcceptedAccuracy", 50.0).toFloat(), item.optString("reminderText").ifEmpty { null },
            ))
        } }
    } catch (_: Exception) { null }
}
