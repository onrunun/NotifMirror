package com.notifmirror.android.ui

import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.notifmirror.android.protocol.WireMessage
import com.notifmirror.android.service.FileBridge
import com.notifmirror.android.service.MediaBridge
import com.notifmirror.android.service.MirrorCore
import com.notifmirror.android.service.TransferEntry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val DEFAULT_TRANSFER_LIMIT = 5

// ---------- Now playing ----------

@Composable
fun NowPlayingCard(media: WireMessage.MediaState?) {
    val hasSession = media?.let {
        it.pkg != null || it.title != null || it.artist != null
    } ?: false
    if (!hasSession) return

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Artwork(media?.artwork)
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    media?.title ?: media?.app ?: "Now playing",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                if (!media?.artist.isNullOrEmpty()) {
                    Text(
                        media?.artist.orEmpty(),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
            Spacer(Modifier.width(8.dp))
            TransportButtons(media)
        }
    }
}

@Composable
private fun Artwork(artworkBase64: String?) {
    var artwork by remember(artworkBase64) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(artworkBase64) {
        artwork = if (artworkBase64.isNullOrEmpty()) {
            null
        } else {
            withContext(Dispatchers.Default) { decodeArtwork(artworkBase64) }
        }
    }
    val bitmap = artwork
    if (bitmap != null) {
        Image(
            bitmap = bitmap,
            contentDescription = null,
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(10.dp))
        )
    } else {
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Filled.MusicNote,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

private fun decodeArtwork(b64: String): ImageBitmap? = try {
    val bytes = Base64.decode(b64, Base64.NO_WRAP)
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
} catch (_: Throwable) {
    null
}

@Composable
private fun TransportButtons(media: WireMessage.MediaState?) {
    val bridge = MediaBridge.current()
    IconButton(
        onClick = { bridge?.handleCommand("prev") },
        enabled = media?.canSkipPrev == true && bridge != null
    ) {
        Icon(
            Icons.Filled.SkipPrevious,
            contentDescription = "Previous track",
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
    IconButton(
        onClick = { bridge?.handleCommand("toggle") },
        enabled = bridge != null
    ) {
        Icon(
            if (media?.playing == true) Icons.Filled.Pause else Icons.Filled.PlayArrow,
            contentDescription = if (media?.playing == true) "Pause" else "Play",
            tint = MaterialTheme.colorScheme.primary
        )
    }
    IconButton(
        onClick = { bridge?.handleCommand("next") },
        enabled = media?.canSkipNext == true && bridge != null
    ) {
        Icon(
            Icons.Filled.SkipNext,
            contentDescription = "Next track",
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

// ---------- Transfers ----------

@Composable
fun TransferCard(transfers: List<TransferEntry>, canRetry: Boolean = true) {
    if (transfers.isEmpty()) return
    var showAll by remember { mutableStateOf(false) }
    val visible = if (showAll) transfers else transfers.take(DEFAULT_TRANSFER_LIMIT)
    val hasFinished = transfers.any {
        it.status != TransferEntry.Status.Active && it.status != TransferEntry.Status.Pending
    }

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
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    "Transfers",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f)
                )
                if (hasFinished) {
                    TextButton(onClick = { FileBridge.clearFinished() }) {
                        Text("Clear")
                    }
                }
                if (transfers.size > DEFAULT_TRANSFER_LIMIT) {
                    TextButton(onClick = { showAll = !showAll }) {
                        Text(if (showAll) "Less" else "All (${transfers.size})")
                    }
                }
            }
            visible.forEach { t ->
                TransferRow(t, canRetry = canRetry)
            }
        }
    }
}

@Composable
private fun TransferRow(t: TransferEntry, canRetry: Boolean) {
    val context = LocalContext.current
    val isActive = t.status == TransferEntry.Status.Active || t.status == TransferEntry.Status.Pending
    val canOpen = t.direction == TransferEntry.Direction.Incoming &&
        t.status == TransferEntry.Status.Done &&
        t.openUri != null
    val showRetry = canRetry &&
        t.direction == TransferEntry.Direction.Outgoing &&
        t.status == TransferEntry.Status.Failed &&
        t.sourceUri != null

    val rowModifier = if (canOpen) {
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable {
                val intent = MirrorCore.fileBridge()?.buildOpenIntent(t)
                if (intent != null) runCatching { context.startActivity(intent) }
            }
            .padding(vertical = 4.dp)
    } else {
        Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp)
    }

    Row(
        modifier = rowModifier,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            if (t.direction == TransferEntry.Direction.Incoming) Icons.Filled.Download
            else Icons.Filled.Upload,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                t.name,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (isActive) {
                val progress = if (t.size > 0) t.bytesTransferred.toFloat() / t.size else 0f
                LinearProgressIndicator(
                    progress = { progress.coerceIn(0f, 1f) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(4.dp)
                )
            }
            Spacer(Modifier.height(2.dp))
            Text(
                formatTransferStatus(t),
                style = MaterialTheme.typography.labelSmall.copy(fontFeatureSettings = "tnum"),
                color = if (t.status == TransferEntry.Status.Failed) {
                    MaterialTheme.colorScheme.error
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                }
            )
        }
        TransferTrailingAction(
            entry = t,
            isActive = isActive,
            showRetry = showRetry,
            canOpen = canOpen
        )
    }
}

@Composable
private fun TransferTrailingAction(
    entry: TransferEntry,
    isActive: Boolean,
    showRetry: Boolean,
    canOpen: Boolean
) {
    when {
        isActive -> IconButton(onClick = { MirrorCore.fileBridge()?.cancel(entry.id) }) {
            Icon(
                Icons.Filled.Close,
                contentDescription = "Cancel transfer ${entry.name}",
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        showRetry -> IconButton(onClick = { MirrorCore.fileBridge()?.retry(entry.id) }) {
            Icon(
                Icons.Filled.Refresh,
                contentDescription = "Retry sending ${entry.name}",
                tint = MaterialTheme.colorScheme.primary
            )
        }
        canOpen -> Icon(
            Icons.AutoMirrored.Filled.OpenInNew,
            contentDescription = "Open ${entry.name}",
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier
                .padding(horizontal = 8.dp)
                .size(18.dp)
        )
    }
}

private fun formatTransferStatus(t: TransferEntry): String {
    val sizeText = if (t.size > 0) " / ${formatBytes(t.size)}" else ""
    val errText = t.errorMessage?.let { humanTransferError(it) }
    val status = if (t.status == TransferEntry.Status.Failed && errText != null) {
        "Failed ($errText)"
    } else {
        t.status.label
    }
    return "$status • ${formatBytes(t.bytesTransferred)}$sizeText"
}

private fun humanTransferError(code: String): String = when (code) {
    "size_mismatch" -> "incomplete file"
    "io_error" -> "storage error"
    else -> code.replace('_', ' ')
}

private val TransferEntry.Status.label: String
    get() = when (this) {
        TransferEntry.Status.Pending -> "Waiting"
        TransferEntry.Status.Active -> "Transferring"
        TransferEntry.Status.Done -> "Done"
        TransferEntry.Status.Failed -> "Failed"
        TransferEntry.Status.Cancelled -> "Cancelled"
    }

private fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val kb = bytes / 1024.0
    if (kb < 1024) return "%.0f KB".format(kb)
    val mb = kb / 1024.0
    if (mb < 1024) return "%.1f MB".format(mb)
    return "%.2f GB".format(mb / 1024.0)
}
