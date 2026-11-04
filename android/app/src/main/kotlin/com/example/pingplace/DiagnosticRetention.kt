package com.example.pingplace

/**
 * APP-10D: the background log is bounded, and in the Build 19 field test
 * repeated per-fix lines (about 150 EXIT_OBSERVED_DURING_COOLDOWN and 196
 * LOCATION_IGNORED) evicted every visit summary and notification result.
 *
 * Routine per-fix lines are now evicted before anything else, so state
 * transitions, visit summaries, notification outcomes, startup failures and
 * errors survive frequent GPS events. Entries keep their chronological order
 * and format. Pure Kotlin, so it is unit tested on the JVM.
 */
internal object DiagnosticRetention {
    const val MAX_ENTRIES = 500

    /** Per-fix or per-event lines that are only useful in aggregate. */
    private val ROUTINE_MESSAGES = listOf(
        "LOCATION distance=",
        "LOCATION_IGNORED ",
        "LOCATION_REJECTED ",
        "EXIT_OBSERVED_DURING_COOLDOWN",
        "BACKGROUND_EVENT_QUEUED ",
    )

    /**
     * An entry is "<instant> [<placeId>] <MESSAGE>". Unknown messages count as
     * critical, so a new failure line is never the first to go.
     */
    fun isRoutine(entry: String): Boolean {
        val native = entry.substringAfter(' ', "")
        val placeScoped = native.substringAfter(' ', "")
        return ROUTINE_MESSAGES.any { native.startsWith(it) || placeScoped.startsWith(it) }
    }

    data class Evicted(val routine: Int, val critical: Int)

    /**
     * Appends [entry] and trims [entries] to [max], evicting the oldest
     * routine entry first and the oldest critical entry only when no routine
     * entry is left.
     */
    fun append(entries: MutableList<String>, entry: String, max: Int = MAX_ENTRIES): Evicted {
        entries.add(entry)
        var routine = 0
        var critical = 0
        while (entries.size > max) {
            val index = entries.indexOfFirst(::isRoutine)
            if (index >= 0) {
                entries.removeAt(index)
                routine++
            } else {
                entries.removeAt(0)
                critical++
            }
        }
        return Evicted(routine, critical)
    }

    /**
     * First line of the exported log: how much history the bounded log has
     * dropped, so a missing visit can be told apart from evicted evidence.
     */
    fun summaryLine(retained: Int, evictedRoutine: Long, evictedCritical: Long): String =
        "LOG_RETENTION retained=$retained max=$MAX_ENTRIES " +
            "evictedRoutine=$evictedRoutine evictedCritical=$evictedCritical " +
            "policy=ROUTINE_FIRST"
}
