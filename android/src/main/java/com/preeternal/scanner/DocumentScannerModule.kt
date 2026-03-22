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
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

@ReactModule(name = DocumentScannerModule.NAME)
class DocumentScannerModule(reactContext: ReactApplicationContext) :
  NativeDocumentScannerSpec(reactContext) {

  companion object {
    const val NAME = "DocumentScanner"
    private const val ANDROID_15_API = 35
    private const val BARCODE_EXTRACTION_TIMEOUT_MS = 20_000L
  }

  override fun getName(): String = NAME

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
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
        "Barcode extraction feature is disabled. Enable -PDocumentScanner_analysisFeatures=barcode to build with barcode support."
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
    val validSources = buildValidImageSources(images)

    if (validSources.isEmpty()) {
      promise.resolve(WritableNativeArray())
      return
    }

    scope.launch {
      try {
        val extracted = extractBarcodesInParallel(
          context = reactApplicationContext,
          sources = validSources,
          allowedFormats = allowedFormats,
          concurrency = concurrency
        )

        val payload = toWritableBarcodeArray(extracted)
        resolveOnUi(promise, payload)
      } catch (cancelled: CancellationException) {
        rejectOnUi(promise, "barcode_extraction_cancelled", "Barcode extraction cancelled", cancelled)
      } catch (error: Exception) {
        rejectOnUi(promise, "barcode_extraction_error", error.message ?: "Barcode extraction failed", error)
      }
    }
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

  private fun buildValidImageSources(images: ReadableArray): List<IndexedImageSource> {
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
    return validSources
  }

  private suspend fun extractBarcodesInParallel(
    context: ReactApplicationContext,
    sources: List<IndexedImageSource>,
    allowedFormats: Set<String>,
    concurrency: Int
  ): List<BarcodeResult> = coroutineScope {
    val limiter = Semaphore(concurrency)

    val tasks = sources.map { source ->
      async {
        limiter.withPermit {
          extractBarcodesForSource(
            context = context,
            imageSource = source.imageSource,
            sourceImageIndex = source.sourceImageIndex,
            allowedFormats = allowedFormats
          )
        }
      }
    }

    tasks.awaitAll().flatten()
  }

  private suspend fun extractBarcodesForSource(
    context: ReactApplicationContext,
    imageSource: String,
    sourceImageIndex: Int,
    allowedFormats: Set<String>
  ): List<BarcodeResult> {
    return withTimeoutOrNull(BARCODE_EXTRACTION_TIMEOUT_MS) {
      suspendCancellableCoroutine { continuation ->
        barcodeExtractor.extractFromSource(
          context = context,
          imageSource = imageSource,
          sourceImageIndex = sourceImageIndex,
          allowedFormats = allowedFormats
        ) { detected ->
          if (continuation.isActive) {
            continuation.resume(detected)
          }
        }
      }
    } ?: emptyList()
  }

  private fun toWritableBarcodeArray(barcodes: List<BarcodeResult>): WritableNativeArray {
    val sorted = barcodes.sortedWith(
      compareBy<BarcodeResult>({ it.sourceImageIndex }, { it.value }, { it.format })
    )

    val payload = WritableNativeArray()
    for (barcode in sorted) {
      payload.pushMap(toWritableBarcode(barcode))
    }
    return payload
  }

  private fun resolveOnUi(promise: Promise, value: Any?) {
    reactApplicationContext.runOnUiQueueThread {
      promise.resolve(value)
    }
  }

  private fun rejectOnUi(promise: Promise, code: String, message: String, throwable: Throwable?) {
    reactApplicationContext.runOnUiQueueThread {
      promise.reject(code, message, throwable)
    }
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

  override fun invalidate() {
    super.invalidate()
    scope.cancel()
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
