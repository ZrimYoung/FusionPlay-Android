package com.fusionplay.android.cast

import org.junit.Assert.*
import org.junit.Test

class NativeModeLeaseTest {
    private class Store(var mode: String? = null) : NativeModeStore {
        var control: String? = null
        var journal = false
        var original: String? = null
        var failWrite = false
        var failNotify = false
        var failSave = false
        var notifications = 0
        override fun readMode() = mode
        override fun readControlMode() = control
        override fun writeMode(value: String?) { check(!failWrite); mode = value }
        override fun notifyModeChanged() { check(!failNotify); notifications++ }
        override fun hasJournal() = journal
        override fun originalMode() = original
        override fun saveJournal(original: String?) { check(!failSave); this.original = original; journal = true }
        override fun clearJournal() { journal = false }
    }
    private var time = 0L
    private fun lease(store: Store) = NativeModeLease(store) { time }
    private fun fails(block: () -> Unit) {
        try { block(); fail("Expected failure") } catch (_: IllegalStateException) {}
    }

    @Test fun restoresMissingAndExplicitZeroExactly() {
        for (value in listOf(null, "0")) {
            val store = Store(value)
            val lease = lease(store)
            lease.pause()
            assertEquals("1", store.mode)
            assertTrue(store.journal)
            lease.resume()
            assertEquals(value, store.mode)
            assertFalse(store.journal)
            assertFalse(lease.paused)
            assertEquals(2, store.notifications)
        }
    }
    @Test fun refusesExistingSystemModesWithoutTakingOwnership() {
        val store = Store("1")
        fails { lease(store).pause() }
        assertFalse(store.journal)
        store.mode = "0"
        store.control = "1"
        fails { lease(store).pause() }
        assertEquals("0", store.mode)
        assertFalse(store.journal)
    }
    @Test fun journalFailureDoesNotChangeSystemSetting() {
        val store = Store().apply { failSave = true }
        fails { lease(store).pause() }
        assertNull(store.mode)
        assertEquals(0, store.notifications)
    }
    @Test fun processRestartRecoversPreviousSession() {
        val store = Store()
        lease(store).pause()
        lease(store).recover()
        assertNull(store.mode)
        assertFalse(store.journal)
    }
    @Test fun notificationFailureKeepsJournalUntilRetryEvenAfterValueRestored() {
        val store = Store()
        val lease = lease(store)
        lease.pause()
        store.failNotify = true
        fails { lease.resume() }
        assertNull(store.mode)
        assertTrue(store.journal)
        store.failNotify = false
        lease.resume()
        assertFalse(store.journal)
        assertFalse(lease.paused)
    }
    @Test fun deniedRestoreRemainsRecoverable() {
        val store = Store()
        val lease = lease(store)
        lease.pause()
        store.failWrite = true
        fails { lease.resume() }
        assertTrue(lease.recoveryPending)
        store.failWrite = false
        lease(store).recover()
        assertNull(store.mode)
    }
    @Test fun heartbeatExpiryRestoresAndDoesNotOverwriteExternalChanges() {
        val store = Store()
        val lease = lease(store)
        lease.pause()
        time = 10_000
        lease.renew()
        time = 16_000
        lease.maintain()
        assertTrue(lease.paused)
        time = 25_000
        lease.maintain()
        assertNull(store.mode)
        lease.pause()
        store.mode = "0"
        lease.maintain()
        assertEquals("0", store.mode)
        assertFalse(lease.paused)
        assertFalse(store.journal)
    }
}
