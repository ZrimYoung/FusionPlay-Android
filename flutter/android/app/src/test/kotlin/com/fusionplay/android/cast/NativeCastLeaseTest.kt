package com.fusionplay.android.cast

import org.junit.Assert.*
import org.junit.Test

class NativeCastLeaseTest {
    private var time = 0L
    private var processRunning = true
    private var failRestore = false
    private val commands = mutableListOf<List<String>>()
    private fun lease() = NativeCastLease({ args ->
        commands += args
        when (args.take(2)) {
            listOf("am", "force-stop") -> processRunning = false
            listOf("am", "startservice") -> {
                check(!failRestore) { "restore unavailable" }
                processRunning = true
            }
        }
        if (args.first() == "pidof" && processRunning) "1234" else ""
    }, { time })

    @Test fun expirationRestoresWithoutChangingPackageEnabledSettings() {
        val lease = lease()
        lease.pause()
        assertFalse(processRunning)
        time = NativeCastLease.LEASE_MS
        lease.maintain()
        assertFalse(lease.paused)
        assertTrue(processRunning)
        assertTrue(commands.none { it.first() == "pm" })
    }

    @Test fun heartbeatExtendsLeaseButDoesNotPauseAnInactiveLease() {
        val lease = lease()
        lease.renew()
        assertFalse(lease.paused)
        lease.pause()
        time = 10_000
        lease.renew()
        time = 16_000
        lease.maintain()
        assertTrue(lease.paused)
        time = 25_000
        lease.maintain()
        assertFalse(lease.paused)
    }

    @Test fun watchdogRestartIsStoppedOnlyDuringActiveLease() {
        val lease = lease()
        lease.pause()
        processRunning = true
        lease.maintain()
        assertFalse(processRunning)
        lease.resume()
        lease.maintain()
        assertTrue(processRunning)
    }

    @Test fun failedRestoreRemainsPendingAndCanBeRetried() {
        val lease = lease()
        lease.pause()
        failRestore = true
        time = NativeCastLease.LEASE_MS
        try { lease.maintain(); fail("Expected restore failure") } catch (_: IllegalStateException) {}
        assertTrue(lease.paused)
        failRestore = false
        lease.maintain()
        assertFalse(lease.paused)
        assertTrue(processRunning)
    }
}
