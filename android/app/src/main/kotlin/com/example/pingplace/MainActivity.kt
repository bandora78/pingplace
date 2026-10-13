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
                    "recoveryStatus" -> result.success(GeofenceRecovery.status(this))
                    "restoreGeofence" -> restoreGeofence(result)
                    "requestPermission" -> requestPermission(result)
                    "register" -> register(call, result)
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
                    PreciseLocationService.handoffToForeground()
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PlatformRuntimeBridge.NOTIFICATION_CHANNEL)
            .setMethodCallHandler { call, result ->
                ArrivalNotificationBridge.handle(this, this, call, result)
            }
        restoreRegistration()
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
        val latitude = (call.argument<Number>("latitude"))?.toDouble()
        val longitude = (call.argument<Number>("longitude"))?.toDouble()
        val radius = (call.argument<Number>("radius"))?.toFloat()
        if (latitude == null || longitude == null || radius == null || radius <= 0) {
            result.error("INVALID_ARGUMENT", "Valid latitude, longitude, and radius are required", null)
            return
        }
        if (!latitude.isFinite() || latitude < -90.0 || latitude > 90.0) {
            result.error("INVALID_COORDINATES", "Latitude must be between -90 and 90", latitude)
            return
        }
        if (!longitude.isFinite() || longitude < -180.0 || longitude > 180.0) {
            result.error("INVALID_COORDINATES", "Longitude must be between -180 and 180", longitude)
            return
        }
        val reminderText = call.argument<String>("reminderText") ?: "עצור בתחנת דלק יעד"
        try {
            GeofenceRecovery.configureDesiredRegistration(
                this,
                GeofenceRecovery.Registration(latitude, longitude, radius),
                reminderText,
            )
        } catch (persistenceError: Exception) {
            GeofenceRecovery.recordDiagnostic(this, "GEOFENCE_CONFIGURATION_PERSISTENCE_FAILED ${persistenceError.message ?: persistenceError}")
            result.error("PERSISTENCE_FAILED", "Saved geofence configuration could not be committed", null)
            return
        }
        if (permissionStatus() != "backgroundAllowed") {
            try {
                RegistrationRecordStore.updateState(this, RegistrationRecordStore.State.RECOVERY_BLOCKED)
            } catch (persistenceError: Exception) {
                GeofenceRecovery.recordDiagnostic(this, "GEOFENCE_CONFIGURATION_PERSISTENCE_FAILED ${persistenceError.message ?: persistenceError}")
            }
            result.error("PERMISSION_MISSING", "Background location permission is required", permissionStatus())
            return
        }
        GeofenceRecovery.restore(this, "register") { success, error ->
            // addGeofences(request, pendingIntent) is performed by the shared
            // GeofenceRecovery reconciliation path after durable persistence.
            runOnUiThread {
                if (success) result.success(null)
                else result.error("GEOFENCE_REGISTRATION_FAILED", error, null)
            }
        }
    }

    private fun remove(result: MethodChannel.Result) {
        // val pendingIntent = GeofencePendingIntent.get(this) and
        // removeGeofences(GeofencePendingIntent.get(this)) are performed by
        // GeofenceRecovery with the same stable PendingIntent identity.
        // removeGeofences(pendingIntent) is intentionally centralized there.
        GeofenceRecovery.remove(this) { success, error ->
            runOnUiThread {
                if (success) result.success(null)
                else result.error("GEOFENCE_REMOVE_FAILED", error, null)
            }
        }
    }

    private fun restoreRegistration() {
        GeofenceRecovery.restore(this, "ui_startup") { _, _ -> }
    }

    private fun restoreGeofence(result: MethodChannel.Result) {
        GeofenceRecovery.restore(this, "manual") { success, error ->
            if (success) result.success(true)
            else result.error("GEOFENCE_RECOVERY_FAILED", error, null)
        }
    }

    private fun registrationDetails(): Map<String, Any?>? {
        val registration = GeofenceRecovery.readRegistration(this) ?: return null
        return mapOf(
            "latitude" to registration.latitude,
            "longitude" to registration.longitude,
            "radius" to registration.radius.toDouble(),
            "confirmed" to GeofenceRecovery.isRegistrationConfirmed(this),
            "registrationState" to GeofenceRecovery.status(this)["registrationState"],
            "recoveryGeneration" to GeofenceRecovery.status(this)["recoveryGeneration"],
            "reminderText" to GeofenceRecovery.status(this)["reminderText"],
        )
    }
}
