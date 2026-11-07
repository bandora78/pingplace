package com.example.pingplace

import com.example.pingplace.DiagnosticRetention.Tier
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** APP-10D/APP-10F: bounded log retention per tier. */
class DiagnosticRetentionTest {
    private val start = Instant.parse("2026-11-04T05:00:00Z")
    private fun at(second: Long) = start.plusSeconds(second).toString()

    /** Persisted like SharedPreferences: JSON text, re-read on every access. */
    private class JsonStorage : DiagnosticRetention.Storage {
        var log = "[]"
        val counters = JSONObject()

        override fun entries(): MutableList<String> {
            val array = JSONArray(log)
            return MutableList(array.length()) { array.getString(it) }
        }

        override fun counter(key: String): Long = counters.optLong(key, 0L)

        override fun save(entries: List<String>, counterIncrements: Map<String, Long>) {
            log = JSONArray(entries).toString()
            counterIncrements.forEach { (key, increment) -> counters.put(key, counter(key) + increment) }
        }

        /** A new process: nothing but the persisted text survives. */
        fun restarted(): JsonStorage = JsonStorage().also { copy ->
            copy.log = log
            counters.keys().forEach { copy.counters.put(it, counters.get(it)) }
        }
    }

    // --- Classification ------------------------------------------------------

    @Test
    fun perFixLinesAreSamples() {
        listOf(
            "legacy-place-1 LOCATION distance=599.3m accuracy=5.0m at=x lat=31.66 lon=34.78 age=0s",
            "legacy-place-1 LOCATION_IGNORED reason=NO_ACTIVE_VERIFICATION state=ARMED count=1",
            "place-2 EXIT_OBSERVED_DURING_COOLDOWN rearmAt=none",
            "place-2 LOCATION_REJECTED reason=LOW_ACCURACY",
        ).forEach { assertEquals(it, Tier.SAMPLE, DiagnosticRetention.tier("${at(1)} $it")) }
        assertTrue(DiagnosticRetention.isRoutine("${at(1)} place-2 LOCATION distance=1.0m accuracy=1.0m"))
    }

    @Test
    fun visitOutcomesAndFailuresAreOutcomes() {
        listOf(
            "legacy-place-1 APPROACH_STARTED visit=visit-1",
            "legacy-place-1 APPROACH_SUMMARY outcome=ARRIVED visit=visit-1 samples=9",
            "legacy-place-1 APPROACH_SUMMARY outcome=START_BLOCKED visit=none stage=START error=X",
            "legacy-place-1 NOTIFICATION_REQUESTED visit=visit-1",
            "legacy-place-1 NOTIFICATION_SENT visit=visit-1",
            "legacy-place-1 NOTIFICATION_SUPPRESSED_DUPLICATE visit=visit-1",
            "legacy-place-1 ENTER_SUPPRESSED reason=COOLDOWN until=x",
            "legacy-place-1 COOLDOWN_ELAPSED_WHILE_STOPPED until=x exitObserved=true",
            "legacy-place-1 REARM_VERIFICATION_COMPLETE exitObserved=true rearmAt=x",
            "legacy-place-1 REARMED_ON_EXIT state=ARMED",
            "place-2 EXIT_CONFIRMED distance=363.5",
            "BACKGROUND_VERIFICATION_WATCHDOG_STOPPED places=[legacy-place-1]",
            "BACKGROUND_ENGINE_NOT_READY after=15000ms queued=3",
            "PRECISE_LOCATION_START_FAILED permission",
            "PRECISE_LOCATION_TARGET_UNKNOWN place=deleted",
            "FOREGROUND_PROMOTION_FAILED error=SecurityException",
            "SOMETHING_NEW",
        ).forEach { assertEquals(it, Tier.OUTCOME, DiagnosticRetention.tier("${at(1)} $it")) }
    }

    @Test
    fun plumbingIsLifecycle() {
        listOf(
            "legacy-place-1 STATE cooldown -> armed",
            "legacy-place-1 BACKGROUND_SESSION_RESTORED state=COOLDOWN visit=visit-1",
            "legacy-place-1 PRECISE_LOCATION_STARTED",
            "legacy-place-1 PRECISE_LOCATION_KEPT reason=NEW_APPROACH",
            "legacy-place-1 INNER_REACHED",
            "PLACE_VERIFICATION_STOPPED place=place-2 service=STOPPING_AFTER_EVENTS events=1",
            "FIRST_LOCATION_SAMPLE after=900ms accuracy=4.0m places=[place-2]",
            "BACKGROUND_EVENT_QUEUED type=exit place=place-2",
            "FOREGROUND_PROMOTED sinceReceive=135ms places=[legacy-place-1]",
            "GEOFENCE_TARGETS_READ took=0ms resolved=1 unknown=[]",
            "PRECISE_LOCATION_START_REQUESTED place=legacy-place-1 sinceReceive=200ms",
        ).forEach { assertEquals(it, Tier.LIFECYCLE, DiagnosticRetention.tier("${at(1)} $it")) }
    }

    // --- Eviction ------------------------------------------------------------

    @Test
    fun aBurstInOneTierNeverEvictsAnotherTier() {
        val caps = mapOf(Tier.OUTCOME to 5, Tier.LIFECYCLE to 5, Tier.SAMPLE to 5)
        val log = mutableListOf<String>()
        DiagnosticRetention.append(log, "${at(0)} p APPROACH_SUMMARY outcome=ARRIVED visit=v0", caps)
        DiagnosticRetention.append(log, "${at(1)} p STATE arrived -> cooldown", caps)
        var outcome = 0
        var lifecycle = 0
        var sample = 0
        for (second in 2L until 400) {
            val result = DiagnosticRetention.append(log, "${at(second)} p EXIT_OBSERVED_DURING_COOLDOWN", caps)
            outcome += result.outcome
            lifecycle += result.lifecycle
            sample += result.sample
        }
        assertEquals(0, outcome)
        assertEquals(0, lifecycle)
        assertEquals(398 - 5, sample)
        assertTrue(log[0].contains("APPROACH_SUMMARY"))
        assertTrue(log[1].contains("STATE arrived"))
        // The newest fixes are kept, in order.
        assertEquals((395L until 400).map { "${at(it)} p EXIT_OBSERVED_DURING_COOLDOWN" }, log.drop(2))
    }

    @Test
    fun lifecycleChatterNoLongerEvictsOutcomes() {
        // The Build 21 Xiaomi 15 pattern: ~30 lifecycle lines per visit.
        val caps = mapOf(Tier.OUTCOME to 10, Tier.LIFECYCLE to 10, Tier.SAMPLE to 10)
        val log = mutableListOf<String>()
        var outcomeEvicted = 0
        for (visit in 0L until 5) {
            outcomeEvicted += DiagnosticRetention.append(log, "${at(visit * 100)} p APPROACH_SUMMARY outcome=ARRIVED visit=v$visit", caps).outcome
            for (line in 1L..30) {
                outcomeEvicted += DiagnosticRetention.append(log, "${at(visit * 100 + line)} p STATE s$line", caps).outcome
            }
        }
        assertEquals(0, outcomeEvicted)
        assertEquals(5, log.count { it.contains("APPROACH_SUMMARY") })
    }

    @Test
    fun outcomesAreEvictedOldestFirstOnlyBeyondTheirOwnBudget() {
        val caps = mapOf(Tier.OUTCOME to 3, Tier.LIFECYCLE to 3, Tier.SAMPLE to 3)
        val log = mutableListOf<String>()
        var evicted = 0
        for (visit in 0L until 5) {
            evicted += DiagnosticRetention.append(log, "${at(visit)} p NOTIFICATION_SENT visit=v$visit", caps).outcome
        }
        assertEquals(2, evicted)
        assertEquals(listOf("v2", "v3", "v4"), log.map { it.substringAfterLast('=') })
    }

    @Test
    fun aBuild21LogConvergesWithoutLosingOutcomes() {
        // Upgrade: 500 entries stored under the APP-10D policy, mostly lifecycle.
        val log = mutableListOf<String>()
        for (index in 0L until 500) {
            log += if (index % 10 == 0L) "${at(index)} p APPROACH_SUMMARY outcome=ARRIVED visit=v$index"
            else "${at(index)} p STATE s$index"
        }
        val evicted = DiagnosticRetention.append(log, "${at(500)} p LOCATION distance=10.0m accuracy=3.0m")
        assertEquals(0, evicted.outcome)
        assertEquals(450 - 200, evicted.lifecycle)
        assertEquals(50, log.count { it.contains("APPROACH_SUMMARY") })
        assertEquals(200, log.count { DiagnosticRetention.tier(it) == Tier.LIFECYCLE })
        // The newest lifecycle lines survive, and order is kept.
        assertTrue(log.contains("${at(499)} p STATE s499"))
        assertEquals(log, log.sortedBy { it.substringBefore(' ') })
    }

    // --- Several days, several places, restarts --------------------------------

    /** One visit as the Build 21 pipeline logs it. */
    private fun visit(storage: JsonStorage, place: String, base: Long, visitId: String) {
        val lines = mutableListOf(
            "PRECISE_LOCATION_START_REQUESTED place=$place sinceReceive=200ms",
            "BACKGROUND_ENGINE_STARTING",
            "BACKGROUND_ENGINE_READY after=258ms queued=2",
            "$place BACKGROUND_SESSION_RESTORED state=COOLDOWN visit=old",
            "$place BACKGROUND_ENTER_RECEIVED",
            "$place STATE armed -> approaching",
            "$place APPROACH_STARTED visit=$visitId",
        )
        repeat(15) { lines += "$place LOCATION distance=${200 - it * 10}.0m accuracy=3.8m age=0s" }
        lines += listOf(
            "$place APPROACH_SUMMARY outcome=ARRIVED visit=$visitId samples=15",
            "$place STATE approaching -> arrived",
            "$place NOTIFICATION_REQUESTED visit=$visitId",
            "$place NOTIFICATION_SENT visit=$visitId",
            "$place STATE arrived -> cooldown",
            "PLACE_VERIFICATION_STOPPED place=$place service=STOPPING_AFTER_EVENTS events=1",
            "BACKGROUND_SERVICE_STOPPING after queued events",
        )
        lines.forEachIndexed { index, line -> DiagnosticRetention.record(storage, "${at(base + index)} $line") }
    }

    @Test
    fun fourDaysOfVisitsAtThreePlacesKeepEveryOutcomeAndTheNewestFixes() {
        var storage = JsonStorage()
        val places = listOf("legacy-place-1", "place-sagula", "place-anita")
        var visits = 0
        var lastBase = 0L
        for (day in 0L until 4) {
            for (trip in 0L until 3) {
                places.forEachIndexed { index, place ->
                    lastBase = day * 86_400 + trip * 3_600 + index * 60L
                    visit(storage, place, lastBase, "visit-$day-$trip-$index")
                    visits++
                }
                // Every trip ends in a new process (the service stops between visits).
                storage = storage.restarted()
            }
        }
        val log = storage.entries()
        assertEquals(36, visits)
        // Every visit's start, summary and notification result survives.
        assertEquals(36, log.count { it.contains("APPROACH_SUMMARY outcome=ARRIVED") })
        assertEquals(36, log.count { it.contains("NOTIFICATION_SENT") })
        assertEquals(36, log.count { it.contains("APPROACH_STARTED") })
        assertEquals(0L, storage.counter(DiagnosticRetention.EVICTED_OUTCOME))
        // GPS evidence of the latest visits is retained.
        assertEquals(150, log.count { DiagnosticRetention.tier(it) == Tier.SAMPLE })
        assertTrue(log.contains("${at(lastBase + 7 + 14)} place-anita LOCATION distance=60.0m accuracy=3.8m age=0s"))
        assertTrue(storage.counter(DiagnosticRetention.EVICTED_SAMPLE) > 0)
        assertTrue(log.size <= DiagnosticRetention.MAX_ENTRIES)
        assertEquals(log, log.sortedBy { it.substringBefore(' ') })
    }

    @Test
    fun countersAndEntriesSurviveARestartMidStream() {
        val caps = mapOf(Tier.OUTCOME to 2, Tier.LIFECYCLE to 2, Tier.SAMPLE to 2)
        var storage = JsonStorage()
        for (second in 0L until 5) DiagnosticRetention.record(storage, "${at(second)} p LOCATION distance=1.0m", caps)
        storage = storage.restarted()
        for (second in 5L until 8) DiagnosticRetention.record(storage, "${at(second)} p LOCATION distance=1.0m", caps)
        assertEquals(6L, storage.counter(DiagnosticRetention.EVICTED_SAMPLE))
        assertEquals(listOf(at(6), at(7)), storage.entries().map { it.substringBefore(' ') })
    }

    // --- Export header ---------------------------------------------------------

    @Test
    fun summaryLineStatesEachTierAndKeepsTheApp10dHistory() {
        val storage = JsonStorage()
        storage.counters.put(DiagnosticRetention.EVICTED_ROUTINE_LEGACY, 798L)
        storage.counters.put(DiagnosticRetention.EVICTED_CRITICAL_LEGACY, 111L)
        storage.counters.put(DiagnosticRetention.EVICTED_SAMPLE, 4L)
        val entries = listOf(
            "${at(0)} p APPROACH_SUMMARY outcome=ARRIVED visit=v",
            "${at(1)} p STATE arrived -> cooldown",
            "${at(2)} p LOCATION distance=1.0m",
        )
        assertEquals(
            "LOG_RETENTION retained=3 outcomes=1/300 lifecycle=1/200 samples=1/150 " +
                "evictedOutcome=0 evictedLifecycle=0 evictedSample=4 " +
                "beforeBuild22=evictedRoutine:798,evictedCritical:111 policy=PER_TIER",
            DiagnosticRetention.summaryLine(entries, storage::counter),
        )
        assertFalse(DiagnosticRetention.summaryLine(emptyList(), { 0L }).contains("beforeBuild22"))
    }
}
