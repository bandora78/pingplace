package com.example.pingplace

/**
 * Bounded background pipeline log, retained per tier (APP-10F).
 *
 * APP-10D evicted routine per-fix lines before anything else. In the Build 21
 * Xiaomi 15 report that left zero GPS fixes among the 500 retained entries:
 * even the newest fix went before two-day-old lifecycle lines, so the age of
 * the 6 November Delek fix and the position at the Delek EXIT were lost.
 * About 30 lifecycle lines per visit then also pushed out the oldest
 * outcomes (evictedCritical=111).
 *
 * Each tier now has its own budget and evicts only its own oldest entries:
 * a burst in one tier can never evict another tier's evidence.
 *
 * - OUTCOME: what happened to a visit (start, summary, notification result,
 *   suppression, exit and re-arm decisions, watchdog, blocked starts) and
 *   every failure. Largest budget; unknown messages land here, so a new
 *   failure line is never the first to go.
 * - LIFECYCLE: engine and service plumbing (state changes, starts, stops).
 * - SAMPLE: per-fix lines; the newest ones are what a field report needs.
 *
 * Entries keep their chronological order and format. Pure Kotlin, JVM tested.
 */
internal object DiagnosticRetention {
    enum class Tier { OUTCOME, LIFECYCLE, SAMPLE }

    /** About 50 visits of outcomes, 8 of lifecycle detail, 5 minutes of 2 s fixes. */
    val DEFAULT_CAPS: Map<Tier, Int> = mapOf(Tier.OUTCOME to 300, Tier.LIFECYCLE to 200, Tier.SAMPLE to 150)
    val MAX_ENTRIES: Int = DEFAULT_CAPS.values.sum()

    private val SAMPLE_MESSAGES = listOf(
        "LOCATION distance=",
        "LOCATION_IGNORED ",
        "LOCATION_REJECTED ",
        "EXIT_OBSERVED_DURING_COOLDOWN",
    )

    private val LIFECYCLE_MESSAGES = listOf(
        "STATE ",
        "BACKGROUND_SESSION_RESTORED",
        "BACKGROUND_ENTER_RECEIVED",
        "BACKGROUND_EXIT_RECEIVED",
        "BACKGROUND_EXIT_RESTORING_PERSISTED_STATE",
        "BACKGROUND_EVENT_QUEUED ",
        "BACKGROUND_ENGINE_STARTING",
        "BACKGROUND_ENGINE_READY",
        "BACKGROUND_SERVICE_STOPPING",
        "PRECISE_LOCATION_STARTED",
        "PRECISE_LOCATION_STOPPED",
        "PRECISE_LOCATION_KEPT",
        "PRECISE_LOCATION_UPDATES_STARTED",
        "PRECISE_LOCATION_START_REQUESTED",
        "PLACE_VERIFICATION_STOPPED",
        "FIRST_LOCATION_SAMPLE",
        "FOREGROUND_PROMOTED",
        "GEOFENCE_TARGETS_READ",
        "INNER_REACHED",
    )

    /** Same failure markers as the export's "Errors and failures" section. */
    private val FAILURE_MARKERS = listOf("FAILED", "ERROR", "BLOCKED", "NOT_READY", "NOT_ROUTED", "CORRUPT", "UNKNOWN")

    /** An entry is "<instant> [<placeId>] <MESSAGE>". */
    fun tier(entry: String): Tier {
        val native = entry.substringAfter(' ', "")
        val placeScoped = native.substringAfter(' ', "")
        fun startsWithAny(prefixes: List<String>) =
            prefixes.any { native.startsWith(it) || placeScoped.startsWith(it) }
        return when {
            FAILURE_MARKERS.any { native.contains(it) } -> Tier.OUTCOME
            startsWithAny(SAMPLE_MESSAGES) -> Tier.SAMPLE
            startsWithAny(LIFECYCLE_MESSAGES) -> Tier.LIFECYCLE
            else -> Tier.OUTCOME
        }
    }

    /** Per-fix lines (the APP-10D "routine" class). */
    fun isRoutine(entry: String): Boolean = tier(entry) == Tier.SAMPLE

    data class Evicted(val outcome: Int = 0, val lifecycle: Int = 0, val sample: Int = 0) {
        fun of(tier: Tier): Int = when (tier) {
            Tier.OUTCOME -> outcome
            Tier.LIFECYCLE -> lifecycle
            Tier.SAMPLE -> sample
        }
    }

    /**
     * Appends [entry]; while a tier holds more than its cap, removes that
     * tier's oldest entry. Entries of other tiers are never touched, so a
     * list written by an older build (or one over budget) converges tier by
     * tier without losing another tier's evidence.
     */
    fun append(entries: MutableList<String>, entry: String, caps: Map<Tier, Int> = DEFAULT_CAPS): Evicted {
        entries.add(entry)
        val tiers = entries.map(::tier).toMutableList()
        val evicted = IntArray(Tier.values().size)
        for (tier in Tier.values()) {
            var excess = tiers.count { it == tier } - caps.getValue(tier)
            var index = 0
            while (excess > 0 && index < entries.size) {
                if (tiers[index] == tier) {
                    entries.removeAt(index)
                    tiers.removeAt(index)
                    excess--
                    evicted[tier.ordinal]++
                } else index++
            }
        }
        return Evicted(evicted[Tier.OUTCOME.ordinal], evicted[Tier.LIFECYCLE.ordinal], evicted[Tier.SAMPLE.ordinal])
    }

    const val EVICTED_OUTCOME = "diagnostics_evicted_outcome"
    const val EVICTED_LIFECYCLE = "diagnostics_evicted_lifecycle"
    const val EVICTED_SAMPLE = "diagnostics_evicted_sample"

    /** APP-10D totals; no longer incremented, reported as history. */
    const val EVICTED_ROUTINE_LEGACY = "diagnostics_evicted_routine"
    const val EVICTED_CRITICAL_LEGACY = "diagnostics_evicted_critical"

    fun counterKey(tier: Tier): String = when (tier) {
        Tier.OUTCOME -> EVICTED_OUTCOME
        Tier.LIFECYCLE -> EVICTED_LIFECYCLE
        Tier.SAMPLE -> EVICTED_SAMPLE
    }

    /** Where the log lives: SharedPreferences on the device, a map in tests. */
    interface Storage {
        fun entries(): MutableList<String>
        fun counter(key: String): Long

        /** Writes the entries and adds the counter increments in one edit. */
        fun save(entries: List<String>, counterIncrements: Map<String, Long>)
    }

    /** Appends one entry to persisted storage; state is re-read every time, so it survives process restarts. */
    fun record(storage: Storage, entry: String, caps: Map<Tier, Int> = DEFAULT_CAPS) {
        val entries = storage.entries()
        val evicted = append(entries, entry, caps)
        val increments = Tier.values()
            .filter { evicted.of(it) > 0 }
            .associate { counterKey(it) to evicted.of(it).toLong() }
        storage.save(entries, increments)
    }

    /**
     * First line of the exported log: what each tier holds and has dropped,
     * so a missing visit can be told apart from evicted evidence.
     */
    fun summaryLine(entries: List<String>, counter: (String) -> Long, caps: Map<Tier, Int> = DEFAULT_CAPS): String {
        val held = entries.groupingBy(::tier).eachCount()
        return buildString {
            append("LOG_RETENTION retained=").append(entries.size)
            append(" outcomes=").append(held[Tier.OUTCOME] ?: 0).append('/').append(caps.getValue(Tier.OUTCOME))
            append(" lifecycle=").append(held[Tier.LIFECYCLE] ?: 0).append('/').append(caps.getValue(Tier.LIFECYCLE))
            append(" samples=").append(held[Tier.SAMPLE] ?: 0).append('/').append(caps.getValue(Tier.SAMPLE))
            append(" evictedOutcome=").append(counter(EVICTED_OUTCOME))
            append(" evictedLifecycle=").append(counter(EVICTED_LIFECYCLE))
            append(" evictedSample=").append(counter(EVICTED_SAMPLE))
            val legacyRoutine = counter(EVICTED_ROUTINE_LEGACY)
            val legacyCritical = counter(EVICTED_CRITICAL_LEGACY)
            if (legacyRoutine > 0 || legacyCritical > 0) {
                append(" beforeBuild22=evictedRoutine:").append(legacyRoutine)
                append(",evictedCritical:").append(legacyCritical)
            }
            append(" policy=PER_TIER")
        }
    }
}
