package com.example.pingplace

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

object GeofencePendingIntent {
    const val REQUEST_CODE = 4202

    internal fun flags(apiLevel: Int): Int =
        PendingIntent.FLAG_UPDATE_CURRENT or
            if (apiLevel >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0

    fun get(context: Context): PendingIntent {
        val intent = Intent(context, GeofenceBroadcastReceiver::class.java)
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags(Build.VERSION.SDK_INT))
    }
}
