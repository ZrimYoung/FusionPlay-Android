package com.fusionplay.android.cast

import android.content.Context
import android.content.Intent
import android.provider.Settings

internal class NativeModeStoreAndroid(private val context: Context) : NativeModeStore {
    private val journal = context.getSharedPreferences("native_cast_mode_recovery", Context.MODE_PRIVATE)
    override fun readMode(): String? = Settings.Secure.getString(context.contentResolver, KEY)
    override fun readControlMode(): String? = Settings.Secure.getString(context.contentResolver, "control_square_mode")
    override fun writeMode(value: String?) {
        check(Settings.Secure.putString(context.contentResolver, KEY, value)) { "无法修改原生投屏配置，请核对一次授权" }
    }
    override fun notifyModeChanged() {
        context.sendBroadcast(Intent(ACTION).setPackage(NativeCastLease.PACKAGE))
    }
    override fun hasJournal() = journal.getBoolean("pending", false)
    override fun originalMode(): String? = journal.getString("original", null)
    override fun saveJournal(original: String?) {
        check(journal.edit().putString("original", original).putBoolean("pending", true).commit()) {
            "无法保存原生投屏恢复配置"
        }
    }
    override fun clearJournal() {
        check(journal.edit().clear().commit()) { "无法保存原生投屏恢复结果" }
    }
    companion object {
        const val KEY = "touping_square_mode"
        const val ACTION = "com.xiaomi.mitv.settings.SQUARE_MODE_CHANGE"
    }
}
