package com.example.pingplace

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DesiredRegistrationStoreTest {
    private val target = DesiredRegistrationStore.Record(31.664913, 34.8, 300f, "  תזכורת קיימת  ")

    private class MemoryStorage : DesiredRegistrationStore.Storage {
        val values = mutableMapOf<String, Any?>()
        var legacyValues = listOf<Map<String, *>>()
        var runtimeValues = mapOf<String, Any?>()
        var diskRecord: String? = null
        var commitSucceeds = true
        var publishFailedWriteInMemory = false
        var omitWrite = false
        var writes = 0

        override fun current(): Map<String, *> = values.toMap()

        override fun legacy(): List<Map<String, *>> = legacyValues

        override fun runtime(): Map<String, *> = runtimeValues

        override fun commitRecord(serialized: String): Boolean {
            writes++
            if (!omitWrite && (commitSucceeds || publishFailedWriteInMemory)) {
                values[DesiredRegistrationStore.KEY] = serialized
            }
            if (commitSucceeds && !omitWrite) diskRecord = serialized
            return commitSucceeds
        }
    }

    private fun seed(storage: MemoryStorage) {
        DesiredRegistrationStore(storage).register(
            target.latitude,
            target.longitude,
            target.radius,
            target.reminderText,
        ) {}
    }

    private fun legacyConfiguration(prefix: String = "") =
        mapOf(
            "${prefix}latitude" to target.latitude.toString(),
            "${prefix}longitude" to target.longitude.toString(),
            "${prefix}radius" to target.radius.toString(),
        )

    private fun failure(expected: DesiredRegistrationStore.Failure, block: () -> Unit) {
        val error = assertThrows(DesiredRegistrationStore.StoreException::class.java, block)
        assertEquals(expected, error.failure)
        assertFalse(error.message!!.contains(target.latitude.toString()))
        assertFalse(error.message!!.contains(target.reminderText))
    }

    @Test
    fun freshConfigurationIsDurableBeforePlatformRegistration() {
        val storage = MemoryStorage()
        val store = DesiredRegistrationStore(storage)
        var registered = false
        store.register(target.latitude, target.longitude, target.radius, target.reminderText) {
            assertNotNull(storage.diskRecord)
            assertEquals(target, DesiredRegistrationStore(storage).load())
            registered = true
        }
        assertTrue(registered)
        assertEquals(target, store.load())
    }

    @Test
    fun eachLegacyNamespaceAndLayoutMigratesWithoutChangingTargetOrReminder() {
        for (sourceIndex in 0..2) {
            for (prefix in listOf("", "geofence_")) {
                val storage = MemoryStorage()
                val old = legacyConfiguration(prefix)
                if (sourceIndex == 0) storage.values.putAll(old)
                else
                    storage.legacyValues =
                        List(sourceIndex) {
                            if (it == sourceIndex - 1) old else emptyMap<String, Any>()
                        }
                storage.runtimeValues = mapOf("reminder_text" to target.reminderText)
                val before = storage.legacyValues.toList()

                assertEquals(target, DesiredRegistrationStore(storage).load())
                assertNotNull(storage.diskRecord)
                assertEquals(target, DesiredRegistrationStore(storage).load())
                assertEquals(before, storage.legacyValues)
                for ((key, value) in old) {
                    if (sourceIndex == 0) assertEquals(value, storage.values[key])
                }
                assertEquals(target.reminderText, storage.runtimeValues["reminder_text"])
            }
        }
    }

    @Test
    fun legacyReminderInTheRegistrationSourceIsPreservedWhenRuntimeReminderIsAbsent() {
        val storage = MemoryStorage()
        storage.values.putAll(legacyConfiguration() + ("reminderText" to target.reminderText))
        assertEquals(target, DesiredRegistrationStore(storage).load())
    }

    @Test
    fun missingConfigurationDoesNotWriteOrInventATarget() {
        val storage = MemoryStorage()
        assertNull(DesiredRegistrationStore(storage).load())
        assertEquals(0, storage.writes)
        failure(DesiredRegistrationStore.Failure.MISSING) {
            DesiredRegistrationStore(storage).restore { fail("Must not register a missing target") }
        }
    }

    @Test
    fun malformedOrPartialCanonicalRecordsNeverFallBackToLegacyData() {
        val storage = MemoryStorage()
        storage.legacyValues = listOf(legacyConfiguration())
        val malformed =
            listOf<Any?>(
                null,
                7,
                "",
                "{",
                "[]",
                "{\"schemaVersion\":1}",
                "{\"schemaVersion\":\"1\"}",
            )
        for (value in malformed) {
            storage.values[DesiredRegistrationStore.KEY] = value
            failure(DesiredRegistrationStore.Failure.CORRUPT) {
                DesiredRegistrationStore(storage).load()
            }
            assertEquals(value, storage.values[DesiredRegistrationStore.KEY])
        }
        assertEquals(0, storage.writes)
    }

    @Test
    fun unsupportedSchemaIsPreservedAndBlocksAllPlatformMutations() {
        val storage = MemoryStorage()
        seed(storage)
        val future = JSONObject(storage.diskRecord!!).put("schemaVersion", 99).toString()
        storage.values[DesiredRegistrationStore.KEY] = future
        storage.legacyValues = listOf(legacyConfiguration())
        val store = DesiredRegistrationStore(storage)
        failure(DesiredRegistrationStore.Failure.UNSUPPORTED_SCHEMA) { store.load() }
        failure(DesiredRegistrationStore.Failure.UNSUPPORTED_SCHEMA) {
            store.register(32.0, 35.0, 200f, "new") { fail("Must not register") }
        }
        failure(DesiredRegistrationStore.Failure.UNSUPPORTED_SCHEMA) {
            store.remove { fail("Must not remove") }
        }
        failure(DesiredRegistrationStore.Failure.UNSUPPORTED_SCHEMA) {
            store.restore { fail("Must not restore") }
        }
        assertEquals(future, storage.values[DesiredRegistrationStore.KEY])
    }

    @Test
    fun partialLegacyCoordinatesAreNotCombinedWithAnOlderTarget() {
        val storage = MemoryStorage()
        storage.values["latitude"] = "32.0"
        storage.legacyValues = listOf(legacyConfiguration())
        failure(DesiredRegistrationStore.Failure.CORRUPT) {
            DesiredRegistrationStore(storage).load()
        }
        assertEquals("32.0", storage.values["latitude"])
        assertNull(storage.diskRecord)
    }

    @Test
    fun invalidFieldsAndTrailingContentAreRejectedWithoutReplacingTheRecord() {
        val storage = MemoryStorage()
        seed(storage)
        val valid = storage.diskRecord!!
        val invalid =
            listOf(
                JSONObject(valid).put("latitude", 91).toString(),
                JSONObject(valid).put("longitude", "34.8").toString(),
                JSONObject(valid).put("radius", -1).toString(),
                JSONObject(valid).put("radius", Double.MAX_VALUE).toString(),
                JSONObject(valid).put("reminderText", 5).toString(),
                JSONObject(valid).put("desiredMonitoring", "true").toString(),
                JSONObject(valid).apply { remove("reminderText") }.toString(),
                valid + "trailing data",
            )
        for (value in invalid) {
            storage.values[DesiredRegistrationStore.KEY] = value
            failure(DesiredRegistrationStore.Failure.CORRUPT) {
                DesiredRegistrationStore(storage).restore { fail("Must not register corrupt data") }
            }
            assertEquals(valid, storage.diskRecord)
        }
    }

    @Test
    fun failedFreshWriteBlocksBothRemovalAndAddInTheRegistrationCallback() {
        val storage = MemoryStorage().apply { commitSucceeds = false }
        val platformCalls = mutableListOf<String>()
        failure(DesiredRegistrationStore.Failure.PERSISTENCE_FAILED) {
            DesiredRegistrationStore(storage).register(
                target.latitude,
                target.longitude,
                target.radius,
                target.reminderText,
            ) {
                platformCalls += "remove old"
                platformCalls += "add new"
            }
        }
        assertTrue(platformCalls.isEmpty())
        assertNull(storage.diskRecord)
    }

    @Test
    fun failedMigrationPreservesLegacyConfigurationAndReminderAndDoesNotRegister() {
        val storage =
            MemoryStorage().apply {
                values.putAll(legacyConfiguration())
                runtimeValues = mapOf("reminder_text" to target.reminderText)
                commitSucceeds = false
            }
        failure(DesiredRegistrationStore.Failure.PERSISTENCE_FAILED) {
            DesiredRegistrationStore(storage).restore {
                fail("Must not register after failed migration")
            }
        }
        assertEquals(legacyConfiguration(), storage.values)
        assertEquals(target.reminderText, storage.runtimeValues["reminder_text"])
        storage.commitSucceeds = true
        assertEquals(target, DesiredRegistrationStore(storage).load())
    }

    @Test
    fun failedDisableWriteDoesNotRemoveThePlatformGeofence() {
        val storage = MemoryStorage()
        seed(storage)
        val saved = storage.diskRecord
        storage.commitSucceeds = false
        failure(DesiredRegistrationStore.Failure.PERSISTENCE_FAILED) {
            DesiredRegistrationStore(storage).remove {
                fail("Must not remove before durable disable")
            }
        }
        assertEquals(saved, storage.diskRecord)
        assertEquals(target, DesiredRegistrationStore(storage).load())
    }

    @Test
    fun disabledRecordSurvivesReloadAndPreventsLegacyResurrectionWithoutRetries() {
        val storage = MemoryStorage()
        seed(storage)
        storage.legacyValues = listOf(legacyConfiguration())
        var removals = 0
        DesiredRegistrationStore(storage).remove {
            assertEquals(
                target.copy(desiredMonitoring = false),
                DesiredRegistrationStore(storage).load(),
            )
            removals++
        }
        assertEquals(1, removals)
        failure(DesiredRegistrationStore.Failure.DISABLED) {
            DesiredRegistrationStore(storage).restore {
                fail("Must not resurrect a disabled target")
            }
        }
        assertEquals(
            target.copy(desiredMonitoring = false),
            DesiredRegistrationStore(storage).load(),
        )
        assertEquals(1, removals)
    }

    @Test
    fun recoveryDoesNotTrustAnInMemoryValueFromAFailedCommit() {
        val storage =
            MemoryStorage().apply {
                commitSucceeds = false
                publishFailedWriteInMemory = true
            }
        val store = DesiredRegistrationStore(storage)
        failure(DesiredRegistrationStore.Failure.PERSISTENCE_FAILED) {
            store.register(target.latitude, target.longitude, target.radius, target.reminderText) {
                fail("Must not register")
            }
        }
        assertNotNull(storage.values[DesiredRegistrationStore.KEY])
        failure(DesiredRegistrationStore.Failure.PERSISTENCE_FAILED) {
            DesiredRegistrationStore(storage).restore {
                fail("Must recheck persistence before recovery")
            }
        }
        assertNull(storage.diskRecord)
    }

    @Test
    fun successfulCommitWithMismatchedReadbackDoesNotReachThePlatform() {
        val storage = MemoryStorage().apply { omitWrite = true }
        failure(DesiredRegistrationStore.Failure.PERSISTENCE_FAILED) {
            DesiredRegistrationStore(storage).register(
                target.latitude,
                target.longitude,
                target.radius,
                target.reminderText,
            ) {
                fail("Must not report a missing write as successful")
            }
        }
    }

    @Test
    fun replacementWithNoReminderArgumentPreservesTheExistingReminder() {
        val storage = MemoryStorage()
        seed(storage)
        DesiredRegistrationStore(storage).register(32.0, 35.0, 200f, null) {}
        assertEquals(
            target.copy(latitude = 32.0, longitude = 35.0, radius = 200f),
            DesiredRegistrationStore(storage).load(),
        )
    }

    @Test
    fun emptyReminderIsPreservedRatherThanSilentlySubstituted() {
        val storage =
            MemoryStorage().apply {
                values.putAll(legacyConfiguration())
                runtimeValues = mapOf("reminder_text" to "")
            }
        assertEquals("", DesiredRegistrationStore(storage).load()!!.reminderText)
    }

    @Test
    fun malformedLegacyReminderIsNotSilentlyReplacedByADefault() {
        val storage =
            MemoryStorage().apply {
                values.putAll(legacyConfiguration())
                runtimeValues = mapOf("reminder_text" to 42)
            }
        failure(DesiredRegistrationStore.Failure.CORRUPT) {
            DesiredRegistrationStore(storage).restore {
                fail("Must not register with an invented reminder")
            }
        }
        assertNull(storage.diskRecord)
        assertEquals(42, storage.runtimeValues["reminder_text"])
    }

    @Test
    fun unreadablePreferencesAreReportedWithoutAnyPlatformMutation() {
        val storage =
            object : DesiredRegistrationStore.Storage by MemoryStorage() {
                override fun current(): Map<String, *> =
                    throw IllegalStateException("private preference contents")
            }
        failure(DesiredRegistrationStore.Failure.READ_FAILED) {
            DesiredRegistrationStore(storage).restore { fail("Must not register unreadable data") }
        }
    }

    @Test
    fun persistenceExceptionDoesNotExposeStoredValues() {
        val storage =
            object : DesiredRegistrationStore.Storage {
                override fun current() = emptyMap<String, Any>()

                override fun legacy() = emptyList<Map<String, Any>>()

                override fun runtime() = emptyMap<String, Any>()

                override fun commitRecord(serialized: String): Boolean =
                    throw IllegalStateException(serialized)
            }
        failure(DesiredRegistrationStore.Failure.PERSISTENCE_FAILED) {
            DesiredRegistrationStore(storage).register(
                target.latitude,
                target.longitude,
                target.radius,
                target.reminderText,
            ) {}
        }
    }
}
