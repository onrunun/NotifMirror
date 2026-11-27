package com.notifmirror.android.ui

import android.Manifest
import android.annotation.SuppressLint
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import android.util.Log
import android.view.ViewGroup
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.notifmirror.android.data.PairingPayload
import com.notifmirror.android.data.PairingStore
import com.notifmirror.android.service.MirrorCore
import java.util.concurrent.Executors
import kotlinx.coroutines.launch

private const val INVALID_QR_COOLDOWN_MS = 2000L

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairingScreen(onDone: () -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    var hasCamera by remember { mutableStateOf(hasCameraPermission(context)) }
    var permissionRequested by remember { mutableStateOf(false) }
    var showManualDialog by remember { mutableStateOf(false) }
    var lastInvalidAt by remember { mutableLongStateOf(0L) }

    val launcher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasCamera = granted
        permissionRequested = true
    }

    LaunchedEffect(Unit) {
        if (!hasCamera) {
            permissionRequested = true
            launcher.launch(Manifest.permission.CAMERA)
        }
    }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                hasCamera = hasCameraPermission(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val permanentlyDenied = !hasCamera && permissionRequested &&
        !shouldShowRationale(context, Manifest.permission.CAMERA)

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Pair with Mac", fontWeight = FontWeight.SemiBold) },
                navigationIcon = {
                    IconButton(onClick = onCancel) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(
                    containerColor = Color.Transparent
                )
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
        bottomBar = {
            PairingBottomBar(
                onPasteJson = { showManualDialog = true },
                onCancel = onCancel
            )
        },
        containerColor = MaterialTheme.colorScheme.background
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(
                "Scan the QR code",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onBackground
            )
            Text(
                "Open NotifMirror on your Mac and point your camera at the pairing QR.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )

            PairingScannerBody(
                hasCamera = hasCamera,
                permanentlyDenied = permanentlyDenied,
                onRequestCamera = {
                    if (permanentlyDenied) {
                        openAppDetailsSettings(context)
                    } else {
                        launcher.launch(Manifest.permission.CAMERA)
                    }
                },
                onPayload = { payload ->
                    handleScannedPayload(
                        context = context,
                        payload = payload,
                        lastInvalidAt = lastInvalidAt,
                        onUpdateInvalidAt = { lastInvalidAt = it },
                        onInvalidNotice = {
                            scope.launch {
                                snackbarHostState.showSnackbar(
                                    "Not a NotifMirror QR code. Scan the code on your Mac."
                                )
                            }
                        },
                        onPaired = onDone
                    )
                }
            )

            HintRow()
            Spacer(Modifier.height(4.dp))
        }
    }

    if (showManualDialog) {
        PastePairingDialog(
            onDismiss = { showManualDialog = false },
            onPaired = { parsed ->
                showManualDialog = false
                PairingStore(context).save(parsed)
                MirrorCore.notifyPairingChanged()
                onDone()
            }
        )
    }
}

private fun handleScannedPayload(
    context: Context,
    payload: String,
    lastInvalidAt: Long,
    onUpdateInvalidAt: (Long) -> Unit,
    onInvalidNotice: () -> Unit,
    onPaired: () -> Unit
): Boolean {
    val parsed = PairingPayload.fromJson(payload)
    if (parsed != null) {
        PairingStore(context).save(parsed)
        MirrorCore.notifyPairingChanged()
        onPaired()
        return true
    }
    Log.w("PairingScreen", "non-pairing QR scanned")
    val now = SystemClock.elapsedRealtime()
    if (now - lastInvalidAt >= INVALID_QR_COOLDOWN_MS) {
        onUpdateInvalidAt(now)
        onInvalidNotice()
    }
    return false
}

@Composable
private fun PairingScannerBody(
    hasCamera: Boolean,
    permanentlyDenied: Boolean,
    onRequestCamera: () -> Unit,
    onPayload: (String) -> Boolean
) {
    val context = LocalContext.current
    if (hasCamera) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 340.dp)
                .aspectRatio(1f)
                .clip(RoundedCornerShape(28.dp))
                .background(Color.Black)
        ) {
            CameraScannerView(onPayload = onPayload)
            ViewfinderOverlay(
                animate = remember(context) { areAnimationsEnabled(context) },
                modifier = Modifier.fillMaxSize()
            )
        }
    } else {
        CameraPermissionPrompt(
            permanentlyDenied = permanentlyDenied,
            onRequest = onRequestCamera
        )
    }
}

private fun hasCameraPermission(context: Context): Boolean =
    ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
        PackageManager.PERMISSION_GRANTED

@Composable
private fun PairingBottomBar(onPasteJson: () -> Unit, onCancel: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        OutlinedButton(
            onClick = onPasteJson,
            modifier = Modifier.fillMaxWidth()
        ) {
            Icon(Icons.Filled.ContentPaste, contentDescription = null)
            Spacer(Modifier.size(8.dp))
            Text("Paste pairing JSON")
        }
        FilledTonalButton(
            onClick = onCancel,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Cancel")
        }
    }
}

@Composable
private fun PastePairingDialog(
    onDismiss: () -> Unit,
    onPaired: (PairingPayload) -> Unit
) {
    val context = LocalContext.current
    var rawJson by remember { mutableStateOf("") }
    var errorText by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Paste pairing JSON") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "Use \"Copy JSON\" on your Mac if the camera is unavailable.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                OutlinedTextField(
                    value = rawJson,
                    onValueChange = {
                        rawJson = it
                        errorText = null
                    },
                    placeholder = { Text("{\"host\":..., \"port\":..., \"secret\":...}") },
                    isError = errorText != null,
                    supportingText = errorText?.let { msg -> { Text(msg) } },
                    maxLines = 4,
                    modifier = Modifier.fillMaxWidth()
                )
                TextButton(
                    onClick = {
                        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                        val clip = cm?.primaryClip
                        val pasted = if (clip != null && clip.itemCount > 0) {
                            clip.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
                        } else {
                            ""
                        }
                        if (pasted.isNotEmpty()) {
                            rawJson = pasted
                            errorText = null
                        } else {
                            errorText = "Clipboard is empty."
                        }
                    }
                ) {
                    Icon(Icons.Filled.ContentPaste, contentDescription = null)
                    Spacer(Modifier.size(6.dp))
                    Text("Paste from clipboard")
                }
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    val parsed = PairingPayload.fromJson(rawJson.trim())
                    if (parsed != null) {
                        onPaired(parsed)
                    } else {
                        errorText = "Invalid pairing JSON. Copy the full payload from your Mac."
                    }
                },
                enabled = rawJson.isNotBlank()
            ) {
                Text("Pair")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    )
}

@Composable
private fun ViewfinderOverlay(animate: Boolean, modifier: Modifier = Modifier) {
    val sweep = if (animate) {
        val transition = rememberInfiniteTransition(label = "scan-line")
        val animated by transition.animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1800),
                repeatMode = RepeatMode.Restart
            ),
            label = "sweep"
        )
        animated
    } else {
        0.5f
    }

    val cornerColor = MaterialTheme.colorScheme.primary
    val scanLine = MaterialTheme.colorScheme.primary.copy(alpha = 0.7f)

    Canvas(modifier = modifier) {
        val frameSize = size.minDimension * 0.7f
        val left = (size.width - frameSize) / 2f
        val top = (size.height - frameSize) / 2f
        val corner = frameSize * 0.14f
        val stroke = 4.dp.toPx()

        val corners = listOf(
            Offset(left, top + corner) to Offset(left, top),
            Offset(left, top) to Offset(left + corner, top),
            Offset(left + frameSize - corner, top) to Offset(left + frameSize, top),
            Offset(left + frameSize, top) to Offset(left + frameSize, top + corner),
            Offset(left, top + frameSize - corner) to Offset(left, top + frameSize),
            Offset(left, top + frameSize) to Offset(left + corner, top + frameSize),
            Offset(left + frameSize - corner, top + frameSize) to Offset(left + frameSize, top + frameSize),
            Offset(left + frameSize, top + frameSize - corner) to Offset(left + frameSize, top + frameSize)
        )
        corners.forEach { (start, end) ->
            drawLine(cornerColor, start = start, end = end, strokeWidth = stroke, cap = StrokeCap.Round)
        }

        if (animate) {
            val y = top + frameSize * sweep
            drawLine(
                scanLine,
                start = Offset(left + corner, y),
                end = Offset(left + frameSize - corner, y),
                strokeWidth = 2.dp.toPx(),
                cap = StrokeCap.Round
            )
        }
    }
}

@Composable
private fun CameraPermissionPrompt(permanentlyDenied: Boolean, onRequest: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 320.dp)
            .aspectRatio(1f)
            .clip(RoundedCornerShape(28.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
            .padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .size(64.dp)
                .clip(RoundedCornerShape(20.dp))
                .background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Filled.CameraAlt,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.size(30.dp)
            )
        }
        Spacer(Modifier.height(14.dp))
        Text(
            "Camera access needed",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(Modifier.height(6.dp))
        Text(
            if (permanentlyDenied) {
                "Camera permission is turned off in system settings. Enable it there, or paste pairing JSON below."
            } else {
                "We use the camera only to scan your pairing QR."
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center
        )
        Spacer(Modifier.height(14.dp))
        FilledTonalButton(onClick = onRequest) {
            Text(if (permanentlyDenied) "Open app settings" else "Allow camera")
        }
    }
}

@Composable
private fun HintRow() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f))
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            Icons.Filled.QrCodeScanner,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary
        )
        Spacer(Modifier.size(12.dp))
        Text(
            "Both devices must be on the same Wi-Fi network.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}

@Composable
@OptIn(ExperimentalGetImage::class)
@SuppressLint("UnsafeOptInUsageError")
private fun CameraScannerView(onPayload: (String) -> Boolean) {
    val lifecycleOwner = LocalLifecycleOwner.current
    val executor = remember { Executors.newSingleThreadExecutor() }
    val scanner = remember { BarcodeScanning.getClient() }
    var consumed by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        onDispose {
            runCatching { scanner.close() }
            runCatching { executor.shutdown() }
        }
    }

    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { ctx ->
            val previewView = PreviewView(ctx).apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
                scaleType = PreviewView.ScaleType.FILL_CENTER
            }
            val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
            cameraProviderFuture.addListener({
                val cameraProvider = cameraProviderFuture.get()
                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }
                val analyzer = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analyzer.setAnalyzer(executor) { proxy: ImageProxy ->
                    if (consumed) {
                        proxy.close()
                        return@setAnalyzer
                    }
                    val mediaImage = proxy.image
                    if (mediaImage == null) {
                        proxy.close()
                        return@setAnalyzer
                    }
                    val image = InputImage.fromMediaImage(
                        mediaImage,
                        proxy.imageInfo.rotationDegrees
                    )
                    scanner.process(image)
                        .addOnSuccessListener { codes ->
                            val payload = codes
                                .firstOrNull { it.format == Barcode.FORMAT_QR_CODE }
                                ?.rawValue
                            if (payload != null && !consumed && onPayload(payload)) {
                                consumed = true
                            }
                        }
                        .addOnCompleteListener { proxy.close() }
                }
                val selector = CameraSelector.DEFAULT_BACK_CAMERA
                runCatching {
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(lifecycleOwner, selector, preview, analyzer)
                }.onFailure { Log.w("CameraScanner", "bind failed", it) }
            }, ContextCompat.getMainExecutor(ctx))
            previewView
        }
    )
}
