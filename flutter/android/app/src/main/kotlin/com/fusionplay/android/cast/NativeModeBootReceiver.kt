package com.fusionplay.android.cast

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log

class NativeModeBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val result = goAsync()
        Thread {
            try {
                NativeModeLease(NativeModeStoreAndroid(context), SystemClock::elapsedRealtime).recover()
            } catch (error: Exception) {
                Log.e(NativeModeService.TAG, "boot recovery pending until App opens", error)
            } finally { result.finish() }
        }.start()
    }
}
