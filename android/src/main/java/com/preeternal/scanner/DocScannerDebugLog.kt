package com.preeternal.scanner

import android.util.Log

internal object DocScannerDebugLog {
  private const val MAIN_TAG = "DocumentScanner"
  private const val BARCODE_TAG = "DocumentScannerBarcode"

  private const val DEBUG_ENV = "DOCUMENT_SCANNER_DEBUG_LOGS"
  private const val TRACE_ENV = "DOCUMENT_SCANNER_TRACE_LOGS"

  private const val DEBUG_PROP = "debug.document_scanner.debug_logs"
  private const val TRACE_PROP = "debug.document_scanner.trace_logs"

  private data class FixedFlags(
    val debugEnabled: Boolean,
    val traceEnabled: Boolean
  )

  // Resolve env/system-property flags once to avoid reflection in hot logging paths.
  private val fixedFlags: FixedFlags by lazy(LazyThreadSafetyMode.PUBLICATION) {
    val debug = flagEnabled(DEBUG_ENV) || propertyEnabled(DEBUG_PROP)
    val trace = flagEnabled(TRACE_ENV) || propertyEnabled(TRACE_PROP)
    FixedFlags(
      debugEnabled = debug || trace,
      traceEnabled = trace
    )
  }

  fun debug(tag: String, message: String) {
    if (isDebugEnabled()) {
      Log.d(tag, message)
    }
  }

  fun warn(tag: String, message: String) {
    if (isDebugEnabled()) {
      Log.w(tag, message)
    }
  }

  fun trace(tag: String, message: String) {
    if (isTraceEnabled()) {
      Log.v(tag, message)
    }
  }

  private fun isDebugEnabled(): Boolean {
    return fixedFlags.debugEnabled ||
      Log.isLoggable(MAIN_TAG, Log.DEBUG) ||
      Log.isLoggable(BARCODE_TAG, Log.DEBUG)
  }

  private fun isTraceEnabled(): Boolean {
    return fixedFlags.traceEnabled ||
      Log.isLoggable(MAIN_TAG, Log.VERBOSE) ||
      Log.isLoggable(BARCODE_TAG, Log.VERBOSE)
  }

  private fun flagEnabled(name: String): Boolean {
    val value = System.getenv(name)
    return isTruthy(value)
  }

  private fun propertyEnabled(name: String): Boolean {
    val value = readSystemProperty(name)
    return isTruthy(value)
  }

  private fun isTruthy(value: String?): Boolean {
    return value == "1" || value.equals("true", ignoreCase = true)
  }

  private fun readSystemProperty(name: String): String? {
    return try {
      val clazz = Class.forName("android.os.SystemProperties")
      val method = clazz.getMethod("get", String::class.java)
      method.invoke(null, name) as? String
    } catch (_: Exception) {
      null
    }
  }
}
