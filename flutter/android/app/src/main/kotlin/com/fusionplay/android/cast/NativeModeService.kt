package com.fusionplay.android.cast

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** An ordinary App process; its lifetime does not depend on adbd or Shizuku. */
class NativeModeService : Service() {
    private lateinit var lease: NativeModeLease
    private val executor = Executors.newSingleThreadScheduledExecutor()
    @Volatile private var lastError: String? = null
    private var owner: IBinder? = null
    private val death = IBinder.DeathRecipient { executor.execute { restore() } }
    private val binder = object : INativeCastService.Stub() {
        override fun setPaused(paused: Boolean, lifetime: IBinder?): String = synchronized(this@NativeModeService) {
            try {
                if (paused) {
                    requireNotNull(lifetime)
                    check(lifetime.isBinderAlive) { "应用连接已断开" }
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
                Log.i(TAG, "mode switch paused=${lease.paused}")
            } catch (error: Exception) {
                lastError = error.message ?: "原生投屏切换失败"
                Log.e(TAG, "mode switch failed", error)
            }
            getState()
        }
        override fun heartbeat(): String { lease.renew(); return getState() }
        override fun getState(): String = JSONObject()
            .put("paused", lease.paused || lease.recoveryPending)
            .put("error", lastError ?: JSONObject.NULL).toString()
        override fun destroy() { restore(); stopSelf() }
    }

    override fun onCreate() {
        super.onCreate()
        lease = NativeModeLease(NativeModeStoreAndroid(this), SystemClock::elapsedRealtime)
        restore() // Recover an interrupted session before accepting a new pause.
        executor.scheduleWithFixedDelay({
            runCatching { lease.maintain() }
                .onSuccess { if (!lease.recoveryPending) lastError = null }
                .onFailure { lastError = it.message }
        }, 2, 2, TimeUnit.SECONDS)
    }
    override fun onBind(intent: Intent): IBinder = binder
    override fun onUnbind(intent: Intent): Boolean { restore(); return false }
    override fun onDestroy() {
        restore()
        owner?.unlinkToDeath(death, 0)
        executor.shutdownNow()
        super.onDestroy()
    }
    @Synchronized private fun restore() {
        runCatching { lease.resume() }
            .onSuccess { lastError = null }
            .onFailure { lastError = it.message; Log.e(TAG, "restore pending", it) }
    }
    companion object { const val TAG = "FusionNativeMode" }
}
