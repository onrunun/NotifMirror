package com.notifmirror.android.service

import android.content.Context
import android.util.Log
import com.notifmirror.android.BuildConfig
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Debug-only diagnostic file logger.
 *
 * Strictly disabled in release builds so transfer metadata and paths are never
 * written to disk. In debug builds, writes into the app-private cache directory
 * (never shared external storage) with a hard size cap.
 */
internal object DebugLog {
    private const val TAG = "DebugLog"
    private const val FILE_NAME = "notifmirror_debug.log"
    private const val MAX_BYTES = 1024L * 1024L

    @Volatile
    private var file: File? = null
    private val fmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    fun init(context: Context) {
        if (!BuildConfig.DEBUG) return
        file = File(context.applicationContext.cacheDir, FILE_NAME)
    }

    @Synchronized
    fun line(msg: String) {
        if (!BuildConfig.DEBUG) return
        val target = file ?: return
        try {
            if (target.exists() && target.length() >= MAX_BYTES) {
                target.writeText("")
            }
            target.appendText("${fmt.format(Date())} $msg\n")
        } catch (e: IOException) {
            Log.w(TAG, "debug log write failed", e)
        }
    }
}
