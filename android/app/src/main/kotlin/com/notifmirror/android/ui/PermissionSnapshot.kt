package com.notifmirror.android.ui

import android.content.Context

internal data class PermissionSnapshot(
    val notificationAccess: Boolean,
    val postNotifications: Boolean,
    val batteryUnrestricted: Boolean,
    val allFiles: Boolean
) {
    val allCoreReady: Boolean
        get() = notificationAccess && postNotifications && batteryUnrestricted
}

internal fun readPermissionSnapshot(context: Context): PermissionSnapshot = PermissionSnapshot(
    notificationAccess = isNotificationListenerEnabled(context),
    postNotifications = hasPostNotificationsPermission(context),
    batteryUnrestricted = isIgnoringBatteryOptimizations(context),
    allFiles = isAllFilesAccessGranted()
)
