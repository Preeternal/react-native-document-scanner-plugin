package com.preeternal.scanner.barcode

import android.content.Context

data class BarcodeResult(
  val value: String,
  val format: String,
  val sourceImageIndex: Int
)

interface BarcodeExtractor {
  fun isFeatureEnabled(): Boolean
  fun extractFromSource(
    context: Context,
    imageSource: String,
    sourceImageIndex: Int,
    allowedFormats: Set<String>,
    callback: (List<BarcodeResult>) -> Unit
  )
}
