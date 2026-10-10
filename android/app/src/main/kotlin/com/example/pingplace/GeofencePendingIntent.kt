package com.example.pingplace

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

object GeofencePendingIntent {
    fun get(context: Context): PendingIntent {
        val intent = Intent(context, GeofenceBroadcastReceiver::class.java)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        return PendingIntent.getBroadcast(context, 4202, intent, flags)
    }
}
