package com.example.pingplace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaceDiagnosticsTest {
    @Test
    fun transitionNamesEveryPlaceIdAndHowItWasRouted() {
        val line = PlaceDiagnostics.transition("enter", listOf("place-1", "place-2"), setOf("place-1", "place-2", "place-3"))
        assertEquals("GEOFENCE_TRANSITION enter ids=[place-1,place-2] places=[place-1,place-2]", line)
    }

    @Test
    fun transitionReportsHowOldTheTriggeringFixWasOnReceipt() {
        val line = PlaceDiagnostics.transition("enter", listOf("legacy-place-1"), setOf("legacy-place-1"), 1_250)
        assertEquals("GEOFENCE_TRANSITION enter ids=[legacy-place-1] places=[legacy-place-1] triggerAge=1250ms", line)
    }

    @Test
    fun transitionFlagsUnknownAndLegacyIds() {
        val line = PlaceDiagnostics.transition(
            "exit",
            listOf("place-9", PlaceDiagnostics.LEGACY_ID),
            setOf("place-1"),
        )
        assertTrue(line, line.contains("places=[]"))
        assertTrue(line, line.contains("legacy=true"))
        assertTrue(line, line.contains("UNKNOWN=[place-9]"))
    }

    @Test
    fun registrationListsEachGeofenceWithRoundedLocationAndRadius() {
        val line = PlaceDiagnostics.registration(
            "restore",
            listOf(
                MultiPlaceGeofenceRegistration.Target("legacy-place-1", 32.085312, 34.781876, 300f),
                MultiPlaceGeofenceRegistration.Target("place-2", -33.8688, 151.2093, 150f),
            ),
        )
        assertEquals(
            "MULTI_GEOFENCE_APPLIED source=restore count=2 legacy-place-1@32.085,34.782/r300 place-2@-33.869,151.209/r150",
            line,
        )
    }

    @Test
    fun emptyRegistrationIsExplicit() {
        assertEquals("MULTI_GEOFENCE_APPLIED source=register count=0", PlaceDiagnostics.registration("register", emptyList()))
        assertEquals(
            "MULTI_GEOFENCE_RECONCILE_FAILED source=boot reason=Location services are disabled",
            PlaceDiagnostics.registrationFailed("boot", "Location services are disabled"),
        )
    }

    @Test
    fun forceStopAndPermissionLossAreFlaggedAsClearingGeofences() {
        assertTrue(PlaceDiagnostics.geofencesCleared(PlaceDiagnostics.REASON_USER_REQUESTED))
        assertTrue(PlaceDiagnostics.geofencesCleared(PlaceDiagnostics.REASON_USER_STOPPED))
        assertTrue(PlaceDiagnostics.geofencesCleared(PlaceDiagnostics.REASON_PERMISSION_CHANGE))
        // Ordinary process death keeps geofences registered.
        assertFalse(PlaceDiagnostics.geofencesCleared(PlaceDiagnostics.REASON_LOW_MEMORY))
        assertFalse(PlaceDiagnostics.geofencesCleared(PlaceDiagnostics.REASON_SIGNALED))
        assertFalse(PlaceDiagnostics.geofencesCleared(PlaceDiagnostics.REASON_PACKAGE_UPDATED))
        assertFalse(PlaceDiagnostics.geofencesCleared(PlaceDiagnostics.REASON_CRASH))
    }

    @Test
    fun exitDiagnosticsReportOnlyNewExitsOldestFirst() {
        val records = listOf(
            PlaceDiagnostics.ExitRecord(PlaceDiagnostics.REASON_USER_REQUESTED, 3_000L, "stop"),
            PlaceDiagnostics.ExitRecord(PlaceDiagnostics.REASON_LOW_MEMORY, 2_000L, null),
            PlaceDiagnostics.ExitRecord(PlaceDiagnostics.REASON_SIGNALED, 1_000L, null),
        )
        val lines = PlaceDiagnostics.exitDiagnostics(records, sinceMillis = 1_000L)
        assertEquals(2, lines.size)
        assertTrue(lines[0], lines[0].startsWith("APP_PROCESS_EXIT reason=LOW_MEMORY at=1970-01-01T00:00:02Z"))
        assertFalse(lines[0], lines[0].contains("GEOFENCES_CLEARED"))
        assertTrue(lines[1], lines[1].startsWith("APP_PROCESS_EXIT reason=FORCE_STOPPED"))
        assertTrue(lines[1], lines[1].contains("detail=stop"))
        assertTrue(lines[1], lines[1].contains("GEOFENCES_CLEARED_BY_ANDROID"))
    }

    @Test
    fun alreadyReportedExitsAreNotRepeated() {
        val records = listOf(PlaceDiagnostics.ExitRecord(PlaceDiagnostics.REASON_USER_REQUESTED, 5_000L, null))
        assertTrue(PlaceDiagnostics.exitDiagnostics(records, sinceMillis = 5_000L).isEmpty())
    }

    @Test
    fun unknownReasonCodesAreNamedNotDropped() {
        assertEquals("UNKNOWN_99", PlaceDiagnostics.reasonName(99))
        assertEquals("FORCE_STOPPED", PlaceDiagnostics.reasonName(PlaceDiagnostics.REASON_USER_REQUESTED))
    }
}
