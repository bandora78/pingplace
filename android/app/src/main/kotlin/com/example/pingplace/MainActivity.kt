package com.example.pingplace

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val methodChannelName = "pingplace/geofence"
    private val eventChannelName = "pingplace/geofence/events"
    private val geofenceId = "pingplace-phase0-outer"
    private val permissionRequestCode = 4201
    private var permissionResult: MethodChannel.Result? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkPermission" -> result.success(permissionStatus())
                    "registrationStatus" -> result.success(getPreferences(MODE_PRIVATE).contains("geofence_latitude"))
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
        restoreRegistration()
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
    }

    private fun register(call: MethodCall, result: MethodChannel.Result) {
        if (permissionStatus() != "backgroundAllowed") {
            result.error("PERMISSION_MISSING", "Background location permission is required", permissionStatus())
            return
        }
        val latitude = (call.argument<Number>("latitude"))?.toDouble()
        val longitude = (call.argument<Number>("longitude"))?.toDouble()
        val radius = (call.argument<Number>("radius"))?.toFloat()
        if (latitude == null || longitude == null || radius == null || radius <= 0) {
            result.error("INVALID_ARGUMENT", "Valid latitude, longitude, and radius are required", null)
            return
        }
        val pendingIntent = GeofencePendingIntent.get(this)
        val geofence = Geofence.Builder()
            .setRequestId(geofenceId)
            .setCircularRegion(latitude, longitude, radius)
            .setExpirationDuration(Geofence.NEVER_EXPIRE)
            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT)
            .build()
        val request = GeofencingRequest.Builder()
            .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
            .addGeofence(geofence)
            .build()
        LocationServices.getGeofencingClient(this).removeGeofences(pendingIntent).addOnCompleteListener {
            LocationServices.getGeofencingClient(this).addGeofences(request, pendingIntent)
                .addOnSuccessListener {
                    getPreferences(MODE_PRIVATE).edit()
                        .putString("geofence_latitude", latitude.toString())
                        .putString("geofence_longitude", longitude.toString())
                        .putString("geofence_radius", radius.toString())
                        .apply()
                    result.success(null)
                }
                .addOnFailureListener { error -> result.error("GEOFENCE_REGISTRATION_FAILED", error.message, error.toString()) }
        }
    }

    private fun remove(result: MethodChannel.Result) {
        LocationServices.getGeofencingClient(this).removeGeofences(GeofencePendingIntent.get(this))
            .addOnSuccessListener {
                getPreferences(MODE_PRIVATE).edit()
                    .remove("geofence_latitude")
                    .remove("geofence_longitude")
                    .remove("geofence_radius")
                    .apply()
                result.success(null)
            }
            .addOnFailureListener { error -> result.error("GEOFENCE_REMOVE_FAILED", error.message, error.toString()) }
    }

    private fun restoreRegistration() {
        if (permissionStatus() != "backgroundAllowed") return
        val preferences = getPreferences(MODE_PRIVATE)
        val latitude = preferences.getString("geofence_latitude", null)?.toDoubleOrNull() ?: return
        val longitude = preferences.getString("geofence_longitude", null)?.toDoubleOrNull() ?: return
        val radius = preferences.getString("geofence_radius", null)?.toFloatOrNull() ?: return
        val geofence = Geofence.Builder()
            .setRequestId(geofenceId)
            .setCircularRegion(latitude, longitude, radius)
            .setExpirationDuration(Geofence.NEVER_EXPIRE)
            .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT)
            .build()
        val request = GeofencingRequest.Builder()
            .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
            .addGeofence(geofence)
            .build()
        val pendingIntent = GeofencePendingIntent.get(this)
        LocationServices.getGeofencingClient(this).removeGeofences(pendingIntent).addOnCompleteListener {
            LocationServices.getGeofencingClient(this).addGeofences(request, pendingIntent)
        }
    }
}
