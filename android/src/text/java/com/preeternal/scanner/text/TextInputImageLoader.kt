package com.preeternal.scanner.text

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import com.google.mlkit.vision.common.InputImage
import java.io.File
import java.io.InputStream

internal object TextInputImageLoader {
  private val base64Regex = Regex("^[A-Za-z0-9+/=\\s]+$")

  fun load(context: Context, imageSource: String): InputImage? {
    val normalized = imageSource.trim()
    if (normalized.isEmpty()) {
      return null
    }

    if (normalized.startsWith("data:", ignoreCase = true) && normalized.contains("base64,")) {
      val payload = normalized.substringAfter("base64,", "")
      return decodeBase64(payload)
    }

    if (normalized.startsWith("content://", ignoreCase = true)) {
      return fromUri(context, Uri.parse(normalized))
    }

    if (normalized.startsWith("file://", ignoreCase = true)) {
      return fromUri(context, Uri.parse(normalized))
    }

    if (File(normalized).exists()) {
      return fromUri(context, Uri.fromFile(File(normalized)))
    }

    if (looksLikeBase64(normalized)) {
      return decodeBase64(normalized)
    }

    val parsed = Uri.parse(normalized)
    return when (parsed.scheme?.lowercase()) {
      "content", "file" -> fromUri(context, parsed)
      null, "" -> {
        val file = File(normalized)
        if (file.exists()) {
          fromUri(context, Uri.fromFile(file))
        } else {
          null
        }
      }
      else -> fromUri(context, parsed)
    }
  }

  fun loadWithAdditionalRotation(
    context: Context,
    imageSource: String,
    additionalRotationDegrees: Int
  ): InputImage? {
    val normalizedDegrees = ((additionalRotationDegrees % 360) + 360) % 360
    if (normalizedDegrees == 0) {
      return load(context, imageSource)
    }

    val bitmap = loadBitmap(context, imageSource) ?: return null
    return try {
      InputImage.fromBitmap(bitmap, normalizedDegrees)
    } catch (_: Exception) {
      null
    }
  }

  private fun fromUri(context: Context, uri: Uri): InputImage? {
    return try {
      InputImage.fromFilePath(context, uri)
    } catch (_: Exception) {
      null
    }
  }

  private fun decodeBase64(payload: String): InputImage? {
    return try {
      val decoded = Base64.decode(payload, Base64.DEFAULT)
      val bitmap = BitmapFactory.decodeByteArray(decoded, 0, decoded.size) ?: return null
      InputImage.fromBitmap(bitmap, 0)
    } catch (_: Exception) {
      null
    }
  }

  private fun looksLikeBase64(value: String): Boolean {
    val compact = value.replace("\\s".toRegex(), "")
    return compact.length >= 32 && compact.length % 4 == 0 && base64Regex.matches(compact)
  }

  private fun loadBitmap(context: Context, imageSource: String): Bitmap? {
    val normalized = imageSource.trim()
    if (normalized.isEmpty()) {
      return null
    }

    if (normalized.startsWith("data:", ignoreCase = true) && normalized.contains("base64,")) {
      val payload = normalized.substringAfter("base64,", "")
      return decodeBitmapFromBase64(payload)
    }

    if (normalized.startsWith("content://", ignoreCase = true)) {
      return decodeBitmapFromUri(context, Uri.parse(normalized))
    }

    if (normalized.startsWith("file://", ignoreCase = true)) {
      return decodeBitmapFromUri(context, Uri.parse(normalized))
    }

    if (File(normalized).exists()) {
      return decodeBitmapFromFile(normalized)
    }

    if (looksLikeBase64(normalized)) {
      return decodeBitmapFromBase64(normalized)
    }

    val parsed = Uri.parse(normalized)
    return when (parsed.scheme?.lowercase()) {
      "content", "file" -> decodeBitmapFromUri(context, parsed)
      null, "" -> {
        val file = File(normalized)
        if (file.exists()) {
          decodeBitmapFromFile(file.path)
        } else {
          null
        }
      }
      else -> decodeBitmapFromUri(context, parsed)
    }
  }

  private fun decodeBitmapFromUri(context: Context, uri: Uri): Bitmap? {
    return try {
      context.contentResolver.openInputStream(uri)?.use { decodeBitmapFromStream(it) }
    } catch (_: Exception) {
      null
    }
  }

  private fun decodeBitmapFromFile(path: String): Bitmap? {
    return try {
      BitmapFactory.decodeFile(path)
    } catch (_: Exception) {
      null
    }
  }

  private fun decodeBitmapFromStream(stream: InputStream): Bitmap? {
    return try {
      BitmapFactory.decodeStream(stream)
    } catch (_: Exception) {
      null
    }
  }

  private fun decodeBitmapFromBase64(payload: String): Bitmap? {
    return try {
      val decoded = Base64.decode(payload, Base64.DEFAULT)
      BitmapFactory.decodeByteArray(decoded, 0, decoded.size)
    } catch (_: IllegalArgumentException) {
      null
    }
  }
}
