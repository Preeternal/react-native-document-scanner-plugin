package com.preeternal.scanner

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.util.Base64
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.view.WindowCompat
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableNativeArray
import com.facebook.react.bridge.WritableNativeMap
import com.facebook.react.module.annotations.ReactModule
import com.google.mlkit.vision.documentscanner.GmsDocumentScanner
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.preeternal.scanner.barcode.BarcodeExtractor
import com.preeternal.scanner.barcode.BarcodeExtractorImpl
import com.preeternal.scanner.barcode.BarcodeFormats
import com.preeternal.scanner.barcode.BarcodeResult
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.lang.ref.WeakReference
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@ReactModule(name = DocumentScannerModule.NAME)
class DocumentScannerModule(reactContext: ReactApplicationContext) :
  NativeDocumentScannerSpec(reactContext) {

  companion object {
    const val NAME = "DocumentScanner"
    private const val ANDROID_15_API = 35
  }

  override fun getName(): String = NAME

  private val barcodeExtractor: BarcodeExtractor = BarcodeExtractorImpl()

  private var launcher: ActivityResultLauncher<IntentSenderRequest>? = null
  private var pendingPromise: Promise? = null
  private var pendingOptions: ReadableMap? = null
  private var pendingQuality: Int = 100
  private var scanner: GmsDocumentScanner? = null

  private var hostActivityRef: WeakReference<ComponentActivity>? = null
  private var previousFitsSystemWindows: Boolean? = null

  override fun scanDocument(options: ReadableMap, promise: Promise) {
    val activity = currentActivity
    if (activity == null) {
      promise.reject("no_activity", "Activity not available")
      return
    }
    val componentActivity = activity as? ComponentActivity
    if (componentActivity == null) {
      promise.reject("invalid_activity", "Activity is not a ComponentActivity")
      return
    }
    if (pendingPromise != null) {
      promise.reject("scan_in_progress", "Scan already in progress")
      return
    }

    pendingPromise = promise
    pendingOptions = options
    pendingQuality = if (options.hasKey("croppedImageQuality")) options.getInt("croppedImageQuality") else 100

    hostActivityRef = WeakReference(componentActivity)
    ensureSystemBarsVisible(componentActivity)

    initLauncher(componentActivity)
    initScanner(options)
    startScan(activity)
  }

  override fun extractBarcodesFromImages(options: ReadableMap, promise: Promise) {
    if (!barcodeExtractor.isFeatureEnabled()) {
      promise.reject(
        "barcode_not_enabled",
        "Barcode extraction feature is disabled. Enable -PenableBarcode=true to build with barcode support."
      )
      return
    }

    val images = getArrayOrNull(options, "images")
    if (images == null || images.size() == 0) {
      promise.resolve(WritableNativeArray())
      return
    }

    val allowedFormats = parseAllowedFormats(getArrayOrNull(options, "barcodeFormats"))
    val requestedConcurrency = getIntOrNull(options, "concurrency") ?: 2
    val concurrency = requestedConcurrency.coerceIn(1, 2)

    extractBarcodesInParallel(
      context = reactApplicationContext,
      images = images,
      allowedFormats = allowedFormats,
      concurrency = concurrency,
      promise = promise
    )
  }

  private fun initScanner(options: ReadableMap) {
    val builder = GmsDocumentScannerOptions.Builder()
      .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
      .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)

    if (options.hasKey("maxNumDocuments")) {
      builder.setPageLimit(options.getInt("maxNumDocuments"))
    }
    scanner = GmsDocumentScanning.getClient(builder.build())
  }

  private fun initLauncher(activity: ComponentActivity) {
    if (launcher != null) return
    launcher = activity.activityResultRegistry.register(
      "document-scanner",
      ActivityResultContracts.StartIntentSenderForResult()
    ) { result ->
      val promise = pendingPromise ?: return@register
      val options = pendingOptions
      val response = WritableNativeMap()
      val images = WritableNativeArray()

      if (result.resultCode == Activity.RESULT_OK) {
        val docResult = GmsDocumentScanningResult.fromActivityResultIntent(result.data)
        val pages = docResult?.pages.orEmpty()
        val responseType = options?.getString("responseType")?.lowercase()

        processPages(
          activity = activity,
          pages = pages,
          pageIndex = 0,
          responseType = responseType,
          images = images,
          onError = { errorMessage ->
            promise.reject("document_scan_error", errorMessage, null)
            clearPending()
          },
          onComplete = {
            response.putString("status", "success")
            response.putArray("scannedImages", images)
            promise.resolve(response)
            clearPending()
          }
        )
      } else {
        response.putString("status", "cancel")
        response.putArray("scannedImages", images)
        promise.resolve(response)
        clearPending()
      }
    }
  }

  private fun processPages(
    activity: Activity,
    pages: List<GmsDocumentScanningResult.Page>,
    pageIndex: Int,
    responseType: String?,
    images: WritableNativeArray,
    onError: (String) -> Unit,
    onComplete: () -> Unit
  ) {
    if (pageIndex >= pages.size) {
      onComplete()
      return
    }

    val uri = pages[pageIndex].imageUri

    val outputImage = try {
      mapOutputImage(activity, uri, responseType)
    } catch (e: FileNotFoundException) {
      onError(e.message ?: "Unable to read scanned image")
      return
    }

    if (outputImage == null || outputImage.isBlank()) {
      processPages(
        activity = activity,
        pages = pages,
        pageIndex = pageIndex + 1,
        responseType = responseType,
        images = images,
        onError = onError,
        onComplete = onComplete
      )
      return
    }

    images.pushString(outputImage)
    processPages(
      activity = activity,
      pages = pages,
      pageIndex = pageIndex + 1,
      responseType = responseType,
      images = images,
      onError = onError,
      onComplete = onComplete
    )
  }

  private fun mapOutputImage(
    activity: Activity,
    uri: Uri,
    responseType: String?
  ): String? {
    // Keep existing API contract: scannedImages is base64[] or uri[] depending on responseType.
    return if (responseType == "base64") {
      val encoded = uriToBase64(activity, uri, pendingQuality)
      if (encoded.isBlank()) null else encoded
    } else {
      if (canReadUri(activity, uri)) uri.toString() else null
    }
  }

  private fun toWritableBarcode(barcode: BarcodeResult): WritableNativeMap {
    val map = WritableNativeMap()
    map.putString("value", barcode.value)
    map.putString("format", barcode.format)
    map.putInt("sourceImageIndex", barcode.sourceImageIndex)
    return map
  }

  private data class IndexedImageSource(
    val sourceImageIndex: Int,
    val imageSource: String
  )

  private fun extractBarcodesInParallel(
    context: ReactApplicationContext,
    images: ReadableArray,
    allowedFormats: Set<String>,
    concurrency: Int,
    promise: Promise
  ) {
    val validSources = mutableListOf<IndexedImageSource>()
    for (index in 0 until images.size()) {
      val imageSource = readStringAt(images, index)
      if (!imageSource.isNullOrBlank()) {
        validSources.add(
          IndexedImageSource(
            sourceImageIndex = index,
            imageSource = imageSource
          )
        )
      }
    }

    if (validSources.isEmpty()) {
      promise.resolve(WritableNativeArray())
      return
    }

    val workerPool = Executors.newFixedThreadPool(concurrency)
    val completionLatch = CountDownLatch(validSources.size)
    val collected = Collections.synchronizedList(mutableListOf<BarcodeResult>())

    for (entry in validSources) {
      workerPool.execute {
        try {
          val detected = extractBarcodesForSource(
            context = context,
            imageSource = entry.imageSource,
            sourceImageIndex = entry.sourceImageIndex,
            allowedFormats = allowedFormats
          )
          if (detected.isNotEmpty()) {
            collected.addAll(detected)
          }
        } finally {
          completionLatch.countDown()
        }
      }
    }

    Thread {
      try {
        completionLatch.await()

        val sorted = collected.sortedWith(
          compareBy<BarcodeResult>({ it.sourceImageIndex }, { it.value }, { it.format })
        )
        val payload = WritableNativeArray()
        for (barcode in sorted) {
          payload.pushMap(toWritableBarcode(barcode))
        }

        reactApplicationContext.runOnUiQueueThread {
          promise.resolve(payload)
        }
      } catch (e: InterruptedException) {
        Thread.currentThread().interrupt()
        reactApplicationContext.runOnUiQueueThread {
          promise.reject("barcode_extraction_error", "Barcode extraction interrupted", e)
        }
      } catch (e: Exception) {
        reactApplicationContext.runOnUiQueueThread {
          promise.reject("barcode_extraction_error", e.message, e)
        }
      } finally {
        workerPool.shutdown()
      }
    }.start()
  }

  private fun extractBarcodesForSource(
    context: ReactApplicationContext,
    imageSource: String,
    sourceImageIndex: Int,
    allowedFormats: Set<String>
  ): List<BarcodeResult> {
    var detectedResults: List<BarcodeResult> = emptyList()
    val extractionLatch = CountDownLatch(1)

    barcodeExtractor.extractFromSource(
      context = context,
      imageSource = imageSource,
      sourceImageIndex = sourceImageIndex,
      allowedFormats = allowedFormats
    ) { detected ->
      detectedResults = detected
      extractionLatch.countDown()
    }

    try {
      extractionLatch.await(20, TimeUnit.SECONDS)
    } catch (_: InterruptedException) {
      Thread.currentThread().interrupt()
    }

    return detectedResults
  }

  private fun parseAllowedFormats(rawFormats: ReadableArray?): Set<String> {
    if (rawFormats == null || rawFormats.size() == 0) {
      return emptySet()
    }

    val values = mutableListOf<String>()
    for (index in 0 until rawFormats.size()) {
      val value = readStringAt(rawFormats, index)
      if (!value.isNullOrBlank()) {
        values.add(value)
      }
    }

    return BarcodeFormats.normalizeRequestedFormats(values)
  }

  private fun readStringAt(array: ReadableArray, index: Int): String? {
    return try {
      if (array.isNull(index)) null else array.getString(index)
    } catch (_: Exception) {
      null
    }
  }

  private fun getArrayOrNull(map: ReadableMap, key: String): ReadableArray? {
    return try {
      if (!map.hasKey(key) || map.isNull(key)) {
        null
      } else {
        map.getArray(key)
      }
    } catch (_: Exception) {
      null
    }
  }

  private fun getIntOrNull(map: ReadableMap, key: String): Int? {
    return try {
      if (!map.hasKey(key) || map.isNull(key)) {
        null
      } else {
        map.getInt(key)
      }
    } catch (_: Exception) {
      null
    }
  }

  private fun startScan(activity: Activity) {
    val currentScanner = scanner
    if (currentScanner == null) {
      pendingPromise?.reject("scanner_init_error", "Scanner not initialized")
      clearPending()
      return
    }

    currentScanner.getStartScanIntent(activity)
      .addOnSuccessListener { intentSender ->
        launcher?.launch(IntentSenderRequest.Builder(intentSender).build())
          ?: run {
            pendingPromise?.reject("launcher_error", "Launcher not available")
            clearPending()
          }
      }
      .addOnFailureListener { e ->
        pendingPromise?.reject("document_scan_error", e.message)
        clearPending()
      }
  }

  @Throws(FileNotFoundException::class)
  private fun uriToBase64(activity: Activity, uri: Uri, quality: Int): String {
    val bmp = activity.contentResolver.openInputStream(uri).use { input ->
      BitmapFactory.decodeStream(input)
    } ?: throw FileNotFoundException("Unable to decode scanned image")

    val baos = ByteArrayOutputStream()
    bmp.compress(Bitmap.CompressFormat.JPEG, quality, baos)
    return Base64.encodeToString(baos.toByteArray(), Base64.DEFAULT)
  }

  private fun clearPending() {
    pendingPromise = null
    pendingOptions = null
    pendingQuality = 100
    restoreSystemBars()
  }

  private fun ensureSystemBarsVisible(activity: ComponentActivity) {
    if (Build.VERSION.SDK_INT < ANDROID_15_API) return
    if (previousFitsSystemWindows != null) return

    val decor = activity.window.decorView
    @Suppress("DEPRECATION")
    val original = decor.fitsSystemWindows
    previousFitsSystemWindows = original
    WindowCompat.setDecorFitsSystemWindows(activity.window, true)
  }

  private fun restoreSystemBars() {
    if (Build.VERSION.SDK_INT < ANDROID_15_API) return
    val previous = previousFitsSystemWindows ?: return
    hostActivityRef?.get()?.let { activity ->
      WindowCompat.setDecorFitsSystemWindows(activity.window, previous)
    }
    previousFitsSystemWindows = null
    hostActivityRef = null
  }

  private fun canReadUri(activity: Activity, uri: Uri): Boolean {
    return try {
      activity.contentResolver.openFileDescriptor(uri, "r")?.use { }
      true
    } catch (_: FileNotFoundException) {
      false
    } catch (_: SecurityException) {
      false
    } catch (_: IllegalArgumentException) {
      false
    }
  }
}
