package com.example.pingplace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VerificationPolicyTest {
    @Test
    fun aShorterWatchdogNeverCutsALongerOne() {
        val approach = VerificationPolicy.extendedDeadline(null, now = 0L, delayMillis = 660_000L)
        assertEquals(660_000L, approach)
        // Another place's EXIT 30 s later asks for a 2-minute re-arm check.
        assertEquals(660_000L, VerificationPolicy.extendedDeadline(approach, now = 30_000L, delayMillis = 120_000L))
        // A later, longer request still extends it.
        assertEquals(1_260_000L, VerificationPolicy.extendedDeadline(approach, now = 600_000L, delayMillis = 660_000L))
    }

    @Test
    fun firstWatchdogUsesTheRequestedDelay() {
        assertEquals(125_000L, VerificationPolicy.extendedDeadline(null, now = 5_000L, delayMillis = 120_000L))
    }

    @Test
    fun onePlaceFinishingKeepsTheServiceForOthers() {
        val decision = VerificationPolicy.stopPlace(linkedSetOf("legacy-place-1", "place-2"), "legacy-place-1")
        assertFalse(decision.stopService)
        assertEquals(listOf("place-2"), decision.remaining)
    }

    @Test
    fun lastPlaceFinishingStopsTheService() {
        assertTrue(VerificationPolicy.stopPlace(listOf("place-2"), "place-2").stopService)
        // A stop for a place that is not tracked must not leave the service orphaned.
        assertTrue(VerificationPolicy.stopPlace(emptyList(), "place-9").stopService)
    }

    @Test
    fun samplesAreQueuedWhileTheEngineIsBooting() {
        assertTrue(VerificationPolicy.shouldQueueSample(engineCreated = false, engineStarting = true))
        assertTrue(VerificationPolicy.shouldQueueSample(engineCreated = true, engineStarting = false))
        assertFalse(VerificationPolicy.shouldQueueSample(engineCreated = false, engineStarting = false))
    }

    @Test
    fun verificationSamplesFastEnoughForAShortVisit() {
        // At 50 km/h an 80 m inner radius is crossed in about 11 s.
        assertTrue(VerificationPolicy.INTERVAL_MS <= 2_000L)
    }

    @Test
    fun lastPlaceStoppingWithNoEventsPendingStopsTheService() {
        val decision = VerificationPolicy.stopPlace(linkedSetOf("legacy-place-1"), "legacy-place-1", eventsInProgress = 0)
        assertTrue(decision.stopService)
        assertFalse(decision.deferStop)
    }

    @Test
    fun lastPlaceStoppingWaitsForQueuedEventsOfOtherPlaces() {
        // APP-10D: one geofence callback reported EXIT for several places. The
        // first place's stop must not destroy the engine with the others' EXITs.
        val decision = VerificationPolicy.stopPlace(linkedSetOf("legacy-place-1"), "legacy-place-1", eventsInProgress = 2)
        assertFalse(decision.stopService)
        assertTrue(decision.deferStop)
        assertEquals(emptyList<String>(), decision.remaining)
    }

    @Test
    fun anotherPlaceVerifyingNeverDefersOrStops() {
        val decision = VerificationPolicy.stopPlace(linkedSetOf("legacy-place-1", "place-2"), "legacy-place-1", eventsInProgress = 3)
        assertFalse(decision.stopService)
        assertFalse(decision.deferStop)
    }

    @Test
    fun deferredStopRunsOnlyWhenIdleAndNoPlaceStartedVerifying() {
        assertFalse(VerificationPolicy.runDeferredStop(deferred = true, active = emptyList(), eventsInProgress = 1))
        assertFalse(VerificationPolicy.runDeferredStop(deferred = true, active = listOf("place-2"), eventsInProgress = 0))
        assertFalse(VerificationPolicy.runDeferredStop(deferred = false, active = emptyList(), eventsInProgress = 0))
        assertTrue(VerificationPolicy.runDeferredStop(deferred = true, active = emptyList(), eventsInProgress = 0))
    }
}
