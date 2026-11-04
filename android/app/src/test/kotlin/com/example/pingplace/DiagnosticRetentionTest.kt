package com.example.pingplace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** APP-10D: frequent GPS lines must not evict visit and notification evidence. */
class DiagnosticRetentionTest {
    private fun at(second: Int) = "2026-11-04T05:%02d:%02dZ".format(second / 60, second % 60)

    @Test
    fun classifiesPerFixLinesAsRoutine() {
        assertTrue(DiagnosticRetention.isRoutine("${at(1)} legacy-place-1 LOCATION distance=599.3m accuracy=5.0m"))
        assertTrue(DiagnosticRetention.isRoutine("${at(1)} legacy-place-1 LOCATION_IGNORED reason=NO_ACTIVE_VERIFICATION state=ARMED count=1"))
        assertTrue(DiagnosticRetention.isRoutine("${at(1)} place-2 EXIT_OBSERVED_DURING_COOLDOWN rearmAt=none"))
        assertTrue(DiagnosticRetention.isRoutine("${at(1)} place-2 LOCATION_REJECTED reason=LOW_ACCURACY"))
        assertTrue(DiagnosticRetention.isRoutine("${at(1)} BACKGROUND_EVENT_QUEUED type=exit place=place-2"))
    }

    @Test
    fun keepsTransitionsOutcomesAndFailuresCritical() {
        listOf(
            "legacy-place-1 APPROACH_SUMMARY outcome=ARRIVED visit=visit-1 samples=9",
            "legacy-place-1 NOTIFICATION_SENT visit=visit-1",
            "legacy-place-1 NOTIFICATION_SUPPRESSED_DUPLICATE visit=visit-1",
            "legacy-place-1 STATE cooldown -> armed",
            "legacy-place-1 ENTER_SUPPRESSED reason=COOLDOWN until=x",
            "legacy-place-1 BACKGROUND_SESSION_RESTORED state=COOLDOWN visit=visit-1",
            "BACKGROUND_ENGINE_NOT_READY after=15000ms queued=3",
            "BACKGROUND_VERIFICATION_WATCHDOG_STOPPED places=[legacy-place-1]",
            "PRECISE_LOCATION_START_FAILED permission",
            "PLACE_VERIFICATION_STOPPED place=place-2 service=STOPPING",
            "FIRST_LOCATION_SAMPLE after=900ms accuracy=4.0m places=[place-2]",
            "SOMETHING_NEW_THAT_FAILED",
        ).forEach { message ->
            assertFalse(message, DiagnosticRetention.isRoutine("${at(1)} $message"))
        }
    }

    @Test
    fun routineLinesAreEvictedBeforeVisitEvidence() {
        val log = mutableListOf<String>()
        // The Build 19 report: a visit, then hundreds of repeated fix lines.
        DiagnosticRetention.append(log, "${at(0)} legacy-place-1 STATE armed -> approaching", max = 50)
        DiagnosticRetention.append(log, "${at(1)} legacy-place-1 APPROACH_SUMMARY outcome=ARRIVED visit=visit-3", max = 50)
        DiagnosticRetention.append(log, "${at(2)} legacy-place-1 NOTIFICATION_SENT visit=visit-3", max = 50)
        var evictedRoutine = 0
        for (second in 3 until 400) {
            val evicted = DiagnosticRetention.append(
                log,
                "${at(second)} place-2 LOCATION_IGNORED reason=NO_ACTIVE_VERIFICATION state=ARMED",
                max = 50,
            )
            assertEquals(0, evicted.critical)
            evictedRoutine += evicted.routine
        }
        assertEquals(50, log.size)
        assertEquals(400 - 50, evictedRoutine)
        // Visit evidence kept, in order, ahead of the newest routine lines.
        assertTrue(log[0].contains("STATE armed -> approaching"))
        assertTrue(log[1].contains("APPROACH_SUMMARY outcome=ARRIVED"))
        assertTrue(log[2].contains("NOTIFICATION_SENT visit=visit-3"))
        assertTrue(log.last().startsWith(at(399)))
    }

    @Test
    fun criticalLinesAreEvictedOldestFirstWhenNothingElseIsLeft() {
        val log = mutableListOf<String>()
        var evictedCritical = 0
        for (second in 0 until 12) {
            evictedCritical += DiagnosticRetention.append(log, "${at(second)} legacy-place-1 STATE s$second", max = 10).critical
        }
        assertEquals(2, evictedCritical)
        assertEquals(10, log.size)
        assertTrue(log.first().endsWith("STATE s2"))
        assertTrue(log.last().endsWith("STATE s11"))
    }

    @Test
    fun summaryLineStatesWhatWasDropped() {
        assertEquals(
            "LOG_RETENTION retained=500 max=500 evictedRoutine=346 evictedCritical=0 policy=ROUTINE_FIRST",
            DiagnosticRetention.summaryLine(500, 346L, 0L),
        )
    }
}
