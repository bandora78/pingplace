package com.example.pingplace

import com.example.pingplace.EnterStartRecovery.Decision
import com.example.pingplace.EnterStartRecovery.Stage
import com.example.pingplace.EnterStartRecovery.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class EnterStartRecoveryTest {
    private val places = listOf("legacy-place-1", "place-2", "place-3")
    private val now = 1_793_821_220_375L

    private fun target(id: String, latitude: Double = 31.665) =
        MultiPlaceGeofenceRegistration.Target(id, latitude, 34.781, 300f, reminderText = "Buy milk")

    // --- Recovery policy ---------------------------------------------------

    @Test
    fun aBlockedEnterForARegisteredPlaceIsReRegisteredOnce() {
        assertEquals(Decision.REREGISTER, EnterStartRecovery.onBlocked("legacy-place-1", places, null, now))
        // The recovered ENTER is blocked again: no second attempt, no loop.
        assertEquals(Decision.EXHAUSTED, EnterStartRecovery.onBlocked("legacy-place-1", places, now, now + 40_000))
        assertEquals(
            Decision.EXHAUSTED,
            EnterStartRecovery.onBlocked("legacy-place-1", places, now, now + EnterStartRecovery.WINDOW_MS - 1),
        )
        // A new episode after the window recovers again.
        assertEquals(
            Decision.REREGISTER,
            EnterStartRecovery.onBlocked("legacy-place-1", places, now, now + EnterStartRecovery.WINDOW_MS),
        )
    }

    @Test
    fun theLimitIsPerPlace() {
        // The caller passes each place's own persisted marker.
        assertEquals(Decision.REREGISTER, EnterStartRecovery.onBlocked("place-2", places, null, now))
        assertEquals(Decision.EXHAUSTED, EnterStartRecovery.onBlocked("place-3", places, now - 1, now))
    }

    @Test
    fun aDeletedOrDisabledPlaceOrTheLegacyGeofenceIsNeverReRegistered() {
        assertEquals(Decision.NOT_REGISTERED, EnterStartRecovery.onBlocked("deleted-place", places, null, now))
        assertEquals(Decision.NOT_REGISTERED, EnterStartRecovery.onBlocked(null, places, null, now))
        assertEquals(Decision.NOT_REGISTERED, EnterStartRecovery.onBlocked("place-2", emptyList(), null, now))
    }

    @Test
    fun theReAddRunsOnlyForAStillDesiredConfirmedAndAppliedPlace() {
        assertTrue(EnterStartRecovery.mayReRegister("place-2", places, true, places))
        // Data written before the applied journal existed: confirmed is enough.
        assertTrue(EnterStartRecovery.mayReRegister("place-2", places, true, null))
        // Deleted or disabled while the re-add was queued.
        assertFalse(EnterStartRecovery.mayReRegister("place-2", listOf("place-3"), true, places))
        // The last registration failed or is in progress.
        assertFalse(EnterStartRecovery.mayReRegister("place-2", places, false, places))
        // Desired but not yet applied on the platform.
        assertFalse(EnterStartRecovery.mayReRegister("place-2", places, true, listOf("place-3")))
    }

    @Test
    fun aClockMovedBackwardsDoesNotBlockRecoveryForever() {
        assertEquals(Decision.REREGISTER, EnterStartRecovery.onBlocked("place-2", places, now + 60_000, now))
    }

    @Test
    fun aStartWithinTheWindowCountsAsTheRecoveredEnter() {
        assertTrue(EnterStartRecovery.recoveredBy(now, now + 2_000))
        assertFalse(EnterStartRecovery.recoveredBy(now, now + EnterStartRecovery.WINDOW_MS))
        assertFalse(EnterStartRecovery.recoveredBy(null, now))
    }

    @Test
    fun theReceiverHoldIsBelowEveryBroadcastTimeout() {
        // Android's foreground broadcast timeout is 10 s (background 60 s).
        assertTrue(EnterStartRecovery.RECEIVER_HOLD_MS < 10_000)
    }

    // --- Logging -----------------------------------------------------------

    @Test
    fun aBlockedStartIsLoggedAsAnOutcomeThatIsNeverAnArrival() {
        val summary = EnterStartRecovery.blockedSummaryLine(
            "legacy-place-1",
            "ForegroundServiceStartNotAllowedException",
            39_362,
            Decision.REREGISTER,
        )
        assertEquals(
            "legacy-place-1 APPROACH_SUMMARY outcome=START_BLOCKED visit=none stage=START " +
                "error=ForegroundServiceStartNotAllowedException sinceReceive=39362ms recovery=REREGISTER",
            summary,
        )
        assertFalse(summary.contains("ARRIVED"))
        assertFalse(DiagnosticRetention.isRoutine("2026-11-04T19:40:20Z $summary"))
        assertEquals(
            "PRECISE_LOCATION_START_BLOCKED place=legacy stage=PROMOTION error=SecurityException " +
                "sinceReceive=5ms recovery=NOT_REGISTERED",
            EnterStartRecovery.blockedLine(null, "SecurityException", 5, Decision.NOT_REGISTERED, Stage.PROMOTION),
        )
    }

    @Test
    fun receiverTimingSeparatesParsingFromTheStartCall() {
        val line = EnterStartRecovery.timingLine(
            EnterStartRecovery.ReceiverTiming("enter", 2, 3, 4, 16, null, 1_250),
        )
        assertEquals(
            "GEOFENCE_RECEIVER_TIMING type=enter places=2 parse=3ms startInvoked=+4ms startReturned=+16ms " +
                "start=ACCEPTED triggerAge=1250ms",
            line,
        )
        val blocked = EnterStartRecovery.timingLine(
            EnterStartRecovery.ReceiverTiming("enter", 1, 2, 39_361, 39_370, "ForegroundServiceStartNotAllowedException", null),
        )
        assertTrue(blocked.endsWith("start=ForegroundServiceStartNotAllowedException"))
        assertFalse(
            EnterStartRecovery.timingLine(EnterStartRecovery.ReceiverTiming("error", 1, 1, null, null, null, null))
                .contains("startInvoked"),
        )
    }

    // --- Ordering and multiple places ----------------------------------------

    @Test
    fun oneStartForEveryPlaceOfTheCallbackPrecedesAllStorageWork() {
        assertEquals(
            listOf(
                Step.StartVerification(listOf("legacy-place-1", "place-2")),
                Step.Diagnostics,
                Step.PublishToUi,
            ),
            EnterStartRecovery.plan("enter", listOf("legacy-place-1", "place-2")),
        )
        assertEquals(
            listOf(Step.QueueExits(listOf("place-2", "place-3")), Step.Diagnostics, Step.PublishToUi),
            EnterStartRecovery.plan("exit", listOf("place-2", "place-3")),
        )
    }

    @Test
    fun anUnsupportedTransitionStartsNothing() {
        assertEquals(listOf(Step.Diagnostics, Step.PublishToUi), EnterStartRecovery.plan("error", listOf("place-2")))
    }

    @Test
    fun theServiceVerifiesOnlyRegisteredPlacesAndKeepsTheRestOfTheCallback() {
        val resolution = EnterStartRecovery.resolve(
            listOf("deleted-place", "legacy-place-1", "place-2", "place-2"),
            listOf(target("legacy-place-1"), target("place-2", 31.667)),
            null,
        )
        // An unknown first ID does not stop the registered places after it.
        assertEquals(listOf("legacy-place-1", "place-2"), resolution.resolved.map { it.placeId })
        assertEquals(31.667, resolution.resolved[1].latitude, 0.0)
        assertEquals("Buy milk", resolution.resolved[0].target?.reminderText)
        assertEquals(listOf("deleted-place"), resolution.unknown)
        assertFalse(resolution.legacyTargetMissing)
    }

    @Test
    fun theLegacyGeofenceResolvesFromItsPersistedCoordinatesOrIsReported() {
        val withTarget = EnterStartRecovery.resolve(listOf(PlaceDiagnostics.LEGACY_ID), emptyList(), 31.0 to 34.0)
        assertNull(withTarget.resolved.single().placeId)
        assertEquals(34.0, withTarget.resolved.single().longitude, 0.0)
        val missing = EnterStartRecovery.resolve(listOf(PlaceDiagnostics.LEGACY_ID), emptyList(), null)
        assertTrue(missing.resolved.isEmpty())
        assertTrue(missing.legacyTargetMissing)
        assertTrue(missing.unknown.isEmpty())
    }

    // --- goAsync hold ----------------------------------------------------------

    @Test
    fun theHoldReleasesOnceWhenEveryRecoveryAnswers() {
        val releases = mutableListOf<String>()
        val hold = EnterStartRecovery.ReceiverHold(2) { releases += it }
        hold.complete()
        assertFalse(hold.isReleased)
        hold.complete()
        hold.complete() // duplicate answer
        hold.timeout() // timeout after completion
        assertEquals(listOf("COMPLETED"), releases)
    }

    @Test
    fun aLateAnswerAfterTheTimeoutDoesNotReleaseAgain() {
        val releases = mutableListOf<String>()
        val hold = EnterStartRecovery.ReceiverHold(1) { releases += it }
        hold.timeout()
        hold.complete()
        assertEquals(listOf("TIMEOUT"), releases)
    }

    @Test
    fun concurrentAnswersAndTimeoutReleaseExactlyOnce() {
        repeat(200) {
            val releases = AtomicInteger()
            val hold = EnterStartRecovery.ReceiverHold(3) { releases.incrementAndGet() }
            val pool = Executors.newFixedThreadPool(4)
            val go = CountDownLatch(1)
            repeat(3) { pool.execute { go.await(); hold.complete() } }
            pool.execute { go.await(); hold.timeout() }
            go.countDown()
            pool.shutdown()
            assertTrue(pool.awaitTermination(5, TimeUnit.SECONDS))
            assertEquals(1, releases.get())
        }
    }
}
