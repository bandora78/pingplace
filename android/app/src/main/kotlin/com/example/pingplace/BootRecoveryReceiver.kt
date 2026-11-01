package com.example.pingplace

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val pendingResult = goAsync()
        when (RecoveryPolicy.path(MultiPlaceGeofenceRegistration.hasDesired(context))) {
            // Android drops all geofences on reboot. Restore every enabled place
            // without waiting for the user to open the app.
            RecoveryPath.MULTI_PLACE -> MultiPlaceGeofenceRegistration.restore(context) { success, error ->
                GeofenceRecovery.recordDiagnostic(
                    context,
                    if (success) "MULTI_GEOFENCE_BOOT_RECOVERY_COMPLETED"
                    else "MULTI_GEOFENCE_BOOT_RECOVERY_FAILED ${error ?: "unknown"}",
                )
                pendingResult.finish()
            }
            RecoveryPath.LEGACY -> GeofenceRecovery.restore(context, "boot") { _, _ -> pendingResult.finish() }
        }
    }
}
