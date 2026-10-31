package com.example.pingplace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecoveryPolicyTest {
    @Test
    fun bootRestoresPlacesOnceThePlaceListIsRegistered() {
        // Regression: BootRecoveryReceiver used to run legacy recovery only, which
        // left places unregistered after reboot and could remove them.
        assertEquals(RecoveryPath.MULTI_PLACE, RecoveryPolicy.path(multiPlaceManaged = true))
    }

    @Test
    fun legacyRecoveryRemainsForInstallsThatNeverRegisteredPlaces() {
        assertEquals(RecoveryPath.LEGACY, RecoveryPolicy.path(multiPlaceManaged = false))
    }

    @Test
    fun legacyOperationsAreRejectedWhilePlacesAreManaged() {
        assertFalse(RecoveryPolicy.legacyOperationAllowed(multiPlaceManaged = true))
        assertTrue(RecoveryPolicy.legacyOperationAllowed(multiPlaceManaged = false))
    }

    @Test
    fun failedPlaceRestoreNeverFallsBackToLegacyRecovery() {
        // Legacy recovery calls removeGeofences(PendingIntent) and would remove all
        // places and resurrect an outdated single target.
        assertFalse(RecoveryPolicy.legacyFallbackAfterMultiFailure(multiPlaceManaged = true))
    }

    @Test
    fun removingEveryPlaceIsARemovalOnlyPlan() {
        val plan = MultiPlaceTransitionPlan.create(listOf("a", "b"), emptyList())
        assertTrue(plan.additions.isEmpty())
        assertEquals(listOf("a", "b"), plan.removals)
    }
}
