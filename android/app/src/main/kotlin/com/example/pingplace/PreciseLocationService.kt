package com.example.pingplace

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
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
import java.time.Instant

class PreciseLocationService : Service() {
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private var locationCallback: LocationCallback? = null

    override fun onCreate() {
        super.onCreate()
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopUpdates()
            else -> startUpdates()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopUpdates()
        super.onDestroy()
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
                }
            }
        }
        try {
            fusedLocationClient.requestLocationUpdates(
                request,
                locationCallback!!,
                Looper.getMainLooper(),
            ).addOnFailureListener { error ->
                LocationEventBus.publish(
                    this,
                    mapOf(
                        "type" to "error",
                        "timestamp" to Instant.now().toString(),
                        "error" to (error.message ?: error.toString()),
                    ),
                )
                stopSelf()
            }
        } catch (error: SecurityException) {
            LocationEventBus.publish(
                this,
                mapOf(
                    "type" to "error",
                    "timestamp" to Instant.now().toString(),
                    "error" to (error.message ?: error.toString()),
                ),
            )
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
        private const val CHANNEL_ID = "pingplace_precise_location"
        private const val NOTIFICATION_ID = 4203
    }
}
