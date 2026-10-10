package com.example.pingplace

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import java.time.Instant

class PreciseLocationService : Service() {
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private var locationCallback: LocationCallback? = null
    private var backgroundEngine: FlutterEngine? = null
    private var backgroundControl: MethodChannel? = null
    private var backgroundReady = false
    private val pendingBackgroundEvents = mutableListOf<Map<String, Any?>>()
    private val watchdog = Handler(Looper.getMainLooper())
    private val watchdogStop = Runnable {
        recordDiagnostic("BACKGROUND_VERIFICATION_WATCHDOG_STOPPED")
        stopUpdates()
    }

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        instance = this
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopUpdates()
            ACTION_START_FROM_GEOFENCE -> {
                pendingBackgroundEvents.add(
                    mapOf(
                        "type" to "enter",
                        "targetLatitude" to intent.getDoubleExtra(EXTRA_TARGET_LATITUDE, Double.NaN),
                        "targetLongitude" to intent.getDoubleExtra(EXTRA_TARGET_LONGITUDE, Double.NaN),
                        "timestamp" to (intent.getStringExtra(EXTRA_TIMESTAMP) ?: Instant.now().toString()),
                    ),
                )
                startBackgroundEngine()
                startUpdates()
                watchdog.removeCallbacks(watchdogStop)
                watchdog.postDelayed(watchdogStop, BACKGROUND_WATCHDOG_MS)
            }
            ACTION_BACKGROUND_EVENT -> {
                pendingBackgroundEvents.add(
                    mapOf(
                        "type" to (intent.getStringExtra(EXTRA_EVENT_TYPE) ?: "error"),
                        "timestamp" to (intent.getStringExtra(EXTRA_TIMESTAMP) ?: Instant.now().toString()),
                        "error" to intent.getStringExtra(EXTRA_ERROR),
                    ),
                )
                flushBackgroundEvents()
            }
            else -> startUpdates()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        watchdog.removeCallbacks(watchdogStop)
        stopUpdates()
        backgroundControl = null
        backgroundEngine?.destroy()
        backgroundEngine = null
        instance = null
        isRunning = false
        super.onDestroy()
    }

    private fun startBackgroundEngine() {
        if (backgroundEngine != null) return
        val loader = FlutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationCompleteAsync(
            applicationContext,
            null,
            Handler(Looper.getMainLooper()),
        ) {
            val engine = FlutterEngine(applicationContext)
            val channel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                BACKGROUND_CONTROL_CHANNEL,
            )
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> {
                        backgroundReady = true
                        flushBackgroundEvents()
                        result.success(null)
                    }
                    "stop" -> {
                        result.success(null)
                        stopUpdates()
                    }
                    "diagnostic" -> {
                        recordDiagnostic(call.arguments as? String ?: "UNKNOWN_BACKGROUND_DIAGNOSTIC")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
            backgroundEngine = engine
            backgroundControl = channel
            engine.dartExecutor.executeDartEntrypoint(
                io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "package:pingplace/main.dart",
                    "backgroundMain",
                ),
            )
        }
    }

    private fun flushBackgroundEvents() {
        if (!backgroundReady) return
        val channel = backgroundControl ?: return
        while (pendingBackgroundEvents.isNotEmpty()) {
            channel.invokeMethod("event", pendingBackgroundEvents.removeAt(0))
        }
    }

    private fun sendBackgroundEvent(payload: Map<String, Any?>) {
        if (backgroundEngine == null) return
        pendingBackgroundEvents.add(payload)
        flushBackgroundEvents()
    }

    private fun recordDiagnostic(message: String) {
        val preferences = getSharedPreferences(BACKGROUND_PREFS, MODE_PRIVATE)
        val diagnostics = try {
            JSONArray(preferences.getString(BACKGROUND_DIAGNOSTICS, "[]"))
        } catch (_: Exception) {
            JSONArray()
        }
        diagnostics.put("${Instant.now()} $message")
        while (diagnostics.length() > MAX_DIAGNOSTICS) diagnostics.remove(0)
        preferences.edit().putString(BACKGROUND_DIAGNOSTICS, diagnostics.toString()).apply()
    }

    private fun startUpdates() {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PingPlace")
            .setContentText("Checking arrival location temporarily")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
        )
        if (locationCallback != null) return

        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 5_000L)
            .setMinUpdateIntervalMillis(2_000L)
            .setMaxUpdateDelayMillis(0L)
            .build()
        locationCallback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.locations.forEach { location ->
                    LocationEventBus.publish(
                        this@PreciseLocationService,
                        mapOf(
                            "type" to "location",
                            "latitude" to location.latitude,
                            "longitude" to location.longitude,
                            "accuracy" to location.accuracy.toDouble(),
                            "timestamp" to Instant.ofEpochMilli(location.time).toString(),
                            "error" to null,
                        ),
                    )
                    sendBackgroundEvent(
                        mapOf(
                            "type" to "location",
                            "latitude" to location.latitude,
                            "longitude" to location.longitude,
                            "accuracy" to location.accuracy.toDouble(),
                            "timestamp" to Instant.ofEpochMilli(location.time).toString(),
                        ),
                    )
                }
            }
        }
        try {
            fusedLocationClient.requestLocationUpdates(
                request,
                locationCallback!!,
                Looper.getMainLooper(),
            ).addOnFailureListener { error ->
                val message = error.message ?: error.toString()
                val payload = mapOf(
                    "type" to "error",
                    "timestamp" to Instant.now().toString(),
                    "error" to message,
                )
                LocationEventBus.publish(this, payload)
                sendBackgroundEvent(payload)
                stopSelf()
            }
        } catch (error: SecurityException) {
            val message = error.message ?: error.toString()
            val payload = mapOf(
                "type" to "error",
                "timestamp" to Instant.now().toString(),
                "error" to message,
            )
            LocationEventBus.publish(this, payload)
            sendBackgroundEvent(payload)
            stopSelf()
        }
    }

    private fun stopUpdates() {
        locationCallback?.let { fusedLocationClient.removeLocationUpdates(it) }
        locationCallback = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Temporary arrival verification",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    companion object {
        const val ACTION_STOP = "com.example.pingplace.STOP_PRECISE_LOCATION"
        const val ACTION_START_FROM_GEOFENCE = "com.example.pingplace.START_FROM_GEOFENCE"
        const val ACTION_BACKGROUND_EVENT = "com.example.pingplace.BACKGROUND_EVENT"
        const val EXTRA_TARGET_LATITUDE = "targetLatitude"
        const val EXTRA_TARGET_LONGITUDE = "targetLongitude"
        const val EXTRA_EVENT_TYPE = "eventType"
        const val EXTRA_TIMESTAMP = "timestamp"
        const val EXTRA_ERROR = "error"
        const val BACKGROUND_CONTROL_CHANNEL = "pingplace/background/control"
        private const val BACKGROUND_PREFS = "pingplace_background"
        private const val BACKGROUND_DIAGNOSTICS = "diagnostics"
        private const val MAX_DIAGNOSTICS = 200
        private const val BACKGROUND_WATCHDOG_MS = 11 * 60 * 1000L
        private const val CHANNEL_ID = "pingplace_precise_location"
        private const val NOTIFICATION_ID = 4203
        @Volatile
        var isRunning: Boolean = false
        private var instance: PreciseLocationService? = null

        fun handoffToForeground() {
            instance?.handoffToForeground()
        }

        fun startFromGeofence(context: android.content.Context, latitude: Double, longitude: Double) {
            val intent = Intent(context, PreciseLocationService::class.java).apply {
                action = ACTION_START_FROM_GEOFENCE
                putExtra(EXTRA_TARGET_LATITUDE, latitude)
                putExtra(EXTRA_TARGET_LONGITUDE, longitude)
                putExtra(EXTRA_TIMESTAMP, Instant.now().toString())
            }
            try {
                androidx.core.content.ContextCompat.startForegroundService(context, intent)
            } catch (error: Exception) {
                GeofenceEventBus.publish(
                    context,
                    "error",
                    "Unable to start background precise location: ${error.message ?: error}",
                )
            }
        }

        fun sendBackgroundEvent(
            context: android.content.Context,
            type: String,
            timestamp: String?,
            error: String?,
            latitude: Double?,
            longitude: Double?,
        ) {
            if (!isRunning) return
            val intent = Intent(context, PreciseLocationService::class.java).apply {
                action = ACTION_BACKGROUND_EVENT
                putExtra(EXTRA_EVENT_TYPE, type)
                putExtra(EXTRA_TIMESTAMP, timestamp ?: Instant.now().toString())
                putExtra(EXTRA_ERROR, error)
                if (latitude != null) putExtra("latitude", latitude)
                if (longitude != null) putExtra("longitude", longitude)
            }
            context.startService(intent)
        }
    }

    private fun handoffToForeground() {
        backgroundControl = null
        backgroundEngine?.destroy()
        backgroundEngine = null
        backgroundReady = false
        pendingBackgroundEvents.clear()
    }
}
