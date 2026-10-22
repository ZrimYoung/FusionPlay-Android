package com.fusionplay.android.cast

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Binder
import android.os.IBinder
import com.fusionplay.android.BuildConfig
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import rikka.shizuku.Shizuku

data class NativeCastState(
    val supported: Boolean = false,
    val paused: Boolean = false,
    val busy: Boolean = false,
    val message: String = "",
) {
    fun toMap(): Map<String, Any> = mapOf(
        "supported" to supported, "paused" to paused, "busy" to busy, "message" to message,
    )
}

class NativeCastManager(private val context: Context, private val scope: CoroutineScope) {
    private val supported = runCatching {
        context.packageManager.getApplicationInfo(NativeCastLease.PACKAGE, 0)
    }.isSuccess
    private val mutableState = MutableStateFlow(NativeCastState(supported = supported))
    val state = mutableState.asStateFlow()
    private val mutex = Mutex()
    private val lifetime = Binder()
    private var service: INativeCastService? = null
    private var pending: CompletableDeferred<INativeCastService>? = null
    private var foreground = false
    private var restoreJob: Job? = null
    private val args = Shizuku.UserServiceArgs(ComponentName(context, NativeCastUserService::class.java))
        .daemon(true).processNameSuffix("native_cast_control").debuggable(BuildConfig.DEBUG).version(1)
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val connected = INativeCastService.Stub.asInterface(binder)
            service = connected
            pending?.complete(connected)
        }
        override fun onServiceDisconnected(name: ComponentName) {
            service = null
            pending?.completeExceptionally(IllegalStateException("授权服务已断开"))
            mutableState.value = mutableState.value.copy(busy = false, message = "授权服务已断开，原生投屏将自动恢复")
        }
    }
    private val received = Shizuku.OnBinderReceivedListener { refresh() }
    private val died = Shizuku.OnBinderDeadListener {
        service = null
        mutableState.value = mutableState.value.copy(busy = false, message = "Shizuku 已停止，请重新启动后核对原生投屏状态")
    }
    private val permission = Shizuku.OnRequestPermissionResultListener { code, result ->
        if (code == PERMISSION_REQUEST) {
            mutableState.value = mutableState.value.copy(message = if (result == PackageManager.PERMISSION_GRANTED) {
                "已授权，可开启暂停开关"
            } else "未授权，原生投屏保持原状")
        }
    }

    init {
        if (supported) {
            Shizuku.addBinderReceivedListenerSticky(received)
            Shizuku.addBinderDeadListener(died)
            Shizuku.addRequestPermissionResultListener(permission)
            refresh()
            scope.launch {
                while (true) {
                    delay(5_000)
                    if (foreground && state.value.paused) {
                        runCatching {
                            val data = withContext(Dispatchers.IO) { service?.heartbeat() }
                            if (data != null) accept(data)
                        }.onFailure { mutableState.value = state.value.copy(message = "连接中断，原生投屏将在短时间内自动恢复") }
                    }
                }
            }
        }
    }

    private fun refresh() {
        mutableState.value = state.value.copy(message = when {
            !Shizuku.pingBinder() -> "需要先启动 Shizuku 并授权"
            Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED -> "首次使用需要允许 Shizuku 授权"
            else -> "关闭开关或离开本应用后恢复原生投屏"
        })
    }

    private suspend fun getService(): INativeCastService {
        service?.takeIf { it.asBinder().isBinderAlive }?.let { return it }
        val result = CompletableDeferred<INativeCastService>()
        pending = result
        return try {
            Shizuku.bindUserService(args, connection)
            withTimeout(10_000) { result.await() }
        } finally {
            pending = null
        }
    }

    suspend fun setPaused(paused: Boolean) = mutex.withLock {
        check(supported) { "本机未安装对应的原生投屏组件" }
        check(!paused || foreground) { "请在应用前台使用暂停开关" }
        if (!Shizuku.pingBinder()) {
            refresh()
            error("请先启动 Shizuku；盒子重启后需要重新启动授权服务")
        }
        if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
            Shizuku.requestPermission(PERMISSION_REQUEST)
            mutableState.value = state.value.copy(message = "请允许授权后再次操作开关")
            return@withLock
        }
        mutableState.value = state.value.copy(busy = true)
        try {
            val remote = getService()
            val data = withContext(Dispatchers.IO) { remote.setPaused(paused, lifetime) }
            accept(data)
        } catch (error: Exception) {
            mutableState.value = state.value.copy(message = "操作未完成：${error.message}")
            throw error
        } finally {
            mutableState.value = state.value.copy(busy = false)
        }
    }

    private fun accept(raw: String) {
        val data = JSONObject(raw)
        val paused = data.getBoolean("paused")
        val error = data.optString("error").takeUnless { it.isBlank() || it == "null" }
        mutableState.value = state.value.copy(paused = paused, message = error ?: if (paused) {
            "原生投屏已暂时暂停；关闭开关或离开应用后恢复"
        } else "原生投屏已恢复")
    }

    fun setForeground(value: Boolean) {
        foreground = value
        restoreJob?.cancel()
        if (value) {
            if (supported) refresh()
        } else {
            restoreJob = scope.launch {
                delay(1_000)
                if (!foreground && state.value.paused) runCatching { setPaused(false) }
            }
        }
    }

    fun close() {
        if (!supported) return
        foreground = false
        // The user service also restores on lifetime death and lease expiry.
        service?.let { remote -> scope.launch(Dispatchers.IO) { runCatching { remote.setPaused(false, lifetime) } } }
        Shizuku.removeBinderReceivedListener(received)
        Shizuku.removeBinderDeadListener(died)
        Shizuku.removeRequestPermissionResultListener(permission)
    }

    companion object { private const val PERMISSION_REQUEST = 7021 }
}
