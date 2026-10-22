package com.fusionplay.android.cast

/** A short, renewable process pause. Package enabled settings are never changed. */
internal class NativeCastLease(
    private val command: (List<String>) -> String,
    private val nowMs: () -> Long,
) {
    @Volatile var paused = false
        private set
    private var expiresAt = 0L

    @Synchronized fun pause() {
        if (!paused) command(listOf("am", "force-stop", PACKAGE))
        paused = true
        renew()
    }

    @Synchronized fun renew() {
        if (paused) expiresAt = nowMs() + LEASE_MS
    }

    @Synchronized fun resume() {
        if (!paused) return
        command(listOf("am", "startservice", "-n", "$PACKAGE/.miplay.service.SmartShareService"))
        // A failed restore must remain visible and eligible for another retry.
        paused = false
        expiresAt = 0
    }

    @Synchronized fun maintain() {
        if (!paused) return
        if (nowMs() >= expiresAt) {
            resume()
        } else if (command(listOf("pidof", PACKAGE)).isNotBlank()) {
            command(listOf("am", "force-stop", PACKAGE))
        }
    }

    companion object {
        const val PACKAGE = "com.xiaomi.hyper_connect.tv"
        const val LEASE_MS = 15_000L
    }
}
