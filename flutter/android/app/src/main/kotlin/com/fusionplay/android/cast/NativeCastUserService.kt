package com.fusionplay.android.cast

import android.os.IBinder
import android.os.SystemClock
import androidx.annotation.Keep
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Runs only after the user grants Shizuku permission. No arbitrary shell API. */
@Keep
class NativeCastUserService : INativeCastService.Stub() {
    private val lease = NativeCastLease(::runCommand, SystemClock::elapsedRealtime)
    private val executor = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var lastError: String? = null
    private var owner: IBinder? = null
    private val death = IBinder.DeathRecipient { restore() }

    init {
        executor.scheduleWithFixedDelay({
            runCatching { lease.maintain() }.onFailure { lastError = it.message }
        }, 2, 2, TimeUnit.SECONDS)
    }

    @Synchronized override fun setPaused(paused: Boolean, lifetime: IBinder?): String {
        if (paused) {
            requireNotNull(lifetime) { "Missing client lifetime" }
            require(lifetime.isBinderAlive) { "Client disconnected" }
            if (owner != lifetime) {
                owner?.unlinkToDeath(death, 0)
                lifetime.linkToDeath(death, 0)
                owner = lifetime
            }
            lease.pause()
        } else {
            lease.resume()
            owner?.unlinkToDeath(death, 0)
            owner = null
        }
        lastError = null
        return getState()
    }

    override fun heartbeat(): String { lease.renew(); return getState() }
    override fun getState(): String = JSONObject()
        .put("paused", lease.paused)
        .put("error", lastError ?: JSONObject.NULL).toString()

    private fun restore() {
        runCatching { lease.resume() }.onFailure { lastError = it.message }
    }

    override fun destroy() {
        restore()
        executor.shutdownNow()
        kotlin.system.exitProcess(0)
    }

    private fun runCommand(arguments: List<String>): String {
        val process = ProcessBuilder(listOf("/system/bin/${arguments.first()}") + arguments.drop(1))
            .redirectErrorStream(true).start()
        if (!process.waitFor(6, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            error("原生投屏操作超时，请重试恢复")
        }
        val output = process.inputStream.bufferedReader().use { it.readText() }.take(16_384)
        // pidof returns 1 when the target is already stopped.
        check(process.exitValue() == 0 || (arguments.first() == "pidof" && process.exitValue() == 1)) { output }
        check(!output.contains("Error:") && !output.contains("Exception")) { output }
        return output.trim()
    }
}
