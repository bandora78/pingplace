package com.example.pingplace

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val pendingResult = goAsync()
        GeofenceRecovery.restore(context, "boot") { _, _ -> pendingResult.finish() }
    }
}
