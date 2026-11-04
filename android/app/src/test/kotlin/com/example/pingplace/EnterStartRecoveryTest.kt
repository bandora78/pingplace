package com.example.pingplace

import com.example.pingplace.EnterStartRecovery.Decision
import com.example.pingplace.EnterStartRecovery.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EnterStartRecoveryTest {
    private val places = listOf("legacy-place-1", "place-2", "place-3")
    private val now = 1_793_821_220_375L

    @Test
    fun aBlockedEnterForARegisteredPlaceIsReRegisteredOnce() {
        assertEquals(Decision.REREGISTER, EnterStartRecovery.onBlocked("legacy-place-1", places, null, now))
        // The recovered ENTER is blocked again: no second attempt, no loop.
        assertEquals(
            Decision.EXHAUSTED,
            EnterStartRecovery.onBlocked("legacy-place-1", places, now, now + 40_000),
        )
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
    fun anotherPlacesRecoveryDoesNotExhaustThisPlace() {
        // The window is per place: the caller passes this place's own marker.
        assertEquals(Decision.REREGISTER, EnterStartRecovery.onBlocked("place-2", places, null, now))
    }

    @Test
    fun aDeletedOrDisabledPlaceOrTheLegacyGeofenceIsNeverReRegistered() {
        assertEquals(Decision.NOT_REGISTERED, EnterStartRecovery.onBlocked("deleted-place", places, null, now))
        assertEquals(Decision.NOT_REGISTERED, EnterStartRecovery.onBlocked(null, places, null, now))
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
    fun theBlockedStartIsLoggedAsAnOutcomeThatIsNeverAnArrival() {
        val summary = EnterStartRecovery.blockedSummaryLine(
            "legacy-place-1",
            "ForegroundServiceStartNotAllowedException",
            39_362,
            Decision.REREGISTER,
        )
        assertEquals(
            "legacy-place-1 APPROACH_SUMMARY outcome=START_BLOCKED visit=none " +
                "error=ForegroundServiceStartNotAllowedException sinceReceive=39362ms recovery=REREGISTER",
            summary,
        )
        assertFalse(summary.contains("ARRIVED"))
        assertFalse(DiagnosticRetention.isRoutine("2026-11-04T19:40:20Z $summary"))
        val native = EnterStartRecovery.blockedLine(null, "ForegroundServiceStartNotAllowedException", 5, Decision.NOT_REGISTERED)
        assertEquals(
            "PRECISE_LOCATION_START_BLOCKED place=legacy error=ForegroundServiceStartNotAllowedException " +
                "sinceReceive=5ms recovery=NOT_REGISTERED",
            native,
        )
    }

    @Test
    fun everyServiceStartPrecedesDiagnosticsAndUiQueueWrites() {
        assertEquals(
            listOf(
                Step.StartVerification("legacy-place-1"),
                Step.StartVerification("place-2"),
                Step.Diagnostics,
                Step.PublishToUi,
            ),
            EnterStartRecovery.plan("enter", listOf("legacy-place-1", "place-2")),
        )
        assertEquals(
            listOf(Step.QueueExit("place-2"), Step.Diagnostics, Step.PublishToUi),
            EnterStartRecovery.plan("exit", listOf("place-2")),
        )
    }

    @Test
    fun anUnsupportedTransitionStartsNothing() {
        assertEquals(
            listOf(Step.Diagnostics, Step.PublishToUi),
            EnterStartRecovery.plan("error", listOf("place-2")),
        )
    }
}
