package com.notifmirror.android.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.notifmirror.android.data.PairingStore
import com.notifmirror.android.data.Settings
import com.notifmirror.android.service.MirrorCore
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    onPair: () -> Unit,
    onOpenFilter: () -> Unit
) {
    val context = LocalContext.current
    val store = remember { PairingStore(context) }
    val settings = remember { Settings.get(context) }
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    var paired by remember { mutableStateOf(store.isPaired) }
    val pairing = remember(paired) { store.load() }
    var perms by remember { mutableStateOf(readPermissionSnapshot(context)) }
    var requestedPostNotif by remember { mutableStateOf(false) }
    var skipSilent by remember { mutableStateOf(settings.skipSilent) }
    var confirmForget by remember { mutableStateOf(false) }

    val postNotifLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        requestedPostNotif = true
        perms = perms.copy(postNotifications = granted)
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                paired = store.isPaired
                perms = readPermissionSnapshot(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings", fontWeight = FontWeight.SemiBold) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent)
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
        containerColor = MaterialTheme.colorScheme.background
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            PairedMacCard(
                paired = paired,
                macName = pairing?.name,
                macHost = pairing?.let { "${it.host}:${it.port}" },
                onPair = onPair,
                onForget = { confirmForget = true }
            )

            MirroringPreferencesCard(
                skipSilent = skipSilent,
                onSkipSilentChange = {
                    skipSilent = it
                    settings.skipSilent = it
                },
                onOpenFilter = onOpenFilter
            )

            SettingsPermissionsCard(
                perms = perms,
                onOpenNotificationAccess = { openNotificationAccessSettings(context) },
                onOpenPostNotifications = {
                    if (perms.postNotifications || (
                            requestedPostNotif &&
                                !shouldShowRationale(context, Manifest.permission.POST_NOTIFICATIONS)
                            )
                    ) {
                        openAppNotificationSettings(context)
                    } else {
                        requestedPostNotif = true
                        postNotifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                },
                onOpenBatteryOptimization = { openBatteryOptimizationSettings(context) },
                onOpenAllFilesAccess = { openAllFilesAccessSettings(context) }
            )

            ShortcutsInfoCard()
            Spacer(Modifier.height(24.dp))
        }
    }

    if (confirmForget) {
        ForgetPairingConfirmDialog(
            macName = pairing?.name,
            onDismiss = { confirmForget = false },
            onConfirm = {
                confirmForget = false
                store.clear()
                MirrorCore.notifyPairingChanged()
                paired = false
                scope.launch { snackbarHostState.showSnackbar("Pairing removed") }
            }
        )
    }
}

@Composable
private fun PairedMacCard(
    paired: Boolean,
    macName: String?,
    macHost: String?,
    onPair: () -> Unit,
    onForget: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                "Paired Mac",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurface
            )
            if (paired && macName != null) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(MaterialTheme.colorScheme.surface)
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primaryContainer),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            macName.take(1).uppercase(),
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onPrimaryContainer
                        )
                    }
                    Spacer(Modifier.size(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(macName, style = MaterialTheme.typography.bodyLarge)
                        Text(
                            macHost.orEmpty(),
                            style = MaterialTheme.typography.bodySmall.copy(fontFeatureSettings = "tnum"),
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                Text(
                    "No Mac paired yet.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                FilledTonalButton(onClick = onPair, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Filled.QrCodeScanner, contentDescription = null)
                    Spacer(Modifier.size(8.dp))
                    Text(if (paired) "Re-pair" else "Pair with Mac")
                }
                if (paired) {
                    TextButton(onClick = onForget) {
                        Text("Forget", color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
    }
}

@Composable
private fun MirroringPreferencesCard(
    skipSilent: Boolean,
    onSkipSilentChange: (Boolean) -> Unit,
    onOpenFilter: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        )
    ) {
        Column(modifier = Modifier.fillMaxWidth().padding(4.dp)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 60.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .clickable(onClick = onOpenFilter)
                    .padding(horizontal = 16.dp, vertical = 12.dp)
                    .semantics(mergeDescendants = true) {},
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(MaterialTheme.colorScheme.secondaryContainer),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        Icons.Filled.Apps,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSecondaryContainer
                    )
                }
                Spacer(Modifier.size(14.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text("Mirrored apps", style = MaterialTheme.typography.titleSmall)
                    Text(
                        "Choose which Android apps mirror to Mac",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Icon(
                    Icons.Filled.ChevronRight,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 64.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .toggleable(
                        value = skipSilent,
                        role = Role.Switch,
                        onValueChange = onSkipSilentChange
                    )
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Skip silent notifications", style = MaterialTheme.typography.titleSmall)
                    Text(
                        "Don't mirror silent or background alerts",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Spacer(Modifier.size(12.dp))
                Switch(checked = skipSilent, onCheckedChange = null, colors = SwitchDefaults.colors())
            }
        }
    }
}

@Composable
private fun SettingsPermissionsCard(
    perms: PermissionSnapshot,
    onOpenNotificationAccess: () -> Unit,
    onOpenPostNotifications: () -> Unit,
    onOpenBatteryOptimization: () -> Unit,
    onOpenAllFilesAccess: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        )
    ) {
        Column(modifier = Modifier.fillMaxWidth().padding(4.dp)) {
            Text(
                "Permissions",
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(start = 16.dp, top = 14.dp, bottom = 4.dp)
            )
            PermissionSettingRow(
                icon = Icons.Filled.NotificationsActive,
                title = "Notification access",
                subtitle = if (perms.notificationAccess) {
                    "Granted — mirrors notifications to Mac"
                } else {
                    "Tap to grant — required for mirroring"
                },
                statusOk = perms.notificationAccess,
                onClick = onOpenNotificationAccess
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                PermissionSettingRow(
                    icon = Icons.Filled.Info,
                    title = "Own notifications",
                    subtitle = if (perms.postNotifications) {
                        "Granted — shows received files & test alerts"
                    } else {
                        "Needed for received files & Mac end-to-end tests"
                    },
                    statusOk = perms.postNotifications,
                    onClick = onOpenPostNotifications
                )
            }
            PermissionSettingRow(
                icon = Icons.Filled.BatteryChargingFull,
                title = "Background battery",
                subtitle = if (perms.batteryUnrestricted) {
                    "Unrestricted — stays connected in background"
                } else {
                    "Tap to allow unrestricted background use"
                },
                statusOk = perms.batteryUnrestricted,
                onClick = onOpenBatteryOptimization
            )
            PermissionSettingRow(
                icon = Icons.Filled.Folder,
                title = "All files access (Mac file browser)",
                subtitle = if (perms.allFiles) {
                    "Granted — Mac can browse files & photo thumbnails over Wi-Fi"
                } else {
                    "Optional — enables Wi-Fi browsing & thumbnails from Mac"
                },
                statusOk = perms.allFiles,
                optional = true,
                onClick = onOpenAllFilesAccess
            )
        }
    }
}

@Composable
private fun PermissionSettingRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    statusOk: Boolean,
    optional: Boolean = false,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically
    ) {
        val containerColor = when {
            statusOk -> MaterialTheme.colorScheme.secondaryContainer
            optional -> MaterialTheme.colorScheme.surfaceVariant
            else -> MaterialTheme.colorScheme.errorContainer
        }
        val iconTint = when {
            statusOk -> MaterialTheme.colorScheme.onSecondaryContainer
            optional -> MaterialTheme.colorScheme.onSurfaceVariant
            else -> MaterialTheme.colorScheme.onErrorContainer
        }
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(containerColor),
            contentAlignment = Alignment.Center
        ) {
            Icon(icon, contentDescription = null, tint = iconTint)
        }
        Spacer(Modifier.size(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = if (statusOk || optional) {
                    MaterialTheme.colorScheme.onSurfaceVariant
                } else {
                    MaterialTheme.colorScheme.error
                }
            )
        }
        Spacer(Modifier.size(8.dp))
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun ShortcutsInfoCard() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.55f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.Top
        ) {
            Icon(
                Icons.Filled.ContentPaste,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSecondaryContainer,
                modifier = Modifier.padding(top = 2.dp)
            )
            Spacer(Modifier.size(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Shortcuts & system handoff",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "Select text in any app and tap \"Send to Mac\", share files/photos to NotifMirror, " +
                        "or add the \"Send clipboard\" tile to Android Quick Settings.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer
                )
            }
        }
    }
}

@Composable
private fun ForgetPairingConfirmDialog(
    macName: String?,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Forget pairing?") },
        text = {
            val target = macName ?: "your Mac"
            Text(
                "This disconnects $target and deletes the saved pairing key. " +
                    "You will need to scan the QR code again to reconnect."
            )
        },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
            ) {
                Text("Forget")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    )
}
