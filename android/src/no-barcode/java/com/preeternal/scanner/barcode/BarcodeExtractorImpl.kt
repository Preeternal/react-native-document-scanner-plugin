package com.preeternal.scanner.barcode

import android.content.Context

class BarcodeExtractorImpl : BarcodeExtractor {
  override fun isFeatureEnabled(): Boolean = false

  override fun extractFromSource(
    context: Context,
    imageSource: String,
    sourceImageIndex: Int,
    allowedFormats: Set<String>,
    callback: (List<BarcodeResult>) -> Unit
  ) {
    callback(emptyList())
  }
}
