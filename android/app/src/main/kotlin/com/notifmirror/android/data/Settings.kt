package com.notifmirror.android.data

import android.content.Context
import android.content.SharedPreferences

class Settings private constructor(ctx: Context) {
    private val prefs: SharedPreferences = ctx.applicationContext
        .getSharedPreferences("settings", Context.MODE_PRIVATE)

    var skipSilent: Boolean
        get() = prefs.getBoolean(KEY_SKIP_SILENT, false)
        set(value) = prefs.edit().putBoolean(KEY_SKIP_SILENT, value).apply()

    var clipboardTipDismissed: Boolean
        get() = prefs.getBoolean(KEY_CLIPBOARD_TIP_DISMISSED, false)
        set(value) = prefs.edit().putBoolean(KEY_CLIPBOARD_TIP_DISMISSED, value).apply()

    /** Stable per-install identifier so multiple Android phones can connect
     *  simultaneously to the same Mac even if they share the same model name. */
    val deviceId: String
        get() {
            val existing = prefs.getString(KEY_DEVICE_ID, null)
            if (!existing.isNullOrEmpty()) return existing
            val fresh = java.util.UUID.randomUUID().toString().replace("-", "").take(16)
            prefs.edit().putString(KEY_DEVICE_ID, fresh).apply()
            return fresh
        }

    companion object {
        private const val KEY_SKIP_SILENT = "skip_silent"
        private const val KEY_CLIPBOARD_TIP_DISMISSED = "clipboard_tip_dismissed"
        private const val KEY_DEVICE_ID = "device_id"

        @Volatile private var instance: Settings? = null

        fun get(context: Context): Settings =
            instance ?: synchronized(this) {
                instance ?: Settings(context).also { instance = it }
            }
    }
}
