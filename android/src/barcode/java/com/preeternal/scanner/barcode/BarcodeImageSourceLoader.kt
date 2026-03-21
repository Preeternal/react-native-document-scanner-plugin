package com.preeternal.scanner.barcode

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.util.Base64
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.FileInputStream
import java.io.InputStream

internal object BarcodeImageSourceLoader {
  private const val MAX_DECODE_DIMENSION = 2048
  private val base64Regex = Regex("^[A-Za-z0-9+/=\\s]+$")

  fun loadBitmap(context: Context, imageSource: String): Bitmap? {
    val normalized = imageSource.trim()
    if (normalized.isEmpty()) {
      return null
    }

    if (normalized.startsWith("data:", ignoreCase = true) && normalized.contains("base64,")) {
      val payload = normalized.substringAfter("base64,", "")
      return decodeFromBase64(payload)
    }

    if (normalized.startsWith("content://", ignoreCase = true)) {
      return loadFromUri(context, Uri.parse(normalized))
    }

    if (normalized.startsWith("file://", ignoreCase = true)) {
      return loadFromFilePath(Uri.parse(normalized).path)
    }

    if (File(normalized).exists()) {
      return loadFromFilePath(normalized)
    }

    if (looksLikeBase64(normalized)) {
      return decodeFromBase64(normalized)
    }

    val parsed = Uri.parse(normalized)
    return when (parsed.scheme?.lowercase()) {
      "content" -> loadFromUri(context, parsed)
      "file" -> loadFromFilePath(parsed.path)
      else -> null
    }
  }

  private fun decodeFromBase64(payload: String): Bitmap? {
    return try {
      val decoded = Base64.decode(payload, Base64.DEFAULT)
      decodeSampledBitmap(decoded)
    } catch (_: IllegalArgumentException) {
      null
    }
  }

  private fun loadFromUri(context: Context, uri: Uri): Bitmap? {
    val bitmap = context.contentResolver.openInputStream(uri)?.use { decodeSampledBitmap(it) }
      ?: return null
    val orientation = context.contentResolver.openInputStream(uri)?.use {
      readOrientation(it)
    } ?: ExifInterface.ORIENTATION_NORMAL

    return rotateBitmapIfRequired(bitmap, orientation)
  }

  private fun loadFromFilePath(path: String?): Bitmap? {
    if (path.isNullOrBlank()) {
      return null
    }

    val file = File(path)
    if (!file.exists() || !file.isFile) {
      return null
    }

    val bitmap = FileInputStream(file).use { decodeSampledBitmap(it) } ?: return null
    val orientation = FileInputStream(file).use {
      readOrientation(it)
    }

    return rotateBitmapIfRequired(bitmap, orientation)
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
      null
    }
  }

  private fun looksLikeBase64(value: String): Boolean {
    val compact = value.replace("\\s".toRegex(), "")
    return compact.length >= 32 && compact.length % 4 == 0 && base64Regex.matches(compact)
  }
}
