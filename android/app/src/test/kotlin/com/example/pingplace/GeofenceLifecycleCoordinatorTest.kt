package com.example.pingplace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GeofenceLifecycleCoordinatorTest {
    @Test
    fun newerOperationPreventsQueuedStalePlatformMutation() {
        val events = mutableListOf<String>()
        var firstDone: ((Boolean, String?) -> Unit)? = null
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.REGISTER,
            { done ->
                events += "register-start"
                firstDone = done
            },
            { completion -> events += "register-${completion.stale}" },
        )
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.REMOVE,
            { done ->
                events += "remove-start"
                done(true, null)
            },
            { completion -> events += "remove-${completion.success}" },
        )

        firstDone!!.invoke(true, null)

        assertEquals(listOf("register-start", "register-true", "remove-start", "remove-true"), events)
        assertFalse(events.contains("register-platform-add"))
    }

    @Test
    fun operationsAreSerializedAndCompletionIsExactlyOnce() {
        val events = mutableListOf<String>()
        var firstDone: ((Boolean, String?) -> Unit)? = null
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.RESTORE,
            { done ->
                events += "restore-start"
                firstDone = done
            },
            { events += "restore-complete" },
        )
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.RETRY_REMOVAL,
            { done ->
                events += "retry-start"
                done(true, null)
            },
            { events += "retry-complete" },
        )

        firstDone!!.invoke(true, null)
        firstDone!!.invoke(false, "late")

        assertEquals(
            listOf("restore-start", "restore-complete", "retry-start", "retry-complete"),
            events,
        )
        assertTrue(events.indexOf("restore-complete") < events.indexOf("retry-start"))
    }
    @Test
    fun overlappingRegisterRemoveRegisterSkipsTheStaleRemovalBeforeItMutatesPlatform() {
        val events = mutableListOf<String>()
        var firstDone: ((Boolean, String?) -> Unit)? = null
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.REGISTER,
            { done ->
                events += "register-old-start"
                firstDone = done
            },
            { completion -> events += "register-old-${completion.stale}" },
        )
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.REMOVE,
            { done ->
                events += "remove-platform"
                done(true, null)
            },
            { completion -> events += "remove-${completion.stale}" },
        )
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.REGISTER,
            { done ->
                events += "register-new-platform"
                done(true, null)
            },
            { completion -> events += "register-new-${completion.success}" },
        )

        firstDone!!.invoke(true, null)

        assertEquals(
            listOf(
                "register-old-start",
                "register-old-true",
                "remove-true",
                "register-new-platform",
                "register-new-true",
            ),
            events,
        )
    }
    @Test
    fun staleRestoreThenRegisterEndsWithLatestDurableStateAndPlatformTarget() {
        val boundary = FakeBoundary().apply { desired = "old" }
        var restoreDone: ((Boolean, String?) -> Unit)? = null
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.RESTORE,
            { done ->
                boundary.platform = boundary.desired
                restoreDone = done
            },
            { completion -> assertTrue(completion.stale) },
        )
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.REGISTER,
            { done ->
                boundary.desired = "new"
                boundary.platform = boundary.desired
                done(true, null)
            },
            { completion -> assertTrue(completion.success) },
        )

        boundary.desired = "old"
        restoreDone!!.invoke(true, null)

        assertEquals("new", boundary.desired)
        assertEquals("new", boundary.platform)
    }

    @Test
    fun staleRetryRemovalCannotPreventNewRegisterFromRestoringPlatform() {
        val boundary = FakeBoundary().apply {
            desired = "old"
            platform = "old"
            removalPending = true
        }
        var retryDone: ((Boolean, String?) -> Unit)? = null
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.RETRY_REMOVAL,
            { done ->
                boundary.platform = null
                boundary.removalPending = false
                retryDone = done
            },
            { completion -> assertTrue(completion.stale) },
        )
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.REGISTER,
            { done ->
                boundary.desired = "latest"
                boundary.platform = boundary.desired
                boundary.removalPending = false
                done(true, null)
            },
            { completion -> assertTrue(completion.success) },
        )

        retryDone!!.invoke(true, null)

        assertEquals("latest", boundary.desired)
        assertEquals("latest", boundary.platform)
        assertFalse(boundary.removalPending)
    }

    @Test
    fun failedRemovalLeavesDurableTombstoneForRetry() {
        val boundary = FakeBoundary().apply {
            desired = "disabled"
            platform = "old"
            removalPending = true
        }
        var result: GeofenceLifecycleCoordinator.Completion? = null
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.REMOVE,
            { done -> done(false, "Platform removal failed") },
            { result = it },
        )

        assertFalse(result!!.success)
        assertTrue(boundary.removalPending)
        assertEquals("old", boundary.platform)
    }

    @Test
    fun disabledRecoveryRemovesPlatformEvenWhenTombstoneWasLost() {
        val boundary = FakeBoundary().apply {
            desired = "disabled"
            platform = "old"
            removalPending = false
        }
        GeofenceLifecycleCoordinator.submit(
            GeofenceLifecycleCoordinator.Kind.RESTORE,
            { done ->
                if (boundary.desired == "disabled") {
                    boundary.removalPending = true
                    boundary.platform = null
                    boundary.removalPending = false
                }
                done(true, null)
            },
            { assertTrue(it.success) },
        )

        assertEquals("disabled", boundary.desired)
        assertEquals(null, boundary.platform)
        assertFalse(boundary.removalPending)
    }

    @Test
    fun multiPlaceTransitionAddsBeforeRemovingObsoleteIds() {
        val plan = MultiPlaceTransitionPlan.create(listOf("old", "keep"), listOf("keep", "new"))
        assertEquals(listOf("keep", "new"), plan.additions)
        assertEquals(listOf("old"), plan.removals)
        assertTrue(plan.removeLegacy)
    }

    @Test
    fun failedAddOrRemoveCannotConfirmTheNewRegistration() {
        val plan = MultiPlaceTransitionPlan.create(listOf("old"), listOf("new"))
        assertFalse(plan.confirmed(false, true, true))
        assertFalse(plan.confirmed(true, false, true))
        assertFalse(plan.confirmed(true, true, false))
        assertTrue(plan.confirmed(true, true, true))
    }

    @Test
    fun restartReusesTheDurableDesiredIdsWithoutDroppingThemOnFailure() {
        val desired = listOf("place-a", "place-b")
        val plan = MultiPlaceTransitionPlan.create(desired, desired)
        assertEquals(desired, plan.additions)
        assertTrue(plan.removals.isEmpty())
        assertFalse(plan.confirmed(false, true, true))
    }

    private data class FakeBoundary(
        var desired: String? = null,
        var platform: String? = null,
        var removalPending: Boolean = false,
    )
}
