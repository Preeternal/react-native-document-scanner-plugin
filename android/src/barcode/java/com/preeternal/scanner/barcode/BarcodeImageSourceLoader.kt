package com.preeternal.scanner.barcode

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.util.Base64
import androidx.exifinterface.media.ExifInterface
import com.preeternal.scanner.DocScannerDebugLog
import java.io.File
import java.io.FileInputStream
import java.io.InputStream

internal object BarcodeImageSourceLoader {
  private const val TAG = "DocumentScannerBarcode"
  private const val MAX_DECODE_DIMENSION = 2048
  private val base64Regex = Regex("^[A-Za-z0-9+/=\\s]+$")

  private fun logDebug(message: String) {
    DocScannerDebugLog.debug(TAG, message)
  }

  private fun logWarn(message: String) {
    DocScannerDebugLog.warn(TAG, message)
  }

  fun loadBitmap(context: Context, imageSource: String): Bitmap? {
    val normalized = imageSource.trim()
    if (normalized.isEmpty()) {
      logDebug("loadBitmap empty source")
      return null
    }
    logDebug(
      "loadBitmap start length=${normalized.length} scheme=${Uri.parse(normalized).scheme ?: "path-or-base64"}"
    )

    if (normalized.startsWith("data:", ignoreCase = true) && normalized.contains("base64,")) {
      val payload = normalized.substringAfter("base64,", "")
      return decodeFromBase64(payload)?.also {
        logDebug("loadBitmap decoded data: base64 size=${it.width}x${it.height}")
      }
    }

    if (normalized.startsWith("content://", ignoreCase = true)) {
      return loadFromUri(context, Uri.parse(normalized))?.also {
        logDebug("loadBitmap decoded content:// size=${it.width}x${it.height}")
      }
    }

    if (normalized.startsWith("file://", ignoreCase = true)) {
      return loadFromFilePath(resolveFilePathFromUri(Uri.parse(normalized)))?.also {
        logDebug("loadBitmap decoded file:// size=${it.width}x${it.height}")
      }
    }

    if (File(normalized).exists()) {
      return loadFromFilePath(normalized)?.also {
        logDebug("loadBitmap decoded path size=${it.width}x${it.height}")
      }
    }

    if (looksLikeBase64(normalized)) {
      return decodeFromBase64(normalized)?.also {
        logDebug("loadBitmap decoded plain-base64 size=${it.width}x${it.height}")
      }
    }

    val parsed = Uri.parse(normalized)
    return when (parsed.scheme?.lowercase()) {
      "content" -> loadFromUri(context, parsed)
      "file" -> loadFromFilePath(resolveFilePathFromUri(parsed))
      null, "" -> loadFromFilePath(normalized)
      else -> loadFromUri(context, parsed)
    }?.also {
      logDebug("loadBitmap decoded fallback size=${it.width}x${it.height}")
    }
  }

  private fun decodeFromBase64(payload: String): Bitmap? {
    return try {
      val decoded = Base64.decode(payload, Base64.DEFAULT)
      decodeSampledBitmap(decoded)
    } catch (_: IllegalArgumentException) {
      logWarn("decodeFromBase64 failed")
      null
    }
  }

  private fun loadFromUri(context: Context, uri: Uri): Bitmap? {
    return try {
      val bitmap = context.contentResolver.openInputStream(uri)?.use { decodeSampledBitmap(it) }
        ?: return null
      val orientation = context.contentResolver.openInputStream(uri)?.use {
        readOrientation(it)
      } ?: ExifInterface.ORIENTATION_NORMAL

      rotateBitmapIfRequired(bitmap, orientation)
    } catch (_: Exception) {
      logWarn("loadFromUri failed uri=$uri")
      null
    }
  }

  private fun loadFromFilePath(path: String?): Bitmap? {
    val normalized = path?.trim()
    if (normalized.isNullOrBlank()) {
      return null
    }

    val decoded = Uri.decode(normalized)
    val candidatePath = when {
      File(normalized).exists() -> normalized
      decoded != normalized && File(decoded).exists() -> decoded
      else -> normalized
    }

    val file = File(candidatePath)
    if (!file.exists() || !file.isFile) {
      logDebug("loadFromFilePath missing file path=$candidatePath")
      return null
    }

    return try {
      val bitmap = FileInputStream(file).use { decodeSampledBitmap(it) } ?: return null
      val orientation = FileInputStream(file).use {
        readOrientation(it)
      }

      rotateBitmapIfRequired(bitmap, orientation)
    } catch (_: Exception) {
      logWarn("loadFromFilePath failed path=$candidatePath")
      null
    }
  }

  private fun decodeSampledBitmap(stream: InputStream): Bitmap? {
    val bytes = stream.readBytes()
    return decodeSampledBitmap(bytes)
  }

  private fun decodeSampledBitmap(bytes: ByteArray): Bitmap? {
    if (bytes.isEmpty()) {
      return null
    }

    val bounds = BitmapFactory.Options().apply {
      inJustDecodeBounds = true
    }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)

    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
      logDebug("decodeSampledBitmap invalid bounds")
      return null
    }

    val options = BitmapFactory.Options().apply {
      inSampleSize = calculateInSampleSize(bounds.outWidth, bounds.outHeight)
      inPreferredConfig = Bitmap.Config.RGB_565
    }

    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
  }

  private fun calculateInSampleSize(width: Int, height: Int): Int {
    var inSampleSize = 1
    var maxDimension = maxOf(width, height)

    while (maxDimension / inSampleSize > MAX_DECODE_DIMENSION) {
      inSampleSize *= 2
    }

    return inSampleSize.coerceAtLeast(1)
  }

  private fun readOrientation(stream: InputStream): Int {
    return try {
      ExifInterface(stream).getAttributeInt(
        ExifInterface.TAG_ORIENTATION,
        ExifInterface.ORIENTATION_NORMAL
      )
    } catch (_: Exception) {
      ExifInterface.ORIENTATION_NORMAL
    }
  }

  private fun rotateBitmapIfRequired(bitmap: Bitmap, orientation: Int): Bitmap {
    return when (orientation) {
      ExifInterface.ORIENTATION_ROTATE_90 -> rotateBitmap(bitmap, 90f) ?: bitmap
      ExifInterface.ORIENTATION_ROTATE_180 -> rotateBitmap(bitmap, 180f) ?: bitmap
      ExifInterface.ORIENTATION_ROTATE_270 -> rotateBitmap(bitmap, 270f) ?: bitmap
      else -> bitmap
    }
  }

  private fun rotateBitmap(source: Bitmap, angle: Float): Bitmap? {
    val matrix = Matrix().apply {
      postRotate(angle)
    }

    return try {
      Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
    } catch (_: Exception) {
      logWarn("rotateBitmap failed angle=$angle")
      null
    }
  }

  private fun looksLikeBase64(value: String): Boolean {
    val compact = value.replace("\\s".toRegex(), "")
    return compact.length >= 32 && compact.length % 4 == 0 && base64Regex.matches(compact)
  }

  private fun resolveFilePathFromUri(uri: Uri): String? {
    val rawPath = uri.path ?: return null
    return Uri.decode(rawPath)
  }
}
