package com.example.pingplace

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val methodChannelName = "pingplace/geofence"
    private val eventChannelName = "pingplace/geofence/events"
    private val locationMethodChannelName = "pingplace/location"
    private val locationEventChannelName = "pingplace/location/events"
    private val permissionRequestCode = 4201
    private var permissionResult: MethodChannel.Result? = null
    private var eventSink: EventChannel.EventSink? = null
    private var locationEventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkPermission" -> result.success(permissionStatus())
                    "registrationStatus" -> result.success(GeofenceRecovery.isRegistrationConfirmed(this))
                    "registrationDetails" -> result.success(registrationDetails())
                    "desiredRegistrationDetails" -> result.success(desiredRegistrationDetails())
                    "desiredMonitoring" -> result.success(GeofenceRecovery.isDesiredMonitoring(this))
                    "recoveryStatus" -> result.success(GeofenceRecovery.status(this))
                    "restoreGeofence" -> restoreGeofence(result)
                    "requestPermission" -> requestPermission(result)
                    "register" -> register(call, result)
                    "registerPlaces" -> registerPlaces(call, result)
                    "multiRegistrationStatus" -> result.success(multiRegistrationStatus())
                    "remove" -> remove(result)
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    eventSink = events
                    GeofenceEventBus.attach(this@MainActivity) { payload ->
                        runOnUiThread { eventSink?.success(payload) }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    GeofenceEventBus.detach()
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, locationMethodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> startPreciseLocation(result)
                    "stop" -> stopPreciseLocation(result)
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, locationEventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    locationEventSink = events
                    PreciseLocationService.handoffToForeground(this@MainActivity)
                    LocationEventBus.attach(this@MainActivity) { payload ->
                        runOnUiThread { locationEventSink?.success(payload) }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    locationEventSink = null
                    LocationEventBus.detach()
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PlatformRuntimeBridge.RUNTIME_CHANNEL)
            .setMethodCallHandler { call, result ->
                PlatformRuntimeBridge.handleRuntime(this, call, result)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PlaceDataBridge.CHANNEL)
            .setMethodCallHandler { call, result ->
                PlaceDataBridge.handle(this, call, result)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PlatformRuntimeBridge.NOTIFICATION_CHANNEL)
            .setMethodCallHandler { call, result ->
                ArrivalNotificationBridge.handle(this, this, call, result)
            }
        if (MultiPlaceGeofenceRegistration.hasDesired(this)) {
            MultiPlaceGeofenceRegistration.restore(this) { success, error ->
                if (!success) {
                    GeofenceRecovery.recordDiagnostic(this, "MULTI_GEOFENCE_STARTUP_FAILED ${error ?: "unknown"}")
                    // A failed multi-place recovery must not disable the last
                    // known-good legacy target.
                    restoreRegistration()
                }
            }
        } else restoreRegistration()
    }

    private fun startPreciseLocation(result: MethodChannel.Result) {
        if (permissionStatus() != "backgroundAllowed") {
            result.error("LOCATION_PERMISSION_MISSING", "Background location permission is required", permissionStatus())
            return
        }
        try {
            val intent = Intent(this, PreciseLocationService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ContextCompat.startForegroundService(this, intent)
            } else {
                startService(intent)
            }
            result.success(null)
        } catch (error: Exception) {
            result.error("LOCATION_SERVICE_FAILED", error.message, error.toString())
        }
    }

    private fun stopPreciseLocation(result: MethodChannel.Result) {
        stopService(Intent(this, PreciseLocationService::class.java).apply {
            action = PreciseLocationService.ACTION_STOP
        })
        result.success(null)
    }

    private fun permissionStatus(): String {
        val foreground = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!foreground) return "denied"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) != PackageManager.PERMISSION_GRANTED
        ) return "foregroundOnly"
        return "backgroundAllowed"
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (permissionStatus() == "denied") {
            permissionResult = result
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
                permissionRequestCode,
            )
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && permissionStatus() == "foregroundOnly") {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
            result.success(permissionStatus())
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            permissionResult = result
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION), permissionRequestCode)
        } else {
            result.success(permissionStatus())
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == permissionRequestCode) {
            permissionResult?.success(permissionStatus())
            permissionResult = null
        }
        ArrivalNotificationBridge.onRequestPermissionsResult(
            this,
            requestCode,
            permissions,
            grantResults,
        )
    }

    private fun register(call: MethodCall, result: MethodChannel.Result) {
        if (permissionStatus() != "backgroundAllowed") {
            result.error("PERMISSION_MISSING", "Background location permission is required", permissionStatus())
            return
        }
        val latitude = call.argument<Number>("latitude")?.toDouble()
        val longitude = call.argument<Number>("longitude")?.toDouble()
        val radius = call.argument<Number>("radius")?.toFloat()
        if (latitude == null || longitude == null || radius == null || radius <= 0) {
            result.error("INVALID_ARGUMENT", "Valid latitude, longitude, and radius are required", null)
            return
        }
        if (!latitude.isFinite() || latitude !in -90.0..90.0) {
            result.error("INVALID_COORDINATES", "Latitude must be between -90 and 90", null)
            return
        }
        if (!longitude.isFinite() || longitude !in -180.0..180.0) {
            result.error("INVALID_COORDINATES", "Longitude must be between -180 and 180", null)
            return
        }
        GeofenceRecovery.register(this, latitude, longitude, radius, call.argument<String>("reminderText")) { success, error ->
            runOnUiThread {
                if (success) result.success(null)
                else if (error?.startsWith("Desired geofence state:") == true) result.error("PERSISTENCE_FAILED", error, null)
                else result.error("GEOFENCE_REGISTRATION_FAILED", error, null)
            }
        }
    }

    private fun multiRegistrationStatus(): Map<String, Any?> {
        val preferences = getSharedPreferences("pingplace_multi_geofences", MODE_PRIVATE)
        return mapOf(
            "mode" to preferences.getBoolean("multi_mode", false),
            "confirmed" to preferences.getBoolean("registration_confirmed", false),
            "desiredPlaceIds" to (MultiPlaceGeofenceRegistration.desiredPlaceIds(this)),
        )
    }

    private fun registerPlaces(call: MethodCall, result: MethodChannel.Result) {
        if (permissionStatus() != "backgroundAllowed") {
            result.error("PERMISSION_MISSING", "Background location permission is required", permissionStatus())
            return
        }
        val raw = call.argument<List<Map<String, Any?>>>("places") ?: emptyList()
        val targets = raw.mapNotNull { item ->
            val id = item["placeId"] as? String
            val latitude = (item["latitude"] as? Number)?.toDouble()
            val longitude = (item["longitude"] as? Number)?.toDouble()
            val radius = (item["radius"] as? Number)?.toFloat()
            val innerRadius = (item["innerRadius"] as? Number)?.toFloat() ?: 80f
            val rearmRadius = (item["rearmRadius"] as? Number)?.toFloat() ?: 350f
            val cooldownSeconds = (item["cooldownSeconds"] as? Number)?.toLong() ?: 600L
            val approachTimeoutSeconds = (item["approachTimeoutSeconds"] as? Number)?.toLong() ?: 600L
            val maxAccuracy = (item["maxAcceptedAccuracy"] as? Number)?.toFloat() ?: 50f
            val reminderText = item["reminderText"] as? String
            if (id == null || latitude == null || longitude == null || radius == null) null
            else MultiPlaceGeofenceRegistration.Target(id, latitude, longitude, radius, innerRadius, rearmRadius, cooldownSeconds, approachTimeoutSeconds, maxAccuracy, reminderText)
        }
        if (targets.size != raw.size) {
            result.error("INVALID_ARGUMENT", "Every place must have an id, coordinates, and radius", null)
            return
        }
        MultiPlaceGeofenceRegistration.register(this, targets) { success, error ->
            runOnUiThread { if (success) result.success(null) else result.error("GEOFENCE_MULTI_RECONCILE_FAILED", error, null) }
        }
    }

    private fun remove(result: MethodChannel.Result) {
        GeofenceRecovery.remove(this) { success, error ->
            runOnUiThread {
                if (success) result.success(null)
                else if (error?.startsWith("Desired geofence state:") == true) result.error("PERSISTENCE_FAILED", error, null)
                else result.error("GEOFENCE_REMOVE_FAILED", error, null)
            }
        }
    }
    private fun restoreRegistration() {
        // A persisted confirmation is not proof that the platform still owns it.
        GeofenceRecovery.restore(this, "ui_startup") { success, _ ->
            if (!success) GeofenceRecovery.recordDiagnostic(this, "GEOFENCE_STARTUP_RECONCILIATION_FAILED")
        }
    }
    private fun restoreGeofence(result: MethodChannel.Result) {
        GeofenceRecovery.restore(this, "manual") { success, error ->
            if (success) result.success(true)
            else result.error("GEOFENCE_RECOVERY_FAILED", error, null)
        }
    }

    private fun desiredRegistrationDetails(): Map<String, Any?>? {
        val registration = GeofenceRecovery.readDesiredRegistration(this) ?: return null
        return mapOf(
            "latitude" to registration.latitude,
            "longitude" to registration.longitude,
            "radius" to registration.radius.toDouble(),
        )
    }

    private fun registrationDetails(): Map<String, Any?>? {
        val registration = GeofenceRecovery.readRegistration(this) ?: return null
        return mapOf(
            "latitude" to registration.latitude,
            "longitude" to registration.longitude,
            "radius" to registration.radius.toDouble(),
            "confirmed" to GeofenceRecovery.isRegistrationConfirmed(this),
        )
    }
}

