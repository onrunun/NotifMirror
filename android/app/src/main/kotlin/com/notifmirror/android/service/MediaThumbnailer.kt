package com.notifmirror.android.service

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.os.Build
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Generates compact, EXIF-oriented JPEG thumbnails for image and video files
 * on device storage. Used by `FileBrowseBridge` to answer `fs_thumb` requests
 * without shipping multi-megabyte originals over LAN.
 */
internal object MediaThumbnailer {
    private const val MIN_DIM = 64
    private const val MAX_DIM = 480
    private const val IMAGE_JPEG_QUALITY = 72
    private const val VIDEO_JPEG_QUALITY = 70
    private const val FALLBACK_JPEG_QUALITY = 50
    private const val MAX_ENCODED_BYTES = 131_072
    private const val VIDEO_SAMPLE_US = 1_000_000L

    private val imageExts = setOf("jpg", "jpeg", "png", "webp", "heic", "heif", "gif", "bmp")
    private val videoExts = setOf("mp4", "mkv", "mov", "webm", "avi", "3gp", "m4v")
    private val exifExts = setOf("jpg", "jpeg", "heic", "heif", "webp")

    sealed class Outcome {
        data class Ok(val base64Jpeg: String) : Outcome()
        data class Err(val message: String) : Outcome()
    }

    fun generate(file: File, requestedMaxDim: Int): Outcome {
        if (!file.exists() || !file.isFile) return Outcome.Err("not found")
        val maxDim = requestedMaxDim.coerceIn(MIN_DIM, MAX_DIM)
        val ext = file.extension.lowercase(Locale.US)
        val raw = when {
            ext in imageExts -> decodeImage(file, maxDim)
            ext in videoExts -> decodeVideoFrame(file, maxDim)
            else -> return Outcome.Err("unsupported format")
        } ?: return Outcome.Err("decode failed")

        val quality = if (ext in videoExts) VIDEO_JPEG_QUALITY else IMAGE_JPEG_QUALITY
        val bytes = try {
            compressJpeg(raw, quality)
        } finally {
            if (!raw.isRecycled) raw.recycle()
        }
        return Outcome.Ok(Base64.encodeToString(bytes, Base64.NO_WRAP))
    }

    private fun decodeImage(file: File, maxDim: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val sample = computeSampleSize(bounds.outWidth, bounds.outHeight, maxDim)
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.RGB_565
        }
        val decoded = BitmapFactory.decodeFile(file.absolutePath, opts) ?: return null
        val oriented = applyExifRotation(decoded, file)
        return scaleToFit(oriented, maxDim)
    }

    private fun decodeVideoFrame(file: File, maxDim: Int): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            val frame = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                retriever.getScaledFrameAtTime(
                    VIDEO_SAMPLE_US,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    maxDim,
                    maxDim
                ) ?: retriever.getScaledFrameAtTime(
                    0L,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    maxDim,
                    maxDim
                )
            } else {
                retriever.getFrameAtTime(VIDEO_SAMPLE_US, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    ?: retriever.getFrameAtTime(0L)
            }
            frame?.let { scaleToFit(it, maxDim) }
        } catch (_: Throwable) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Throwable) {
                // MediaMetadataRetriever.release may throw on corrupt files.
            }
        }
    }

    private fun computeSampleSize(width: Int, height: Int, maxDim: Int): Int {
        var sample = 1
        val longest = max(width, height)
        while (longest / (sample * 2) >= maxDim) {
            sample *= 2
        }
        return sample
    }

    private fun applyExifRotation(bitmap: Bitmap, file: File): Bitmap {
        if (file.extension.lowercase(Locale.US) !in exifExts) return bitmap
        val degrees = try {
            when (ExifInterface(file.absolutePath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (_: Throwable) {
            0f
        }
        if (degrees == 0f) return bitmap
        val matrix = Matrix().apply { postRotate(degrees) }
        val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        if (rotated !== bitmap) bitmap.recycle()
        return rotated
    }

    private fun scaleToFit(bitmap: Bitmap, maxDim: Int): Bitmap {
        val longest = max(bitmap.width, bitmap.height)
        if (longest <= maxDim) return bitmap
        val ratio = maxDim.toFloat() / longest.toFloat()
        val targetW = max(1, (bitmap.width * ratio).roundToInt())
        val targetH = max(1, (bitmap.height * ratio).roundToInt())
        val scaled = Bitmap.createScaledBitmap(bitmap, targetW, targetH, true)
        if (scaled !== bitmap) bitmap.recycle()
        return scaled
    }

    private fun compressJpeg(bitmap: Bitmap, quality: Int): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
        val first = out.toByteArray()
        if (first.size <= MAX_ENCODED_BYTES) return first
        out.reset()
        bitmap.compress(Bitmap.CompressFormat.JPEG, FALLBACK_JPEG_QUALITY, out)
        return out.toByteArray()
    }
}
