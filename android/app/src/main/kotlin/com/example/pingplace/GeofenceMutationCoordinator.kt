package com.example.pingplace

/**
 * Serializes the complete asynchronous remove/add lifecycle. Desired-state
 * writers can request a follow-up reconciliation while an operation is active;
 * no second platform mutation starts until the current callback completes.
 */
internal class GeofenceMutationCoordinator {
    data class Token(val serial: Long)

    private val lock = Any()
    private var nextSerial = 0L
    private var active: Token? = null
    private var reconcileRequested = false

    fun begin(): Token? = synchronized(lock) {
        if (active != null) {
            reconcileRequested = true
            return null
        }
        val token = Token(++nextSerial)
        active = token
        token
    }

    fun requestReconcile() = synchronized(lock) {
        if (active != null) reconcileRequested = true
    }

    fun <T> synchronizedMutation(block: () -> T): T = synchronized(lock) { block() }

    fun isActive(token: Token): Boolean = synchronized(lock) { active == token }

    fun finish(token: Token): Boolean = synchronized(lock) {
        if (active != token) return false
        active = null
        val requested = reconcileRequested
        reconcileRequested = false
        requested
    }
}
