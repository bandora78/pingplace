package com.example.pingplace

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
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

/** One startForegroundService call: elapsed-realtime bounds and the refusal, if any. */
data class GeofenceStartAttempt(val invokedAt: Long, val returnedAt: Long, val failure: String?)

class PreciseLocationService : Service() {
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private var locationCallback: LocationCallback? = null
    private var backgroundEngine: FlutterEngine? = null
    private var backgroundControl: MethodChannel? = null
    private var backgroundReady = false
    private var backgroundEngineStarting = false
    private val pendingBackgroundEvents = mutableListOf<Map<String, Any?>>()
    private val activePlaceIds = linkedSetOf<String>()
    // Events handed to Dart that it has not finished handling.
    private var inFlightEvents = 0
    private var stopDeferred = false
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
            ACTION_START_FROM_GEOFENCE -> handleGeofenceStart(intent)
            ACTION_BACKGROUND_EVENT -> handleBackgroundEvent(intent)
            else -> startUpdates()
        }
        return START_NOT_STICKY
    }

    /**
     * APP-10E: one start for every place of an ENTER callback. Promote to the
     * foreground first, then read and validate the configuration; a place
     * that is not registered never gets GPS.
     */
    private fun handleGeofenceStart(intent: Intent) {
        val placeIds = intent.getStringArrayListExtra(EXTRA_PLACE_IDS).orEmpty()
        val receivedAt = intent.getLongExtra(EXTRA_RECEIVED_ELAPSED, SystemClock.elapsedRealtime())
        val promotion = promoteToForeground()
        if (promotion != null) {
            // Never verifying without the foreground service: log, request
            // recovery and stop (the system requires startForeground or stop).
            val recoveries = EnterRecovery.recordBlocked(
                this,
                placeIds.map { it.takeUnless { id -> id == PlaceDiagnostics.LEGACY_ID } },
                promotion,
                EnterStartRecovery.Stage.PROMOTION,
                SystemClock.elapsedRealtime() - receivedAt,
            )
            if (recoveries.isNotEmpty()) EnterRecovery.request(this, recoveries, receivedAt) { }
            stopIfIdle()
            return
        }
        recordDiagnostic(
            "FOREGROUND_PROMOTED sinceReceive=${SystemClock.elapsedRealtime() - receivedAt}ms " +
                "places=${placeIds.joinToString(",", "[", "]")}",
        )
        val readStart = SystemClock.elapsedRealtime()
        val resolution = EnterStartRecovery.resolve(
            placeIds,
            MultiPlaceGeofenceRegistration.targets(this),
            legacyTarget(),
        )
        recordDiagnostic(
            "GEOFENCE_TARGETS_READ took=${SystemClock.elapsedRealtime() - readStart}ms " +
                "resolved=${resolution.resolved.size} unknown=${resolution.unknown.joinToString(",", "[", "]")}",
        )
        resolution.unknown.forEach { recordDiagnostic("PRECISE_LOCATION_TARGET_UNKNOWN place=$it") }
        if (resolution.legacyTargetMissing) {
            GeofenceEventBus.publish(this, "error", "Target coordinates are not persisted", null)
        }
        if (resolution.resolved.isEmpty()) {
            stopIfIdle()
            return
        }
        val timestamp = intent.getStringExtra(EXTRA_TIMESTAMP) ?: Instant.now().toString()
        resolution.resolved.forEach { place ->
            recordDiagnostic(
                "PRECISE_LOCATION_START_REQUESTED place=${place.placeId ?: "legacy"} " +
                    "sinceReceive=${SystemClock.elapsedRealtime() - receivedAt}ms",
            )
            place.placeId?.let { activePlaceIds.add(it) }
            pendingBackgroundEvents.add(
                mapOf(
                    "type" to "enter",
                    "targetLatitude" to place.latitude,
                    "targetLongitude" to place.longitude,
                    "timestamp" to timestamp,
                    "placeId" to place.placeId,
                    "outerRadius" to (place.target?.radius?.toDouble() ?: 300.0),
                    "innerRadius" to (place.target?.innerRadius?.toDouble() ?: 80.0),
                    "rearmRadius" to (place.target?.rearmRadius?.toDouble() ?: 350.0),
                    "cooldownSeconds" to (place.target?.cooldownSeconds ?: 600L),
                    "approachTimeoutSeconds" to (place.target?.approachTimeoutSeconds ?: 600L),
                    "maxAcceptedAccuracy" to (place.target?.maxAcceptedAccuracy?.toDouble() ?: 50.0),
                    "reminderText" to place.target?.reminderText,
                ),
            )
        }
        startBackgroundEngine()
        startUpdates()
        armWatchdog(BACKGROUND_WATCHDOG_MS)
    }

    private fun handleBackgroundEvent(intent: Intent) {
        val type = intent.getStringExtra(EXTRA_EVENT_TYPE) ?: "error"
        val placeIds = intent.getStringArrayListExtra(EXTRA_PLACE_IDS)
        val promotion = promoteToForeground()
        if (promotion != null) {
            recordDiagnostic(
                "BACKGROUND_EVENT_START_BLOCKED stage=PROMOTION type=$type " +
                    "places=${(placeIds ?: listOfNotNull(intent.getStringExtra(EXTRA_PLACE_ID))).joinToString(",", "[", "]")} " +
                    "error=$promotion",
            )
            stopIfIdle()
            return
        }
        val timestamp = intent.getStringExtra(EXTRA_TIMESTAMP) ?: Instant.now().toString()
        // APP-10D: an EXIT (or error) does not by itself need fixes. Build 19
        // added the place here, so an ARMED place kept receiving fixes it
        // ignored and kept GPS running after every other place had finished,
        // until the watchdog. The Dart session asks with startVerification
        // when it must measure the exit distance.
        val events = if (placeIds != null) {
            val targets = MultiPlaceGeofenceRegistration.targets(this)
            placeIds.map { id ->
                val placeId = id.takeUnless { it == PlaceDiagnostics.LEGACY_ID }
                mutableMapOf<String, Any?>(
                    "type" to type,
                    "timestamp" to timestamp,
                    "error" to null,
                    "placeId" to placeId,
                ).also { event ->
                    // The place's configuration lets it re-arm with the right radii.
                    targets.firstOrNull { it.placeId == id }?.let { target ->
                        event["targetLatitude"] = target.latitude
                        event["targetLongitude"] = target.longitude
                        event["outerRadius"] = target.radius.toDouble()
                        event["innerRadius"] = target.innerRadius.toDouble()
                        event["rearmRadius"] = target.rearmRadius.toDouble()
                        event["cooldownSeconds"] = target.cooldownSeconds
                        event["approachTimeoutSeconds"] = target.approachTimeoutSeconds
                        event["maxAcceptedAccuracy"] = target.maxAcceptedAccuracy.toDouble()
                    }
                }
            }
        } else {
            listOf(
                mutableMapOf<String, Any?>(
                    "type" to type,
                    "timestamp" to timestamp,
                    "error" to intent.getStringExtra(EXTRA_ERROR),
                    "placeId" to intent.getStringExtra(EXTRA_PLACE_ID),
                ),
            )
        }
        events.forEach { event ->
            recordDiagnostic("BACKGROUND_EVENT_QUEUED type=$type place=${event["placeId"] ?: "legacy"}")
            pendingBackgroundEvents.add(event)
        }
        armWatchdog(REARM_WATCHDOG_MS)
        startBackgroundEngine()
        flushBackgroundEvents()
    }

    private fun legacyTarget(): Pair<Double, Double>? {
        val preferences = getSharedPreferences(GeofenceEventBus.PREFS, MODE_PRIVATE)
        val latitude = preferences.getString("target_latitude", null)?.toDoubleOrNull()
        val longitude = preferences.getString("target_longitude", null)?.toDoubleOrNull()
        return if (latitude != null && longitude != null) latitude to longitude else null
    }

    /** Stops the service unless a place is verifying or Dart still has events to handle. */
    private fun stopIfIdle() {
        val decision = VerificationPolicy.stopPlace(activePlaceIds, "", eventsInProgress())
        if (decision.stopService) stopUpdates(stopService = true)
        else if (decision.deferStop) stopDeferred = true
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
                            val decision = VerificationPolicy.stopPlace(activePlaceIds, placeId, eventsInProgress())
                            activePlaceIds.remove(placeId)
                            if (decision.stopService) {
                                recordDiagnostic("PLACE_VERIFICATION_STOPPED place=$placeId service=STOPPING")
                                stopUpdates(stopService = true)
                            } else if (decision.deferStop) {
                                // No place needs fixes: GPS off now, the service
                                // once Dart has handled every queued event.
                                recordDiagnostic("PLACE_VERIFICATION_STOPPED place=$placeId service=STOPPING_AFTER_EVENTS events=${eventsInProgress()}")
                                stopLocationUpdatesOnly()
                                stopDeferred = true
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
            inFlightEvents++
            channel.invokeMethod(
                "event",
                pendingBackgroundEvents.removeAt(0),
                object : MethodChannel.Result {
                    override fun success(result: Any?) = eventHandled()
                    override fun error(code: String, message: String?, details: Any?) = eventHandled()
                    override fun notImplemented() = eventHandled()
                },
            )
        }
    }

    private fun eventsInProgress(): Int = inFlightEvents + pendingBackgroundEvents.size

    private fun eventHandled() {
        inFlightEvents = maxOf(0, inFlightEvents - 1)
        if (!stopDeferred) return
        if (activePlaceIds.isNotEmpty()) {
            // A place started verifying meanwhile; its own stop decides.
            stopDeferred = false
        } else if (VerificationPolicy.runDeferredStop(stopDeferred, activePlaceIds, eventsInProgress())) {
            recordDiagnostic("BACKGROUND_SERVICE_STOPPING after queued events")
            stopUpdates(stopService = true)
        }
    }

    private fun stopLocationUpdatesOnly() {
        if (locationCallback != null) recordDiagnostic("PRECISE_LOCATION_STOPPED_NATIVE")
        locationCallback?.let { fusedLocationClient.removeLocationUpdates(it) }
        locationCallback = null
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

    private fun recordDiagnostic(message: String) = recordPipelineDiagnostic(this, message)

    private fun startUpdates() {
        promoteToForeground()?.let { error ->
            // GPS only ever runs inside the foreground service.
            recordDiagnostic("PRECISE_LOCATION_NOT_STARTED reason=FOREGROUND_PROMOTION_FAILED error=$error")
            stopIfIdle()
            return
        }
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

    /**
     * Null once the service is in the foreground; otherwise the exception's
     * simple name. APP-10E: Android can refuse the promotion
     * (ForegroundServiceStartNotAllowedException, or SecurityException for
     * the location type); unguarded, that crashed the process and every
     * place verifying in it.
     */
    private fun promoteToForeground(): String? {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PingPlace")
            .setContentText("Checking arrival location temporarily")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
        return try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
            null
        } catch (error: Exception) {
            recordDiagnostic("FOREGROUND_PROMOTION_FAILED error=${error.javaClass.simpleName}")
            error.javaClass.simpleName
        }
    }

    private fun stopUpdates(stopService: Boolean = true) {
        if (stopService) stopDeferred = false
        stopLocationUpdatesOnly()
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
        const val EXTRA_PLACE_IDS = "placeIds"
        const val EXTRA_RECEIVED_ELAPSED = "receivedElapsedRealtime"
        const val BACKGROUND_CONTROL_CHANNEL = "pingplace/background/control"
        const val BACKGROUND_PREFS = "pingplace_background"
        const val BACKGROUND_DIAGNOSTICS = "diagnostics"
        // Bounded at DiagnosticRetention.MAX_ENTRIES; routine lines go first.
        const val EVICTED_ROUTINE = "diagnostics_evicted_routine"
        const val EVICTED_CRITICAL = "diagnostics_evicted_critical"
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

        /**
         * APP-10E: one start for every place of an ENTER callback, built from
         * the platform's request IDs only (no storage access), so it runs
         * while the geofence exemption is still open. The service validates
         * the IDs once it is in the foreground.
         */
        fun startFromGeofence(context: android.content.Context, placeIds: List<String>, receivedAt: Long): GeofenceStartAttempt =
            startGeofenceIntent(context, ACTION_START_FROM_GEOFENCE, "enter", placeIds, receivedAt)

        /**
         * EXITs of one callback in one start. Always startForegroundService:
         * Build 20 used startService while isRunning was still true for a
         * service that had already begun stopping, which Android refuses
         * from the background.
         */
        fun sendExitEvents(context: android.content.Context, placeIds: List<String>, receivedAt: Long): GeofenceStartAttempt =
            startGeofenceIntent(context, ACTION_BACKGROUND_EVENT, "exit", placeIds, receivedAt)

        private fun startGeofenceIntent(
            context: android.content.Context,
            action: String,
            type: String,
            placeIds: List<String>,
            receivedAt: Long,
        ): GeofenceStartAttempt {
            val intent = Intent(context, PreciseLocationService::class.java).apply {
                this.action = action
                putExtra(EXTRA_EVENT_TYPE, type)
                putStringArrayListExtra(EXTRA_PLACE_IDS, ArrayList(placeIds))
                putExtra(EXTRA_RECEIVED_ELAPSED, receivedAt)
                putExtra(EXTRA_TIMESTAMP, Instant.now().toString())
            }
            val invokedAt = SystemClock.elapsedRealtime()
            val failure = try {
                androidx.core.content.ContextCompat.startForegroundService(context, intent)
                null
            } catch (error: Exception) {
                // For example ForegroundServiceStartNotAllowedException once the
                // geofence broadcast's background-start exemption has expired.
                error.javaClass.simpleName
            }
            return GeofenceStartAttempt(invokedAt, SystemClock.elapsedRealtime(), failure)
        }

        /** Appends to the background pipeline log from outside the service (APP-10E). */
        fun recordPipelineDiagnostic(context: android.content.Context, message: String) {
            val preferences = context.getSharedPreferences(BACKGROUND_PREFS, android.content.Context.MODE_PRIVATE)
            val entries = try {
                val array = JSONArray(preferences.getString(BACKGROUND_DIAGNOSTICS, "[]"))
                MutableList(array.length()) { array.getString(it) }
            } catch (_: Exception) {
                mutableListOf()
            }
            val evicted = DiagnosticRetention.append(entries, "${Instant.now()} $message")
            val editor = preferences.edit().putString(BACKGROUND_DIAGNOSTICS, JSONArray(entries).toString())
            if (evicted.routine > 0) {
                editor.putLong(EVICTED_ROUTINE, preferences.getLong(EVICTED_ROUTINE, 0L) + evicted.routine)
            }
            if (evicted.critical > 0) {
                editor.putLong(EVICTED_CRITICAL, preferences.getLong(EVICTED_CRITICAL, 0L) + evicted.critical)
            }
            editor.apply()
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
        inFlightEvents = 0
    }
}
