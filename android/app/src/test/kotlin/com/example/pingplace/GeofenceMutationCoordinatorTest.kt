package com.example.pingplace

import android.content.Context
import android.content.SharedPreferences
import android.content.ContextWrapper
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference

class GeofenceMutationCoordinatorTest {
    @Test
    fun removeCallbackKeepsCoordinatorActiveUntilCompletion() {
        val coordinator = GeofenceMutationCoordinator()
        val removeToken = coordinator.begin()
        assertNotNull(removeToken)

        // A concurrent register/restore request is queued while remove is
        // still awaiting its asynchronous platform callback.
        assertNull(coordinator.begin())
        assertTrue(coordinator.isActive(removeToken!!))

        assertTrue(coordinator.finish(removeToken))
        val next = coordinator.begin()
        assertNotNull(next)
        assertFalse(coordinator.isActive(removeToken))
        coordinator.finish(next!!)
    }

    @Test
    fun concurrentMutationsHaveOneActiveGeneration() {
        val coordinator = GeofenceMutationCoordinator()
        val start = CountDownLatch(1)
        val finished = CountDownLatch(2)
        val tokens = mutableListOf<GeofenceMutationCoordinator.Token?>()
        val first = Thread {
            start.await()
            synchronized(tokens) { tokens += coordinator.begin() }
            finished.countDown()
        }
        val second = Thread {
            start.await()
            synchronized(tokens) { tokens += coordinator.begin() }
            finished.countDown()
        }
        first.start()
        second.start()
        start.countDown()
        finished.await()

        assertTrue(tokens.count { it != null } <= 1)
        val active = tokens.firstOrNull { it != null }
        if (active != null) coordinator.finish(active)
    }

    @Test
    fun staleTokenCannotBeAppliedAfterAQueuedMutation() {
        val coordinator = GeofenceMutationCoordinator()
        val old = coordinator.begin()!!
        coordinator.requestReconcile()
        assertTrue(coordinator.finish(old))
        val current = coordinator.begin()!!

        assertFalse(coordinator.isActive(old))
        assertTrue(coordinator.isActive(current))
        coordinator.finish(current)
    }

    @Test
    fun persistenceCommitFailureIsObservableAndFailsClosed() {
        val context = TestContext(commitSucceeds = false)
        val record = RegistrationRecordStore.Record(
            registration = GeofenceRecovery.Registration(32.0, 34.8, 300f),
            reminderText = "test",
            desiredMonitoring = true,
            state = RegistrationRecordStore.State.REGISTRATION_PENDING,
            recoveryGeneration = 1L,
        )

        var failed = false
        try {
            RegistrationRecordStore.persist(context, record)
        } catch (_: IllegalStateException) {
            failed = true
        }
        assertTrue(failed)
        assertNull(RegistrationRecordStore.read(context))
    }

    @Test
    fun removalTombstoneSurvivesRecordClear() {
        val context = TestContext(commitSucceeds = true)
        RegistrationRecordStore.persistRemovalTombstone(context)
        RegistrationRecordStore.clearRecord(context)

        assertTrue(RegistrationRecordStore.hasRemovalTombstone(context))
        assertNull(RegistrationRecordStore.read(context))
    }
}

private class TestContext(commitSucceeds: Boolean) : ContextWrapper(null) {
    private val preferences = TestPreferences(commitSucceeds)

    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = preferences
}

private class TestPreferences(private val commitSucceeds: Boolean) : SharedPreferences {
    private val values = linkedMapOf<String, Any?>()

    override fun getAll(): MutableMap<String, *> = values.toMutableMap()
    override fun getString(key: String, defValue: String?): String? = values[key] as? String ?: defValue
    override fun getStringSet(key: String, defValues: Set<String>?): Set<String>? = values[key] as? Set<String> ?: defValues
    override fun getInt(key: String, defValue: Int): Int = values[key] as? Int ?: defValue
    override fun getLong(key: String, defValue: Long): Long = values[key] as? Long ?: defValue
    override fun getFloat(key: String, defValue: Float): Float = values[key] as? Float ?: defValue
    override fun getBoolean(key: String, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
    override fun contains(key: String): Boolean = values.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener) = Unit
    override fun edit(): SharedPreferences.Editor = TestEditor()

    private inner class TestEditor : SharedPreferences.Editor {
        private val changes = linkedMapOf<String, Any?>()
        private var clear = false

        override fun putString(key: String, value: String?): SharedPreferences.Editor = apply { changes[key] = value }
        override fun putStringSet(key: String, values: Set<String>?): SharedPreferences.Editor = apply { changes[key] = values }
        override fun putInt(key: String, value: Int): SharedPreferences.Editor = apply { changes[key] = value }
        override fun putLong(key: String, value: Long): SharedPreferences.Editor = apply { changes[key] = value }
        override fun putFloat(key: String, value: Float): SharedPreferences.Editor = apply { changes[key] = value }
        override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor = apply { changes[key] = value }
        override fun remove(key: String): SharedPreferences.Editor = apply { changes[key] = null }
        override fun clear(): SharedPreferences.Editor = apply { clear = true }
        override fun commit(): Boolean {
            if (!commitSucceeds) return false
            if (clear) values.clear()
            changes.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }
            return true
        }
        override fun apply() { commit() }
    }
}
