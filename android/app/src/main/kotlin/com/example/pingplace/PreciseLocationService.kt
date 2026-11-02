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
    private var backgroundEngineStarting = false
    private val pendingBackgroundEvents = mutableListOf<Map<String, Any?>>()
    private val activePlaceIds = linkedSetOf<String>()
    private var lastStartId = 0
    private var updatesStartedAtMillis = 0L
    private var firstFixLogged = false
    private var droppedSampleLogged = false
    private var watchdogDeadline: Long? = null
    private var engineStartedAtMillis = 0L
    private val engineReadyCheck = Runnable {
        if (!backgroundReady) {
            // The Dart side never completed its handshake: nothing queued for
            // it (ENTER, fixes, EXIT) can be evaluated. Never fail silently.
            recordDiagnostic(
                "BACKGROUND_ENGINE_NOT_READY after=${System.currentTimeMillis() - engineStartedAtMillis}ms " +
                    "queued=${pendingBackgroundEvents.size} places=${activePlaceIds.joinToString(",", "[", "]")}",
            )
        }
    }
    private val watchdog = Handler(Looper.getMainLooper())
    private val watchdogStop = Runnable {
        watchdogDeadline = null
        recordDiagnostic("BACKGROUND_VERIFICATION_WATCHDOG_STOPPED places=${activePlaceIds.joinToString(",", "[", "]")}")
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
        lastStartId = startId
        when (intent?.action) {
            ACTION_STOP -> stopUpdates()
            ACTION_START_FROM_GEOFENCE -> {
                recordDiagnostic("PRECISE_LOCATION_START_REQUESTED place=${intent.getStringExtra(EXTRA_PLACE_ID) ?: "legacy"}")
                intent.getStringExtra(EXTRA_PLACE_ID)?.let { activePlaceIds.add(it) }
                pendingBackgroundEvents.add(
                    mapOf(
                        "type" to "enter",
                        "targetLatitude" to intent.getDoubleExtra(EXTRA_TARGET_LATITUDE, Double.NaN),
                        "targetLongitude" to intent.getDoubleExtra(EXTRA_TARGET_LONGITUDE, Double.NaN),
                        "timestamp" to (intent.getStringExtra(EXTRA_TIMESTAMP) ?: Instant.now().toString()),
                        "placeId" to intent.getStringExtra(EXTRA_PLACE_ID),
                        "outerRadius" to intent.getDoubleExtra(EXTRA_OUTER_RADIUS, 300.0),
                        "innerRadius" to intent.getDoubleExtra(EXTRA_INNER_RADIUS, 80.0),
                        "rearmRadius" to intent.getDoubleExtra(EXTRA_REARM_RADIUS, 350.0),
                        "cooldownSeconds" to intent.getLongExtra(EXTRA_COOLDOWN_SECONDS, 600L),
                        "approachTimeoutSeconds" to intent.getLongExtra(EXTRA_APPROACH_TIMEOUT_SECONDS, 600L),
                        "maxAcceptedAccuracy" to intent.getDoubleExtra(EXTRA_MAX_ACCURACY, 50.0),
                        "reminderText" to intent.getStringExtra(EXTRA_REMINDER_TEXT),
                    ),
                )
                startBackgroundEngine()
                startUpdates()
                armWatchdog(BACKGROUND_WATCHDOG_MS)
            }
            ACTION_BACKGROUND_EVENT -> {
                recordDiagnostic("BACKGROUND_EVENT_QUEUED type=${intent.getStringExtra(EXTRA_EVENT_TYPE) ?: "error"} place=${intent.getStringExtra(EXTRA_PLACE_ID) ?: "legacy"}")
                val placeId = intent.getStringExtra(EXTRA_PLACE_ID)
                if (placeId != null) activePlaceIds.add(placeId)
                val event = mutableMapOf<String, Any?>(
                    "type" to (intent.getStringExtra(EXTRA_EVENT_TYPE) ?: "error"),
                    "timestamp" to (intent.getStringExtra(EXTRA_TIMESTAMP) ?: Instant.now().toString()),
                    "error" to intent.getStringExtra(EXTRA_ERROR),
                    "placeId" to placeId,
                )
                if (intent.hasExtra(EXTRA_TARGET_LATITUDE) && intent.hasExtra(EXTRA_TARGET_LONGITUDE)) {
                    event["targetLatitude"] = intent.getDoubleExtra(EXTRA_TARGET_LATITUDE, Double.NaN)
                    event["targetLongitude"] = intent.getDoubleExtra(EXTRA_TARGET_LONGITUDE, Double.NaN)
                    event["outerRadius"] = intent.getDoubleExtra(EXTRA_OUTER_RADIUS, 300.0)
                    event["innerRadius"] = intent.getDoubleExtra(EXTRA_INNER_RADIUS, 80.0)
                    event["rearmRadius"] = intent.getDoubleExtra(EXTRA_REARM_RADIUS, 350.0)
                    event["cooldownSeconds"] = intent.getLongExtra(EXTRA_COOLDOWN_SECONDS, 600L)
                    event["approachTimeoutSeconds"] = intent.getLongExtra(EXTRA_APPROACH_TIMEOUT_SECONDS, 600L)
                    event["maxAcceptedAccuracy"] = intent.getDoubleExtra(EXTRA_MAX_ACCURACY, 50.0)
                }
                pendingBackgroundEvents.add(event)
                startForegroundShell()
                armWatchdog(REARM_WATCHDOG_MS)
                startBackgroundEngine()
                flushBackgroundEvents()
            }
            else -> startUpdates()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        watchdog.removeCallbacks(watchdogStop)
        watchdog.removeCallbacks(engineReadyCheck)
        watchdogDeadline = null
        stopUpdates()
        backgroundControl = null
        backgroundEngine?.destroy()
        backgroundEngine = null
        instance = null
        isRunning = false
        super.onDestroy()
    }

    private fun startBackgroundEngine() {
        if (backgroundEngine != null || backgroundEngineStarting) return
        backgroundEngineStarting = true
        engineStartedAtMillis = System.currentTimeMillis()
        recordDiagnostic("BACKGROUND_ENGINE_STARTING")
        watchdog.postDelayed(engineReadyCheck, VerificationPolicy.ENGINE_READY_TIMEOUT_MS)
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
                        watchdog.removeCallbacks(engineReadyCheck)
                        recordDiagnostic(
                            "BACKGROUND_ENGINE_READY after=${System.currentTimeMillis() - engineStartedAtMillis}ms " +
                                "queued=${pendingBackgroundEvents.size}",
                        )
                        backgroundReady = true
                        flushBackgroundEvents()
                        result.success(null)
                    }
                    "stop" -> {
                        result.success(null)
                        stopUpdates(stopService = true)
                    }
                    "stopPlace" -> {
                        result.success(null)
                        val placeId = call.arguments as? String
                        if (placeId == null) {
                            stopUpdates(stopService = true)
                        } else {
                            val decision = VerificationPolicy.stopPlace(activePlaceIds, placeId)
                            activePlaceIds.remove(placeId)
                            if (decision.stopService) {
                                recordDiagnostic("PLACE_VERIFICATION_STOPPED place=$placeId service=STOPPING")
                                stopUpdates(stopService = true)
                            } else {
                                recordDiagnostic("PLACE_VERIFICATION_STOPPED place=$placeId service=KEPT_FOR ${decision.remaining.joinToString(",", "[", "]")}")
                            }
                        }
                    }
                    "stopLocation" -> {
                        result.success(null)
                        stopUpdates(stopService = false)
                    }
                    "startVerification" -> {
                        result.success(null)
                        (call.arguments as? String)?.let { activePlaceIds.add(it) }
                        armWatchdog(REARM_WATCHDOG_MS)
                        startUpdates()
                    }
                    "diagnostic" -> {
                        recordDiagnostic(call.arguments as? String ?: "UNKNOWN_BACKGROUND_DIAGNOSTIC")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                PlatformRuntimeBridge.RUNTIME_CHANNEL,
            ).setMethodCallHandler { call, result ->
                PlatformRuntimeBridge.handleRuntime(this, call, result)
            }
            MethodChannel(
                engine.dartExecutor.binaryMessenger,
                PlatformRuntimeBridge.NOTIFICATION_CHANNEL,
            ).setMethodCallHandler { call, result ->
                ArrivalNotificationBridge.handle(this, null, call, result)
            }
            backgroundEngine = engine
            backgroundEngineStarting = false
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
        // Build 17 dropped every sample that arrived before the engine
        // existed; on a short visit that can be the only useful fix.
        if (!VerificationPolicy.shouldQueueSample(backgroundEngine != null, backgroundEngineStarting)) {
            if (!droppedSampleLogged) {
                droppedSampleLogged = true
                recordDiagnostic("BACKGROUND_SAMPLE_NOT_ROUTED reason=NO_BACKGROUND_ENGINE type=${payload["type"]}")
            }
            return
        }
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
        startForegroundShell()
        if (locationCallback != null) return
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, VerificationPolicy.INTERVAL_MS)
            .setMinUpdateIntervalMillis(VerificationPolicy.MIN_INTERVAL_MS)
            .setMaxUpdateDelayMillis(0L)
            .build()
        updatesStartedAtMillis = System.currentTimeMillis()
        firstFixLogged = false
        locationCallback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.locations.forEach { location ->
                    if (!firstFixLogged) {
                        firstFixLogged = true
                        recordDiagnostic(
                            "FIRST_LOCATION_SAMPLE after=${System.currentTimeMillis() - updatesStartedAtMillis}ms " +
                                "accuracy=${location.accuracy}m places=${activePlaceIds.joinToString(",", "[", "]")}",
                        )
                    }
                    val ids = activePlaceIds.toList().ifEmpty { listOf<String?>(null) }
                    ids.forEach { placeId ->
                        val payload = mapOf<String, Any?>(
                            "type" to "location",
                            "latitude" to location.latitude,
                            "longitude" to location.longitude,
                            "accuracy" to location.accuracy.toDouble(),
                            "timestamp" to Instant.ofEpochMilli(location.time).toString(),
                            "error" to null,
                            "placeId" to placeId,
                        )
                        LocationEventBus.publish(this@PreciseLocationService, payload)
                        sendBackgroundEvent(payload)
                    }
                }
            }
        }
        try {
            fusedLocationClient.requestLocationUpdates(
                request,
                locationCallback!!,
                Looper.getMainLooper(),
            ).addOnSuccessListener {
                recordDiagnostic("PRECISE_LOCATION_UPDATES_STARTED")
            }.addOnFailureListener { error ->
                recordDiagnostic("PRECISE_LOCATION_START_FAILED ${error.message ?: error}")
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

    private fun armWatchdog(delayMillis: Long) {
        val now = System.currentTimeMillis()
        val deadline = VerificationPolicy.extendedDeadline(watchdogDeadline, now, delayMillis)
        watchdogDeadline = deadline
        watchdog.removeCallbacks(watchdogStop)
        watchdog.postDelayed(watchdogStop, deadline - now)
    }

    private fun startForegroundShell() {
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
    }

    private fun stopUpdates(stopService: Boolean = true) {
        if (locationCallback != null) recordDiagnostic("PRECISE_LOCATION_STOPPED_NATIVE")
        locationCallback?.let { fusedLocationClient.removeLocationUpdates(it) }
        locationCallback = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        // stopSelf(startId) leaves the service running if a newer start (for
        // example another place's ENTER) is already queued.
        if (stopService) stopSelf(lastStartId)
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
        const val EXTRA_PLACE_ID = "placeId"
        const val EXTRA_OUTER_RADIUS = "outerRadius"
        const val EXTRA_INNER_RADIUS = "innerRadius"
        const val EXTRA_REARM_RADIUS = "rearmRadius"
        const val EXTRA_COOLDOWN_SECONDS = "cooldownSeconds"
        const val EXTRA_APPROACH_TIMEOUT_SECONDS = "approachTimeoutSeconds"
        const val EXTRA_MAX_ACCURACY = "maxAcceptedAccuracy"
        const val EXTRA_REMINDER_TEXT = "reminderText"
        const val BACKGROUND_CONTROL_CHANNEL = "pingplace/background/control"
        private const val BACKGROUND_PREFS = "pingplace_background"
        private const val BACKGROUND_DIAGNOSTICS = "diagnostics"
        // A 10-minute approach at one fix per 2 s must not push its ENTER out.
        private const val MAX_DIAGNOSTICS = 500
        private const val BACKGROUND_WATCHDOG_MS = 11 * 60 * 1000L
        private const val REARM_WATCHDOG_MS = 2 * 60 * 1000L
        private const val CHANNEL_ID = "pingplace_precise_location"
        private const val NOTIFICATION_ID = 4203
        @Volatile
        var isRunning: Boolean = false
        private var instance: PreciseLocationService? = null

        fun handoffToForeground(context: android.content.Context) {
            // Multi-place verification remains owned by the headless service while
            // the UI is attached; only legacy monitoring is handed off.
            if (MultiPlaceGeofenceRegistration.isMultiMode(context)) return
            instance?.handoffToForeground()
        }

        fun startFromGeofence(context: android.content.Context, target: MultiPlaceGeofenceRegistration.Target) {
            startFromGeofence(context, target.latitude, target.longitude, target)
        }

        fun startFromGeofence(
            context: android.content.Context,
            latitude: Double,
            longitude: Double,
            target: MultiPlaceGeofenceRegistration.Target?,
        ) {
            val intent = Intent(context, PreciseLocationService::class.java).apply {
                action = ACTION_START_FROM_GEOFENCE
                putExtra(EXTRA_TARGET_LATITUDE, latitude)
                putExtra(EXTRA_TARGET_LONGITUDE, longitude)
                putExtra(EXTRA_TIMESTAMP, Instant.now().toString())
                target?.let {
                    putExtra(EXTRA_PLACE_ID, it.placeId)
                    putExtra(EXTRA_OUTER_RADIUS, it.radius.toDouble())
                    putExtra(EXTRA_INNER_RADIUS, it.innerRadius.toDouble())
                    putExtra(EXTRA_REARM_RADIUS, it.rearmRadius.toDouble())
                    putExtra(EXTRA_COOLDOWN_SECONDS, it.cooldownSeconds)
                    putExtra(EXTRA_APPROACH_TIMEOUT_SECONDS, it.approachTimeoutSeconds)
                    putExtra(EXTRA_MAX_ACCURACY, it.maxAcceptedAccuracy.toDouble())
                    putExtra(EXTRA_REMINDER_TEXT, it.reminderText)
                }
            }
            try {
                androidx.core.content.ContextCompat.startForegroundService(context, intent)
            } catch (error: Exception) {
                // For example ForegroundServiceStartNotAllowedException under a
                // background or battery restriction: the arrival cannot be verified.
                GeofenceRecovery.recordDiagnostic(
                    context,
                    "PRECISE_LOCATION_START_BLOCKED place=${target?.placeId ?: "legacy"} error=${error.javaClass.simpleName}",
                )
                GeofenceEventBus.publish(context, "error", "Unable to start background precise location", target?.placeId)
            }
        }

        fun sendBackgroundEvent(
            context: android.content.Context,
            type: String,
            timestamp: String?,
            error: String?,
            latitude: Double?,
            longitude: Double?,
            placeId: String?,
            target: MultiPlaceGeofenceRegistration.Target? = null,
        ) {
            val intent = Intent(context, PreciseLocationService::class.java).apply {
                action = ACTION_BACKGROUND_EVENT
                putExtra(EXTRA_EVENT_TYPE, type)
                putExtra(EXTRA_TIMESTAMP, timestamp ?: Instant.now().toString())
                putExtra(EXTRA_ERROR, error)
                if (latitude != null) putExtra("latitude", latitude)
                if (longitude != null) putExtra("longitude", longitude)
                if (placeId != null) putExtra(EXTRA_PLACE_ID, placeId)
                // An EXIT usually arrives in a new background process. The place's
                // configuration lets it re-arm with the right radii.
                target?.let {
                    putExtra(EXTRA_TARGET_LATITUDE, it.latitude)
                    putExtra(EXTRA_TARGET_LONGITUDE, it.longitude)
                    putExtra(EXTRA_OUTER_RADIUS, it.radius.toDouble())
                    putExtra(EXTRA_INNER_RADIUS, it.innerRadius.toDouble())
                    putExtra(EXTRA_REARM_RADIUS, it.rearmRadius.toDouble())
                    putExtra(EXTRA_COOLDOWN_SECONDS, it.cooldownSeconds)
                    putExtra(EXTRA_APPROACH_TIMEOUT_SECONDS, it.approachTimeoutSeconds)
                    putExtra(EXTRA_MAX_ACCURACY, it.maxAcceptedAccuracy.toDouble())
                }
            }
            try {
                if (isRunning) {
                    context.startService(intent)
                } else {
                    androidx.core.content.ContextCompat.startForegroundService(context, intent)
                }
            } catch (error: Exception) {
                GeofenceRecovery.recordDiagnostic(
                    context,
                    "BACKGROUND_EVENT_START_BLOCKED type=$type place=${placeId ?: "legacy"} error=${error.javaClass.simpleName}",
                )
                GeofenceEventBus.publish(
                    context,
                    "error",
                    "Unable to start background event processing: ${error.message ?: error}",
                )
            }
        }
    }

    private fun handoffToForeground() {
        backgroundControl = null
        backgroundEngine?.destroy()
        backgroundEngine = null
        backgroundEngineStarting = false
        backgroundReady = false
        pendingBackgroundEvents.clear()
    }
}
