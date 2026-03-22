package com.preeternal.scanner.text

import android.content.Context
import android.graphics.Rect
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlin.math.floor

class TextExtractorImpl : TextExtractor {
  private companion object {
    private const val OCR_ROTATE_FALLBACK_DEGREES = 180
    private const val MIN_TEXT_CHARS_FOR_SINGLE_PASS = 24
    private const val CENTER_BUCKETS = 24
    private val WHITESPACE_REGEX = Regex("\\s+")
  }

  private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

  override fun isFeatureEnabled(): Boolean = true

  override fun extractFromSource(
    context: Context,
    imageSource: String,
    sourceImageIndex: Int,
    enableRotate180Fallback: Boolean,
    callback: (List<TextBlockResult>) -> Unit
  ) {
    val inputImage = TextInputImageLoader.load(context, imageSource) ?: run {
      callback(emptyList())
      return
    }

    recognize(inputImage, sourceImageIndex) { firstPass ->
      if (!enableRotate180Fallback || !shouldRunRotateFallback(firstPass)) {
        callback(firstPass)
        return@recognize
      }

      val rotatedInput = TextInputImageLoader.loadWithAdditionalRotation(
        context = context,
        imageSource = imageSource,
        additionalRotationDegrees = OCR_ROTATE_FALLBACK_DEGREES
      )
      if (rotatedInput == null) {
        callback(firstPass)
        return@recognize
      }

      recognize(rotatedInput, sourceImageIndex) { secondPass ->
        if (totalCharacterCount(secondPass) > totalCharacterCount(firstPass)) {
          callback(secondPass)
        } else {
          callback(firstPass)
        }
      }
    }
  }

  private fun recognize(
    inputImage: com.google.mlkit.vision.common.InputImage,
    sourceImageIndex: Int,
    callback: (List<TextBlockResult>) -> Unit
  ) {
    recognizer.process(inputImage)
      .addOnSuccessListener { text ->
        callback(
          mapTextBlocks(
            text = text,
            sourceImageIndex = sourceImageIndex,
            imageWidth = inputImage.width,
            imageHeight = inputImage.height
          )
        )
      }
      .addOnFailureListener {
        callback(emptyList())
      }
  }

  private fun shouldRunRotateFallback(blocks: List<TextBlockResult>): Boolean {
    if (blocks.isEmpty()) {
      return true
    }

    return totalCharacterCount(blocks) < MIN_TEXT_CHARS_FOR_SINGLE_PASS
  }

  private fun totalCharacterCount(blocks: List<TextBlockResult>): Int {
    var total = 0
    for (block in blocks) {
      total += block.text.length
    }
    return total
  }

  private fun mapTextBlocks(
    text: Text,
    sourceImageIndex: Int,
    imageWidth: Int,
    imageHeight: Int
  ): List<TextBlockResult> {
    val mapped = mutableListOf<TextBlockResult>()
    val deduplicated = mutableSetOf<String>()

    for (block in text.textBlocks) {
      val blockText = block.text.trim()
      if (blockText.isEmpty()) {
        continue
      }

      val lines = block.lines.mapNotNull { line ->
        val lineText = line.text.trim()
        if (lineText.isEmpty()) {
          return@mapNotNull null
        }

        TextLineResult(
          text = lineText,
          boundingBox = normalizeBoundingBox(line.boundingBox, imageWidth, imageHeight)
        )
      }

      val mappedBlock = TextBlockResult(
        text = blockText,
        sourceImageIndex = sourceImageIndex,
        boundingBox = normalizeBoundingBox(block.boundingBox, imageWidth, imageHeight),
        lines = lines
      )

      val dedupKey = buildTextBlockDedupKey(mappedBlock)
      if (dedupKey != null && !deduplicated.add(dedupKey)) {
        continue
      }

      mapped.add(mappedBlock)
    }

    return mapped.sortedWith(
      compareBy<TextBlockResult>(
        { it.sourceImageIndex },
        { it.boundingBox?.top ?: Double.MAX_VALUE },
        { it.boundingBox?.left ?: Double.MAX_VALUE },
        { it.text }
      )
    )
  }

  private fun normalizeBoundingBox(
    rect: Rect?,
    imageWidth: Int,
    imageHeight: Int
  ): NormalizedBoundingBox? {
    if (rect == null || imageWidth <= 0 || imageHeight <= 0) {
      return null
    }

    val width = (rect.width().toDouble() / imageWidth.toDouble()).coerceIn(0.0, 1.0)
    val height = (rect.height().toDouble() / imageHeight.toDouble()).coerceIn(0.0, 1.0)
    val left = (rect.left.toDouble() / imageWidth.toDouble()).coerceIn(0.0, 1.0)
    val top = (rect.top.toDouble() / imageHeight.toDouble()).coerceIn(0.0, 1.0)

    return NormalizedBoundingBox(
      left = left,
      top = top,
      width = width,
      height = height
    )
  }

  private fun buildTextBlockDedupKey(block: TextBlockResult): String? {
    val normalizedText = normalizeTextForDedup(block.text)
    if (normalizedText.isEmpty()) {
      return null
    }

    val bucket = centerBucketKey(block.boundingBox) ?: return null
    return "${block.sourceImageIndex}|$normalizedText|$bucket"
  }

  private fun normalizeTextForDedup(value: String): String {
    return value
      .trim()
      .lowercase()
      .split(WHITESPACE_REGEX)
      .filter { it.isNotEmpty() }
      .joinToString(" ")
  }

  private fun centerBucketKey(boundingBox: NormalizedBoundingBox?): String? {
    if (boundingBox == null) {
      return null
    }

    val centerX = (boundingBox.left + (boundingBox.width * 0.5)).coerceIn(0.0, 1.0)
    val centerY = (boundingBox.top + (boundingBox.height * 0.5)).coerceIn(0.0, 1.0)
    val xBucket = quantize(centerX)
    val yBucket = quantize(centerY)
    return "$xBucket:$yBucket"
  }

  private fun quantize(value: Double): Int {
    if (CENTER_BUCKETS <= 1) {
      return 0
    }

    val scaled = floor(value.coerceIn(0.0, 1.0) * CENTER_BUCKETS.toDouble()).toInt()
    return scaled.coerceIn(0, CENTER_BUCKETS - 1)
  }
}
