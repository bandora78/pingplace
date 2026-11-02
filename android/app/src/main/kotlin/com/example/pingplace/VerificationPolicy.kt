package com.example.pingplace

/**
 * Pure decisions for the temporary precise-location service, kept free of
 * Android types so they can be unit tested.
 */
internal object VerificationPolicy {
    /** Fix interval while verifying. A visit can last under a minute. */
    const val INTERVAL_MS = 2_000L
    const val MIN_INTERVAL_MS = 1_000L

    /** How long the headless Dart side may take to report ready. */
    const val ENGINE_READY_TIMEOUT_MS = 15_000L

    /**
     * A later, shorter watchdog (for example an EXIT re-arm check for another
     * place) must never cut an approach that still has time left.
     */
    fun extendedDeadline(current: Long?, now: Long, delayMillis: Long): Long =
        maxOf(current ?: Long.MIN_VALUE, now + delayMillis)

    data class StopDecision(val stopService: Boolean, val remaining: List<String>)

    /** One place finishing stops the service only if no other place is verifying. */
    fun stopPlace(active: Collection<String>, placeId: String): StopDecision {
        val remaining = active.filter { it != placeId }
        return StopDecision(stopService = remaining.isEmpty(), remaining = remaining)
    }

    /**
     * Samples produced before the headless Flutter engine exists must be
     * queued, not dropped: the engine boots in parallel with the first fix.
     */
    fun shouldQueueSample(engineCreated: Boolean, engineStarting: Boolean): Boolean =
        engineCreated || engineStarting
}
