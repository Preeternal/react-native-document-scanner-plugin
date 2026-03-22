package com.preeternal.scanner.barcode

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.Rect
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import kotlin.math.floor
import kotlin.math.roundToInt

class BarcodeExtractorImpl : BarcodeExtractor {
  companion object {
    private const val CROP_WIDTH_PERCENT = 25.0f
    private const val CROP_HEIGHT_PERCENT = 20.0f
    private const val CORNER_MARGIN_PERCENT = 3.0f
    private const val CENTER_BUCKETS = 24

    private val formatToMlKit = mapOf(
      BarcodeFormats.AZTEC to Barcode.FORMAT_AZTEC,
      BarcodeFormats.CODABAR to Barcode.FORMAT_CODABAR,
      BarcodeFormats.CODE_39 to Barcode.FORMAT_CODE_39,
      BarcodeFormats.CODE_93 to Barcode.FORMAT_CODE_93,
      BarcodeFormats.CODE_128 to Barcode.FORMAT_CODE_128,
      BarcodeFormats.DATA_MATRIX to Barcode.FORMAT_DATA_MATRIX,
      BarcodeFormats.EAN_8 to Barcode.FORMAT_EAN_8,
      BarcodeFormats.EAN_13 to Barcode.FORMAT_EAN_13,
      BarcodeFormats.ITF to Barcode.FORMAT_ITF,
      BarcodeFormats.PDF_417 to Barcode.FORMAT_PDF417,
      BarcodeFormats.QR to Barcode.FORMAT_QR_CODE,
      BarcodeFormats.UPC_A to Barcode.FORMAT_UPC_A,
      BarcodeFormats.UPC_E to Barcode.FORMAT_UPC_E
    )
  }

  private val scannerCache = mutableMapOf<String, BarcodeScanner>()

  private data class BarcodeCandidate(
    val dedupKey: String,
    val result: BarcodeResult
  )

  override fun isFeatureEnabled(): Boolean = true

  override fun extractFromSource(
    context: Context,
    imageSource: String,
    sourceImageIndex: Int,
    allowedFormats: Set<String>,
    callback: (List<BarcodeResult>) -> Unit
  ) {
    val normalizedAllowList = BarcodeFormats.normalizeRequestedFormats(allowedFormats.toList())
    val sourceBitmap = BarcodeImageSourceLoader.loadBitmap(context, imageSource) ?: run {
      callback(emptyList())
      return
    }

    val scanner = scannerForAllowedFormats(normalizedAllowList)
    processAttempt(
      scanner = scanner,
      sourceBitmap = sourceBitmap,
      sourceImageIndex = sourceImageIndex,
      allowedFormats = normalizedAllowList,
      attemptIndex = 0,
      collected = LinkedHashMap(),
      callback = callback
    )
  }

  private fun processAttempt(
    scanner: BarcodeScanner,
    sourceBitmap: Bitmap,
    sourceImageIndex: Int,
    allowedFormats: Set<String>,
    attemptIndex: Int,
    collected: LinkedHashMap<String, BarcodeResult>,
    callback: (List<BarcodeResult>) -> Unit
  ) {
    if (attemptIndex >= 4) {
      callback(collected.values.toList())
      return
    }

    if (attemptIndex > 0 && collected.isNotEmpty()) {
      callback(collected.values.toList())
      return
    }

    val angle = when (attemptIndex) {
      0 -> 0f
      1 -> 180f
      2 -> 90f
      else -> -90f
    }

    val candidate = if (angle == 0f) {
      sourceBitmap
    } else {
      rotateBitmap(sourceBitmap, angle)
    }

    if (candidate == null) {
      processAttempt(
        scanner,
        sourceBitmap,
        sourceImageIndex,
        allowedFormats,
        attemptIndex + 1,
        collected,
        callback
      )
      return
    }

    val roiBitmap = cropTopRightRoi(candidate)
    if (roiBitmap == null) {
      processAttempt(
        scanner,
        sourceBitmap,
        sourceImageIndex,
        allowedFormats,
        attemptIndex + 1,
        collected,
        callback
      )
      return
    }

    val input = InputImage.fromBitmap(roiBitmap, 0)
    scanner.process(input)
      .addOnSuccessListener { barcodes ->
        val mapped = barcodesToCandidates(
          barcodes = barcodes,
          sourceImageIndex = sourceImageIndex,
          allowedFormats = allowedFormats,
          attemptIndex = attemptIndex,
          roiWidth = roiBitmap.width,
          roiHeight = roiBitmap.height
        )
        for (candidateResult in mapped) {
          if (!collected.containsKey(candidateResult.dedupKey)) {
            collected[candidateResult.dedupKey] = candidateResult.result
          }
        }

        processAttempt(
          scanner,
          sourceBitmap,
          sourceImageIndex,
          allowedFormats,
          attemptIndex + 1,
          collected,
          callback
        )
      }
      .addOnFailureListener {
        processAttempt(
          scanner,
          sourceBitmap,
          sourceImageIndex,
          allowedFormats,
          attemptIndex + 1,
          collected,
          callback
        )
      }
  }

  private fun barcodesToCandidates(
    barcodes: List<Barcode>,
    sourceImageIndex: Int,
    allowedFormats: Set<String>,
    attemptIndex: Int,
    roiWidth: Int,
    roiHeight: Int
  ): List<BarcodeCandidate> {
    val dedup = LinkedHashMap<String, BarcodeCandidate>()

    for (barcode in barcodes) {
      val value = barcode.rawValue?.trim()
      if (value.isNullOrEmpty()) {
        continue
      }

      val format = normalizeFormat(barcode.format)
      if (allowedFormats.isNotEmpty() && !allowedFormats.contains(format)) {
        continue
      }

      val instanceKey = buildInstanceKey(
        format = format,
        value = value,
        attemptIndex = attemptIndex,
        boundingBox = barcode.boundingBox,
        roiWidth = roiWidth,
        roiHeight = roiHeight
      )
      if (!dedup.containsKey(instanceKey)) {
        dedup[instanceKey] = BarcodeCandidate(
          dedupKey = instanceKey,
          result = BarcodeResult(
            value = value,
            format = format,
            sourceImageIndex = sourceImageIndex
          )
        )
      }
    }

    return dedup.values.toList()
  }

  private fun buildInstanceKey(
    format: String,
    value: String,
    attemptIndex: Int,
    boundingBox: Rect?,
    roiWidth: Int,
    roiHeight: Int
  ): String {
    val bucket = centerBucketKey(boundingBox, roiWidth, roiHeight)
    return "$format|$value|a$attemptIndex|$bucket"
  }

  private fun centerBucketKey(
    boundingBox: Rect?,
    imageWidth: Int,
    imageHeight: Int
  ): String {
    if (boundingBox == null || imageWidth <= 0 || imageHeight <= 0) {
      return "u"
    }

    val centerX = (((boundingBox.left + boundingBox.right) * 0.5f) / imageWidth.toFloat())
      .coerceIn(0f, 1f)
    val centerY = (((boundingBox.top + boundingBox.bottom) * 0.5f) / imageHeight.toFloat())
      .coerceIn(0f, 1f)

    val xBucket = quantize(centerX)
    val yBucket = quantize(centerY)
    return "$xBucket:$yBucket"
  }

  private fun quantize(value: Float): Int {
    if (CENTER_BUCKETS <= 1) {
      return 0
    }

    val clamped = value.coerceIn(0f, 1f)
    val scaled = floor((clamped * CENTER_BUCKETS.toFloat()).toDouble()).toInt()
    return scaled.coerceIn(0, CENTER_BUCKETS - 1)
  }

  private fun normalizeFormat(format: Int): String {
    return when (format) {
      Barcode.FORMAT_AZTEC -> BarcodeFormats.AZTEC
      Barcode.FORMAT_CODABAR -> BarcodeFormats.CODABAR
      Barcode.FORMAT_CODE_39 -> BarcodeFormats.CODE_39
      Barcode.FORMAT_CODE_93 -> BarcodeFormats.CODE_93
      Barcode.FORMAT_CODE_128 -> BarcodeFormats.CODE_128
      Barcode.FORMAT_DATA_MATRIX -> BarcodeFormats.DATA_MATRIX
      Barcode.FORMAT_EAN_8 -> BarcodeFormats.EAN_8
      Barcode.FORMAT_EAN_13 -> BarcodeFormats.EAN_13
      Barcode.FORMAT_ITF -> BarcodeFormats.ITF
      Barcode.FORMAT_PDF417 -> BarcodeFormats.PDF_417
      Barcode.FORMAT_QR_CODE -> BarcodeFormats.QR
      Barcode.FORMAT_UPC_A -> BarcodeFormats.UPC_A
      Barcode.FORMAT_UPC_E -> BarcodeFormats.UPC_E
      else -> BarcodeFormats.UNKNOWN
    }
  }

  private fun cropTopRightRoi(bitmap: Bitmap): Bitmap? {
    // ROI tuned for shipping-label top-right barcode placement.
    val width = bitmap.width
    val height = bitmap.height
    if (width <= 1 || height <= 1) {
      return null
    }

    val cropWidth = (width * (CROP_WIDTH_PERCENT / 100f)).roundToInt().coerceAtLeast(1)
    val cropHeight = (height * (CROP_HEIGHT_PERCENT / 100f)).roundToInt().coerceAtLeast(1)
    val marginX = (width * (CORNER_MARGIN_PERCENT / 100f)).roundToInt()
    val marginY = (height * (CORNER_MARGIN_PERCENT / 100f)).roundToInt()

    val left = (width - cropWidth - marginX).coerceAtLeast(0)
    val top = marginY.coerceAtLeast(0)
    val right = (left + cropWidth).coerceAtMost(width)
    val bottom = (top + cropHeight).coerceAtMost(height)
    val finalWidth = right - left
    val finalHeight = bottom - top

    if (finalWidth <= 1 || finalHeight <= 1) {
      return null
    }

    return try {
      Bitmap.createBitmap(bitmap, left, top, finalWidth, finalHeight)
    } catch (_: IllegalArgumentException) {
      null
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

  private fun scannerForAllowedFormats(allowedFormats: Set<String>): BarcodeScanner {
    val key = allowedFormats.sorted().joinToString(",")
    return scannerCache.getOrPut(key) {
      createScanner(allowedFormats)
    }
  }

  private fun createScanner(allowedFormats: Set<String>): BarcodeScanner {
    val optionsBuilder = BarcodeScannerOptions.Builder()
    val requestedFormats = allowedFormats
      .mapNotNull { formatToMlKit[it] }
      .distinct()

    if (requestedFormats.isNotEmpty()) {
      val first = requestedFormats.first()
      val rest = requestedFormats.drop(1).toIntArray()
      optionsBuilder.setBarcodeFormats(first, *rest)
    }

    return BarcodeScanning.getClient(optionsBuilder.build())
  }
}
