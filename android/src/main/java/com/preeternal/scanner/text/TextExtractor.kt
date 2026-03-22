package com.preeternal.scanner.text

import android.content.Context

data class NormalizedBoundingBox(
  val left: Double,
  val top: Double,
  val width: Double,
  val height: Double
)

data class TextLineResult(
  val text: String,
  val boundingBox: NormalizedBoundingBox?
)

data class TextBlockResult(
  val text: String,
  val sourceImageIndex: Int,
  val boundingBox: NormalizedBoundingBox?,
  val lines: List<TextLineResult>
)

interface TextExtractor {
  fun isFeatureEnabled(): Boolean
  fun extractFromSource(
    context: Context,
    imageSource: String,
    sourceImageIndex: Int,
    enableRotate180Fallback: Boolean,
    callback: (List<TextBlockResult>) -> Unit
  )
}
