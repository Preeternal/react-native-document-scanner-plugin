package com.preeternal.scanner.text

import android.content.Context

class TextExtractorImpl : TextExtractor {
  override fun isFeatureEnabled(): Boolean = false

  override fun extractFromSource(
    context: Context,
    imageSource: String,
    sourceImageIndex: Int,
    enableRotate180Fallback: Boolean,
    callback: (List<TextBlockResult>) -> Unit
  ) {
    callback(emptyList())
  }
}
