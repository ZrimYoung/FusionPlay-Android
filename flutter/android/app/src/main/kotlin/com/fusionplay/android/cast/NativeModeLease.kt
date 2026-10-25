package com.fusionplay.android.cast

/** The journal is durable before any system change. Null is a missing setting, not "0". */
internal interface NativeModeStore {
    fun readMode(): String?
    fun readControlMode(): String?
    fun writeMode(value: String?)
    fun notifyModeChanged()
    fun hasJournal(): Boolean
    fun originalMode(): String?
    fun saveJournal(original: String?)
    fun clearJournal()
}

internal class NativeModeLease(private val store: NativeModeStore, private val nowMs: () -> Long) {
    var paused = false
        private set
    val recoveryPending get() = store.hasJournal()
    private var expiresAt = 0L

    @Synchronized fun recover() {
        if (!store.hasJournal()) return
        // Another system/user change takes precedence over our old lease.
        if (store.readMode() == "1") {
            val original = store.originalMode()
            store.writeMode(original)
            check(store.readMode() == original) { "原生投屏配置恢复失败" }
        }
        // Retry notification even when an earlier restore already wrote the setting.
        store.notifyModeChanged()
        store.clearJournal()
        paused = false
        expiresAt = 0L
    }

    @Synchronized fun pause() {
        if (paused) { renew(); return }
        recover()
        val original = store.readMode()
        check(original == null || original == "0") { "原生投屏已由系统设置暂停，请先恢复系统设置" }
        check(store.readControlMode() != "1") { "系统控制模式已开启，无法接管原生投屏" }
        store.saveJournal(original)
        try {
            store.writeMode("1")
            check(store.readMode() == "1") { "原生投屏配置写入失败" }
            store.notifyModeChanged()
            paused = true
            renew()
        } catch (error: Exception) {
            runCatching { recover() }.onFailure { error.addSuppressed(it) }
            throw error
        }
    }

    @Synchronized fun renew() {
        if (paused) expiresAt = nowMs() + NativeCastLease.LEASE_MS
    }

    @Synchronized fun resume() = recover()

    @Synchronized fun maintain() {
        if (paused && store.readMode() != "1") {
            // Do not reassert a pause after an external setting change.
            paused = false
            recover()
        } else if ((!paused && recoveryPending) || (paused && nowMs() >= expiresAt)) {
            recover()
        }
    }
}
