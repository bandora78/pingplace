package com.example.pingplace

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

object PlatformRuntimeBridge {
    const val RUNTIME_CHANNEL = "pingplace/runtime"
    const val NOTIFICATION_CHANNEL = "pingplace/notifications"

    fun handleRuntime(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val preferences = context.getSharedPreferences(RUNTIME_PREFS, Context.MODE_PRIVATE)
        when (call.method) {
            "load" -> {
                val serialized = preferences.getString(RUNTIME_STATE, null)
                result.success(serialized?.let { decodeState(it) })
            }
            "save" -> {
                val arguments = call.arguments as? Map<*, *>
                if (arguments == null) {
                    result.error("INVALID_ARGUMENT", "Runtime state map is required", null)
                } else {
                    preferences.edit().putString(RUNTIME_STATE, encodeState(arguments)).commit()
                    result.success(null)
                }
            }
            "clear" -> {
                preferences.edit().remove(RUNTIME_STATE).commit()
                result.success(null)
            }
            "loadReminderText" -> result.success(
                preferences.getString(REMINDER_TEXT, DEFAULT_REMINDER) ?: DEFAULT_REMINDER,
            )
            "saveReminderText" -> {
                preferences.edit().putString(REMINDER_TEXT, call.arguments as? String ?: DEFAULT_REMINDER).apply()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun encodeState(arguments: Map<*, *>): String = JSONObject().apply {
        put("state", arguments["state"] ?: "disarmed")
        putNullable("targetLatitude", arguments["targetLatitude"])
        putNullable("targetLongitude", arguments["targetLongitude"])
        putNullable("approachStartedAt", arguments["approachStartedAt"])
        putNullable("cooldownUntil", arguments["cooldownUntil"])
        put("exitObservedDuringCooldown", arguments["exitObservedDuringCooldown"] ?: false)
        putNullable("visitId", arguments["visitId"])
    }.toString()

    private fun decodeState(serialized: String): Map<String, Any?> = try {
        val state = JSONObject(serialized)
        mapOf(
            "state" to state.optString("state", "disarmed"),
            "targetLatitude" to state.optDouble("targetLatitude", Double.NaN).takeUnless { it.isNaN() },
            "targetLongitude" to state.optDouble("targetLongitude", Double.NaN).takeUnless { it.isNaN() },
            "approachStartedAt" to state.optString("approachStartedAt").ifEmpty { null },
            "cooldownUntil" to state.optString("cooldownUntil").ifEmpty { null },
            "exitObservedDuringCooldown" to state.optBoolean("exitObservedDuringCooldown", false),
            "visitId" to state.optString("visitId").ifEmpty { null },
        )
    } catch (_: Exception) {
        emptyMap()
    }

    private fun JSONObject.putNullable(key: String, value: Any?) {
        put(key, value ?: JSONObject.NULL)
    }

    private const val RUNTIME_PREFS = "pingplace_runtime"
    private const val RUNTIME_STATE = "detection_state"
    private const val REMINDER_TEXT = "reminder_text"
    private const val DEFAULT_REMINDER = "עצור בתחנת דלק יעד"
}

object ArrivalNotificationBridge {
    private const val CHANNEL_ID = "pingplace_arrival_reminders"
    private const val CHANNEL_NAME = "Arrival reminders"
    private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 4204
    private const val NOTIFICATION_PREFS = "pingplace_notifications"
    private const val SENT_VISITS = "sent_visits"
    private const val LAST_RESULT = "last_result"
    private const val LAST_TIMESTAMP = "last_timestamp"
    private const val LAST_VISIT_ID = "last_visit_id"
    private const val DEFAULT_REMINDER = "הגעת למקום שהגדרת"
    private val lock = Any()

    fun handle(
        context: Context,
        activity: Activity?,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "status" -> result.success(status(context))
            "requestPermission" -> requestPermission(activity, result)
            "openSettings" -> {
                context.startActivity(
                    Intent(
                        Settings.ACTION_APP_NOTIFICATION_SETTINGS,
                        Uri.parse("package:${context.packageName}"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                result.success(null)
            }
            "resetTest" -> {
                context.getSharedPreferences(NOTIFICATION_PREFS, Context.MODE_PRIVATE).edit()
                    .remove(SENT_VISITS)
                    .remove(LAST_RESULT)
                    .remove(LAST_TIMESTAMP)
                    .remove(LAST_VISIT_ID)
                    .apply()
                result.success(null)
            }
            "deliver" -> deliver(context, call, result)
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(activity: Activity?, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(null)
            return
        }
        if (activity == null) {
            result.error("BACKGROUND_PERMISSION_REQUEST", "Notification permission requires the visible UI", null)
            return
        }
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
        result.success(null)
    }

    private fun deliver(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val visitId = call.argument<String>("visitId")
        val reminder = call.argument<String>("reminderText")?.trim().orEmpty().ifEmpty { DEFAULT_REMINDER }
        if (visitId.isNullOrEmpty()) {
            result.success("failed")
            return
        }
        if (!notificationsAllowed(context)) {
            recordResult(context, "permissionMissing", visitId)
            result.success("permissionMissing")
            return
        }
        synchronized(lock) {
            val preferences = context.getSharedPreferences(NOTIFICATION_PREFS, Context.MODE_PRIVATE)
            val sent = readSentVisits(preferences.getString(SENT_VISITS, null))
            if (visitId in sent) {
                recordResult(context, "duplicate", visitId)
                result.success("duplicate")
                return
            }
            try {
                createChannel(context)
                val intent = Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
                val pendingIntentFlags = PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    4301,
                    intent,
                    pendingIntentFlags,
                )
                val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(context.applicationInfo.icon)
                    .setContentTitle("PingPlace — הגעת ליעד")
                    .setContentText(reminder)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                    .setAutoCancel(true)
                    .setContentIntent(pendingIntent)
                    .build()
                val notificationId = visitId.hashCode() and 0x7fffffff
                context.getSystemService(NotificationManager::class.java).notify(notificationId, notification)
                sent.add(visitId)
                preferences.edit().putString(SENT_VISITS, JSONArray(sent).toString()).commit()
                recordResult(context, "sent", visitId)
                result.success("sent")
            } catch (_: Exception) {
                recordResult(context, "failed", visitId)
                result.success("failed")
            }
        }
    }

    private fun notificationsAllowed(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    private fun status(context: Context): Map<String, Any?> {
        val preferences = context.getSharedPreferences(NOTIFICATION_PREFS, Context.MODE_PRIVATE)
        return mapOf(
            "permission" to if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || notificationsAllowed(context)) "allowed" else "denied",
            "lastResult" to preferences.getString(LAST_RESULT, null),
            "lastTimestamp" to preferences.getString(LAST_TIMESTAMP, null),
            "lastVisitId" to preferences.getString(LAST_VISIT_ID, null),
            "backgroundDiagnostics" to backgroundDiagnostics(context),
        )
    }

    private fun recordResult(context: Context, result: String, visitId: String) {
        context.getSharedPreferences(NOTIFICATION_PREFS, Context.MODE_PRIVATE).edit()
            .putString(LAST_RESULT, result)
            .putString(LAST_TIMESTAMP, Instant.now().toString())
            .putString(LAST_VISIT_ID, visitId)
            .apply()
    }

    private fun readSentVisits(serialized: String?): MutableSet<String> = try {
        val array = JSONArray(serialized ?: "[]")
        buildSet { for (index in 0 until array.length()) add(array.getString(index)) }.toMutableSet()
    } catch (_: Exception) {
        mutableSetOf()
    }

    private fun backgroundDiagnostics(context: Context): List<String> = try {
        val serialized = context.getSharedPreferences("pingplace_background", Context.MODE_PRIVATE)
            .getString("diagnostics", "[]")
        val array = JSONArray(serialized)
        buildList { for (index in 0 until array.length()) add(array.getString(index)) }
    } catch (_: Exception) {
        emptyList()
    }
}
