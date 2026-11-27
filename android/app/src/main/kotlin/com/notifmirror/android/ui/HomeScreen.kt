package com.notifmirror.android.ui

import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
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
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.notifmirror.android.data.PairingStore
import com.notifmirror.android.protocol.WireMessage
import com.notifmirror.android.service.FileBridge
import com.notifmirror.android.service.MediaBridge
import com.notifmirror.android.service.MirrorCore
import com.notifmirror.android.ui.theme.StatusConnected
import com.notifmirror.android.ui.theme.StatusStopped
import com.notifmirror.android.ui.theme.StatusWaiting
import kotlinx.coroutines.launch

private const val CLIP_PREVIEW_LIMIT = 72

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    onPair: () -> Unit,
    onOpenFilter: () -> Unit,
    onOpenSettings: () -> Unit
) {
    val context = LocalContext.current
    val store = remember { PairingStore(context) }
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    var paired by remember { mutableStateOf(store.isPaired) }
    val pairing = remember(paired) { store.load() }
    var perms by remember { mutableStateOf(readPermissionSnapshot(context)) }
    var clipPreview by remember { mutableStateOf(readClipboardPreview(context)) }

    val sendPicked: (List<Uri>) -> Unit = { uris ->
        if (uris.isNotEmpty()) {
            val sent = dispatchPickedFiles(context, uris)
            scope.launch {
                val msg = when {
                    sent > 1 -> "Sending $sent items to Mac"
                    sent == 1 -> "Sending item to Mac"
                    else -> "Service not connected — not sent"
                }
                snackbarHostState.showSnackbar(msg)
            }
        }
    }

    val photoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(),
        onResult = sendPicked
    )
    val filePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments(),
        onResult = sendPicked
    )

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                paired = store.isPaired
                perms = readPermissionSnapshot(context)
                clipPreview = readClipboardPreview(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val serviceRunning by MirrorCore.runningFlow.collectAsState()
    val serviceConnected by MirrorCore.connectedFlow.collectAsState()

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("NotifMirror", fontWeight = FontWeight.SemiBold) },
                actions = {
                    IconButton(onClick = onOpenSettings) {
                        Icon(
                            Icons.Filled.Settings,
                            contentDescription = "Settings",
                            tint = if (!perms.allCoreReady) {
                                MaterialTheme.colorScheme.error
                            } else {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            }
                        )
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = Color.Transparent
                )
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
        containerColor = MaterialTheme.colorScheme.background
    ) { padding ->
        HomeBody(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            state = HomeUiState(
                paired = paired,
                pairedName = pairing?.name,
                pairedHost = pairing?.let { "${it.host}:${it.port}" },
                serviceRunning = serviceRunning,
                serviceConnected = serviceConnected,
                perms = perms,
                clipPreview = clipPreview
            ),
            actions = HomeActions(
                onPair = onPair,
                onSendClipboard = {
                    clipPreview = readClipboardPreview(context)
                    val msg = sendForegroundClipboard(context)
                    scope.launch { snackbarHostState.showSnackbar(msg) }
                },
                onSendText = { text ->
                    MirrorCore.dispatch(WireMessage.Clip(text = text, origin = "android", seq = 0))
                    scope.launch { snackbarHostState.showSnackbar("Sent text to Mac") }
                },
                onSendPhotos = {
                    photoPickerLauncher.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
                    )
                },
                onSendFiles = { filePickerLauncher.launch(arrayOf("*/*")) },
                onOpenFilter = onOpenFilter,
                onOpenSettings = onOpenSettings
            )
        )
    }
}

private data class HomeUiState(
    val paired: Boolean,
    val pairedName: String?,
    val pairedHost: String?,
    val serviceRunning: Boolean,
    val serviceConnected: Boolean,
    val perms: PermissionSnapshot,
    val clipPreview: String?
)

private data class HomeActions(
    val onPair: () -> Unit,
    val onSendClipboard: () -> Unit,
    val onSendText: (String) -> Unit,
    val onSendPhotos: () -> Unit,
    val onSendFiles: () -> Unit,
    val onOpenFilter: () -> Unit,
    val onOpenSettings: () -> Unit
)

@Composable
private fun HomeBody(
    modifier: Modifier,
    state: HomeUiState,
    actions: HomeActions
) {
    val context = LocalContext.current
    val media by MediaBridge.state.collectAsState()
    val transfers by FileBridge.transfers.collectAsState()

    Column(
        modifier = modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        ConnectionHero(
            paired = state.paired,
            pairedName = state.pairedName,
            pairedHost = state.pairedHost,
            serviceRunning = state.serviceRunning,
            serviceConnected = state.serviceConnected,
            onPair = actions.onPair,
            onOpenSettings = actions.onOpenSettings
        )

        if (state.paired && !state.perms.allCoreReady) {
            HealthAlertBanner(
                perms = state.perms,
                onFix = {
                    when {
                        !state.perms.notificationAccess -> openNotificationAccessSettings(context)
                        !state.perms.batteryUnrestricted -> openBatteryOptimizationSettings(context)
                        else -> actions.onOpenSettings()
                    }
                }
            )
        }

        if (state.serviceConnected) {
            ClipboardHandoffCard(
                preview = state.clipPreview,
                onSendClipboard = actions.onSendClipboard,
                onSendText = actions.onSendText
            )
            MediaAndFileRow(
                onSendPhotos = actions.onSendPhotos,
                onSendFiles = actions.onSendFiles
            )
        }

        NowPlayingCard(media)
        TransferCard(transfers, canRetry = state.serviceConnected)

        if (state.paired) {
            MirroredAppsLinkRow(onClick = actions.onOpenFilter)
        }

        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun ConnectionHero(
    paired: Boolean,
    pairedName: String?,
    pairedHost: String?,
    serviceRunning: Boolean,
    serviceConnected: Boolean,
    onPair: () -> Unit,
    onOpenSettings: () -> Unit
) {
    val (statusColor, statusLabel, statusDetail) = when {
        !paired -> Triple(StatusStopped, "Not paired", "Scan the QR code on your Mac to connect")
        !serviceRunning -> Triple(StatusStopped, "Notification access needed", "Enable access to start mirroring")
        serviceConnected -> Triple(
            StatusConnected,
            pairedName ?: "Connected to Mac",
            pairedHost?.let { "LAN TLS • $it" } ?: "LAN TLS active"
        )
        else -> Triple(
            StatusWaiting,
            "Looking for ${pairedName ?: "your Mac"}",
            "Scanning local network…"
        )
    }

    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (paired) Modifier.clickable(onClick = onOpenSettings) else Modifier),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
        ),
        elevation = CardDefaults.elevatedCardElevation(defaultElevation = 0.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(color = statusColor, pulse = serviceRunning && !serviceConnected)
                Spacer(Modifier.size(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        statusLabel,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        statusDetail,
                        style = MaterialTheme.typography.bodySmall.copy(fontFeatureSettings = "tnum"),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                if (paired) {
                    Icon(
                        Icons.Filled.ChevronRight,
                        contentDescription = "Open settings",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            if (!paired) {
                FilledTonalButton(
                    onClick = onPair,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Icon(Icons.Filled.QrCodeScanner, contentDescription = null)
                    Spacer(Modifier.size(8.dp))
                    Text("Pair with Mac")
                }
            }
        }
    }
}

@Composable
private fun HealthAlertBanner(perms: PermissionSnapshot, onFix: () -> Unit) {
    val reason = when {
        !perms.notificationAccess -> "Grant notification access so alerts mirror to your Mac."
        !perms.postNotifications -> "Allow NotifMirror notifications for received files and tests."
        else -> "Allow unrestricted background battery so the link stays alive."
    }
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.75f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, top = 12.dp, end = 8.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Filled.Warning,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onErrorContainer
            )
            Spacer(Modifier.size(12.dp))
            Text(
                reason,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onErrorContainer,
                modifier = Modifier.weight(1f)
            )
            TextButton(onClick = onFix) {
                Text("Fix", color = MaterialTheme.colorScheme.onErrorContainer)
            }
        }
    }
}

@Composable
private fun ClipboardHandoffCard(
    preview: String?,
    onSendClipboard: () -> Unit,
    onSendText: (String) -> Unit
) {
    var draft by remember { mutableStateOf("") }
    var showComposer by remember { mutableStateOf(false) }

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
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.primaryContainer),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        Icons.Filled.ContentPaste,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimaryContainer
                    )
                }
                Spacer(Modifier.size(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        "Clipboard handoff",
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        preview ?: "Tap Send to push copied text to Mac",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                TextButton(onClick = { showComposer = !showComposer }) {
                    Text(if (showComposer) "Hide" else "Type")
                }
            }

            if (showComposer) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        placeholder = { Text("Type text or link…") },
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                    IconButton(
                        onClick = {
                            val trimmed = draft.trim()
                            if (trimmed.isNotEmpty()) {
                                onSendText(trimmed)
                                draft = ""
                                showComposer = false
                            }
                        },
                        enabled = draft.isNotBlank()
                    ) {
                        Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send text to Mac")
                    }
                }
            }

            FilledTonalButton(
                onClick = onSendClipboard,
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Filled.ContentPaste, contentDescription = null)
                Spacer(Modifier.size(8.dp))
                Text("Send clipboard to Mac")
            }
        }
    }
}

@Composable
private fun MediaAndFileRow(
    onSendPhotos: () -> Unit,
    onSendFiles: () -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        HandoffTile(
            icon = Icons.Filled.PhotoLibrary,
            label = "Send photos",
            description = "Pick from gallery",
            onClick = onSendPhotos,
            modifier = Modifier.weight(1f)
        )
        HandoffTile(
            icon = Icons.Filled.UploadFile,
            label = "Send files",
            description = "Docs & folders",
            onClick = onSendFiles,
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
private fun HandoffTile(
    icon: ImageVector,
    label: String,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        onClick = onClick,
        modifier = modifier.semantics(mergeDescendants = true) {},
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        )
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.primaryContainer),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimaryContainer
                )
            }
            Text(label, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurface)
            Text(
                description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun MirroredAppsLinkRow(onClick: () -> Unit) {
    Card(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {},
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 60.dp)
                .padding(horizontal = 16.dp, vertical = 14.dp),
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
                Text(
                    "Mirrored apps",
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    "Mute noisy apps or pick what mirrors to Mac",
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
    }
}

@Composable
private fun StatusDot(color: Color, pulse: Boolean) {
    val context = LocalContext.current
    val shouldPulse = pulse && remember(context) { areAnimationsEnabled(context) }

    val scale: Float
    val haloAlpha: Float
    if (shouldPulse) {
        val transition = rememberInfiniteTransition(label = "status-pulse")
        val animatedScale by transition.animateFloat(
            initialValue = 1f,
            targetValue = 1.6f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1100),
                repeatMode = RepeatMode.Reverse
            ),
            label = "scale"
        )
        val animatedAlpha by transition.animateFloat(
            initialValue = 0.45f,
            targetValue = 0f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1100),
                repeatMode = RepeatMode.Reverse
            ),
            label = "alpha"
        )
        scale = animatedScale
        haloAlpha = animatedAlpha
    } else {
        scale = 1f
        haloAlpha = 0.25f
    }

    Box(modifier = Modifier.size(28.dp), contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .size((16 * scale).dp)
                .clip(CircleShape)
                .background(color.copy(alpha = haloAlpha))
        )
        Box(
            modifier = Modifier
                .size(12.dp)
                .clip(CircleShape)
                .background(color)
        )
    }
}

private fun readClipboardPreview(context: Context): String? {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return null
    val clip = cm.primaryClip ?: return null
    if (clip.itemCount == 0) return null
    val raw = runCatching { clip.getItemAt(0)?.coerceToText(context)?.toString() }.getOrNull()
        ?.replace('\n', ' ')
        ?.trim()
    if (raw.isNullOrEmpty()) return null
    return if (raw.length > CLIP_PREVIEW_LIMIT) raw.take(CLIP_PREVIEW_LIMIT) + "…" else raw
}

private fun sendForegroundClipboard(context: Context): String {
    if (!MirrorCore.connectedFlow.value) return "Not connected to Mac"
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
    val clip = cm?.primaryClip
    val text = if (clip != null && clip.itemCount > 0) {
        clip.getItemAt(0)?.coerceToText(context)?.toString()
    } else {
        null
    }
    if (text.isNullOrEmpty()) return "Clipboard is empty"
    MirrorCore.dispatch(WireMessage.Clip(text = text, origin = "android", seq = 0))
    return "Clipboard sent to Mac"
}

private fun dispatchPickedFiles(context: Context, uris: List<Uri>): Int {
    val bridge = MirrorCore.fileBridge() ?: return 0
    var sent = 0
    for (uri in uris) {
        val (name, size) = queryFileMeta(context, uri)
        runCatching {
            bridge.sendFile(uri, name, size)
            sent++
        }
    }
    return sent
}

private fun queryFileMeta(context: Context, uri: Uri): Pair<String, Long> {
    var name = uri.lastPathSegment ?: "file"
    var size = 0L
    runCatching {
        context.contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val si = c.getColumnIndex(OpenableColumns.SIZE)
                if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
            }
        }
    }
    return name to size
}
