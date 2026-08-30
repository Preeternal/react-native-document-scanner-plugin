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
import com.preeternal.scanner.analysis.DocumentSemantics
import com.preeternal.scanner.analysis.SemanticRegion
import com.preeternal.scanner.analysis.SemanticStructuredData
import com.preeternal.scanner.analysis.SemanticStructuredEntity
import com.preeternal.scanner.analysis.SemanticTable
import com.preeternal.scanner.analysis.SemanticTableCell
import com.preeternal.scanner.barcode.BarcodeExtractor
import com.preeternal.scanner.barcode.BarcodeExtractorImpl
import com.preeternal.scanner.barcode.BarcodeFormats
import com.preeternal.scanner.barcode.BarcodeResult
import com.preeternal.scanner.text.NormalizedBoundingBox
import com.preeternal.scanner.text.TextBlockResult
import com.preeternal.scanner.text.TextExtractor
import com.preeternal.scanner.text.TextExtractorImpl
import com.preeternal.scanner.text.TextLineResult
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
    const val NAME = NativeDocumentScannerSpec.NAME
    private const val ANDROID_15_API = 35
    private const val BARCODE_EXTRACTION_TIMEOUT_MS = 10_000L
    private const val TEXT_EXTRACTION_TIMEOUT_MS = 25_000L
    private const val MIN_EXTRACTION_TIMEOUT_MS = 1_000L
    private const val MAX_EXTRACTION_TIMEOUT_MS = 120_000L
  }

  override fun getName(): String = NAME

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val barcodeExtractor: BarcodeExtractor = BarcodeExtractorImpl()
  private val textExtractor: TextExtractor = TextExtractorImpl()

  private enum class AnalysisStageStatus {
    SUCCESS,
    NOT_ENABLED,
    FAILED,
    SKIPPED
  }

  private data class AnalysisStageResult<T>(
    val status: AnalysisStageStatus,
    val value: T? = null
  )

  private var launcher: ActivityResultLauncher<IntentSenderRequest>? = null
  private val launcherInitLock = Any()
  private var pendingPromise: Promise? = null
  private var pendingOptions: ReadableMap? = null
  private var pendingQuality: Int = 100
  private var scanner: GmsDocumentScanner? = null

  private var hostActivityRef: WeakReference<ComponentActivity>? = null
  private var previousFitsSystemWindows: Boolean? = null

  private fun logDebug(message: String) {
    DocScannerDebugLog.debug(NAME, message)
  }

  private fun logWarn(message: String) {
    DocScannerDebugLog.warn(NAME, message)
  }

  override fun scanDocument(options: ReadableMap, promise: Promise) {
    logDebug("scanDocument invoked")
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
    logDebug(
      "scanDocument options responseType=${getStringOrNull(options, "responseType") ?: "default"} croppedImageQuality=$pendingQuality"
    )

    hostActivityRef = WeakReference(componentActivity)
    ensureSystemBarsVisible(componentActivity)

    initLauncher(componentActivity)
    initScanner(options)
    startScan(activity)
  }

  override fun extractBarcodesFromImages(options: ReadableMap, promise: Promise) {
    logDebug("extractBarcodesFromImages invoked")
    val images = getArrayOrNull(options, "images")
    if (images == null || images.size() == 0) {
      logDebug("extractBarcodesFromImages no images, resolve []")
      promise.resolve(WritableNativeArray())
      return
    }

    if (!barcodeExtractor.isFeatureEnabled()) {
      promise.reject(
        "barcode_not_enabled",
        "Barcode extraction feature is disabled. Enable -PDocumentScanner_analysisFeatures=barcode to build with barcode support."
      )
      return
    }

    val allowedFormats = parseAllowedFormats(getArrayOrNull(options, "barcodeFormats"))
    val requestedConcurrency = getIntOrNull(options, "concurrency") ?: 2
    val concurrency = requestedConcurrency.coerceIn(1, 2)
    val timeoutMs = resolveTimeoutMs(
      getIntOrNull(options, "barcodeTimeoutMs"),
      BARCODE_EXTRACTION_TIMEOUT_MS
    )
    val validSources = buildValidImageSources(images)
    logDebug(
      "extractBarcodesFromImages images=${images.size()} validSources=${validSources.size} concurrency=$concurrency timeoutMs=$timeoutMs allowedFormats=${allowedFormats.sorted()}"
    )

    if (validSources.isEmpty()) {
      logDebug("extractBarcodesFromImages no valid sources, resolve []")
      promise.resolve(WritableNativeArray())
      return
    }

    scope.launch {
      try {
        val extracted = extractBarcodesInParallel(
          context = reactApplicationContext,
          sources = validSources,
          allowedFormats = allowedFormats,
          concurrency = concurrency,
          timeoutMs = timeoutMs
        )

        val payload = toWritableBarcodeArray(extracted)
        logDebug("extractBarcodesFromImages resolved barcodes=${extracted.size}")
        resolveOnUi(promise, payload)
      } catch (cancelled: CancellationException) {
        logWarn("extractBarcodesFromImages cancelled: ${cancelled.message}")
        rejectOnUi(promise, "barcode_extraction_cancelled", "Barcode extraction cancelled", cancelled)
      } catch (error: Exception) {
        logWarn("extractBarcodesFromImages error: ${error.message}")
        rejectOnUi(promise, "barcode_extraction_error", error.message ?: "Barcode extraction failed", error)
      }
    }
  }

  override fun extractTextFromImages(options: ReadableMap, promise: Promise) {
    logDebug("extractTextFromImages invoked")
    val images = getArrayOrNull(options, "images")
    if (images == null || images.size() == 0) {
      logDebug("extractTextFromImages no images, resolve []")
      promise.resolve(WritableNativeArray())
      return
    }

    if (!textExtractor.isFeatureEnabled()) {
      promise.reject(
        "text_not_enabled",
        "Text extraction feature is disabled. Enable -PDocumentScanner_analysisFeatures=text (or tables) to build with OCR support."
      )
      return
    }

    val requestedConcurrency = getIntOrNull(options, "concurrency") ?: 2
    val concurrency = requestedConcurrency.coerceIn(1, 2)
    val ocrRotate180Fallback = getBooleanOrNull(options, "ocrRotate180Fallback") ?: false
    val timeoutMs = resolveTimeoutMs(
      getIntOrNull(options, "textTimeoutMs"),
      TEXT_EXTRACTION_TIMEOUT_MS
    )
    val validSources = buildValidImageSources(images)
    logDebug(
      "extractTextFromImages images=${images.size()} validSources=${validSources.size} concurrency=$concurrency timeoutMs=$timeoutMs rotate180=$ocrRotate180Fallback"
    )

    if (validSources.isEmpty()) {
      logDebug("extractTextFromImages no valid sources, resolve []")
      promise.resolve(WritableNativeArray())
      return
    }

    scope.launch {
      try {
        val extracted = extractTextInParallel(
          context = reactApplicationContext,
          sources = validSources,
          concurrency = concurrency,
          timeoutMs = timeoutMs,
          ocrRotate180Fallback = ocrRotate180Fallback
        )

        val payload = toWritableTextBlockArray(extracted)
        logDebug("extractTextFromImages resolved textBlocks=${extracted.size}")
        resolveOnUi(promise, payload)
      } catch (cancelled: CancellationException) {
        logWarn("extractTextFromImages cancelled: ${cancelled.message}")
        rejectOnUi(promise, "text_extraction_cancelled", "Text extraction cancelled", cancelled)
      } catch (error: Exception) {
        logWarn("extractTextFromImages error: ${error.message}")
        rejectOnUi(promise, "text_extraction_error", error.message ?: "Text extraction failed", error)
      }
    }
  }

  override fun analyzeScannedImages(options: ReadableMap, promise: Promise) {
    logDebug("analyzeScannedImages invoked")
    val images = getArrayOrNull(options, "images")
    if (images == null || images.size() == 0) {
      val empty = WritableNativeMap()
      empty.putString("status", "success")
      logDebug("analyzeScannedImages no images, resolve success")
      promise.resolve(empty)
      return
    }

    val wantsBarcodes = getBooleanOrNull(options, "extractBarcodes") ?: false
    val wantsText = getBooleanOrNull(options, "extractText") ?: false
    val wantsTables = getBooleanOrNull(options, "extractTables") ?: false
    val wantsRegions = getBooleanOrNull(options, "extractRegions") ?: false
    val wantsStructuredData = getBooleanOrNull(options, "extractStructuredData") ?: false
    val wantsTextPipeline = wantsText || wantsTables || wantsRegions || wantsStructuredData
    logDebug(
      "analyzeScannedImages flags barcodes=$wantsBarcodes text=$wantsText tables=$wantsTables regions=$wantsRegions structured=$wantsStructuredData"
    )

    if (!wantsBarcodes && !wantsTextPipeline) {
      val empty = WritableNativeMap()
      empty.putString("status", "success")
      logDebug("analyzeScannedImages nothing requested, resolve success")
      promise.resolve(empty)
      return
    }

    val allowedFormats = parseAllowedFormats(getArrayOrNull(options, "barcodeFormats"))
    val requestedConcurrency = getIntOrNull(options, "concurrency") ?: 2
    val concurrency = requestedConcurrency.coerceIn(1, 2)
    val ocrRotate180Fallback = getBooleanOrNull(options, "ocrRotate180Fallback") ?: true
    val barcodeTimeoutMs = resolveTimeoutMs(
      getIntOrNull(options, "barcodeTimeoutMs"),
      BARCODE_EXTRACTION_TIMEOUT_MS
    )
    val textTimeoutMs = resolveTimeoutMs(
      getIntOrNull(options, "textTimeoutMs"),
      TEXT_EXTRACTION_TIMEOUT_MS
    )
    val validSources = buildValidImageSources(images)
    logDebug(
      "analyzeScannedImages images=${images.size()} validSources=${validSources.size} concurrency=$concurrency barcodeTimeoutMs=$barcodeTimeoutMs textTimeoutMs=$textTimeoutMs rotate180=$ocrRotate180Fallback allowedFormats=${allowedFormats.sorted()}"
    )

    if (validSources.isEmpty()) {
      val empty = WritableNativeMap()
      empty.putString("status", "success")
      logDebug("analyzeScannedImages no valid sources, resolve success")
      promise.resolve(empty)
      return
    }

    scope.launch {
      try {
        val (barcodeStage, textStage) = coroutineScope {
          val barcodeDeferred = async {
            runBarcodeAnalysisStage(
              wantsStage = wantsBarcodes,
              sources = validSources,
              allowedFormats = allowedFormats,
              concurrency = concurrency,
              timeoutMs = barcodeTimeoutMs
            )
          }

          val textDeferred = async {
            runTextAnalysisStage(
              wantsStage = wantsTextPipeline,
              sources = validSources,
              concurrency = concurrency,
              timeoutMs = textTimeoutMs,
              ocrRotate180Fallback = ocrRotate180Fallback
            )
          }

          Pair(barcodeDeferred.await(), textDeferred.await())
        }

        val result = WritableNativeMap()
        result.putString(
          "status",
          mergeAnalysisStageStatuses(listOf(barcodeStage.status, textStage.status))
        )
        logDebug(
          "analyzeScannedImages stage status barcode=${barcodeStage.status} text=${textStage.status}"
        )

        if (barcodeStage.status == AnalysisStageStatus.SUCCESS) {
          result.putArray("barcodes", toWritableBarcodeArray(barcodeStage.value ?: emptyList()))
        }

        val textBlocks = if (textStage.status == AnalysisStageStatus.SUCCESS) {
          textStage.value ?: emptyList()
        } else {
          emptyList()
        }

        if (textStage.status == AnalysisStageStatus.SUCCESS && wantsText) {
          result.putArray("textBlocks", toWritableTextBlockArray(textBlocks))
          result.putArray("text", toWritableTextBlockArray(textBlocks))
        }

        if (textStage.status == AnalysisStageStatus.SUCCESS && wantsTables) {
          result.putArray(
            "tables",
            toWritableTableArray(DocumentSemantics.inferTables(textBlocks))
          )
        }

        if (textStage.status == AnalysisStageStatus.SUCCESS && wantsRegions) {
          result.putArray(
            "regions",
            toWritableRegionArray(DocumentSemantics.inferRegions(textBlocks))
          )
        }

        if (textStage.status == AnalysisStageStatus.SUCCESS && wantsStructuredData) {
          val structured = DocumentSemantics.inferStructuredData(textBlocks)
          val mapped = toWritableStructuredData(structured)
          if (mapped != null) {
            result.putMap("structuredData", mapped)
          }
        }

        resolveOnUi(promise, result)
        logDebug(
          "analyzeScannedImages resolved status=${result.getString("status")} barcodes=${if (barcodeStage.status == AnalysisStageStatus.SUCCESS) (barcodeStage.value ?: emptyList()).size else 0} textBlocks=${textBlocks.size}"
        )
      } catch (cancelled: CancellationException) {
        logWarn("analyzeScannedImages cancelled: ${cancelled.message}")
        rejectOnUi(promise, "analysis_cancelled", "Image analysis cancelled", cancelled)
      } catch (error: Exception) {
        logWarn("analyzeScannedImages error: ${error.message}")
        rejectOnUi(promise, "analysis_error", error.message ?: "Image analysis failed", error)
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
    synchronized(launcherInitLock) {
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
    var currentIndex = pageIndex
    while (currentIndex < pages.size) {
      val uri = pages[currentIndex].imageUri
      val outputImage = try {
        mapOutputImage(activity, uri, responseType)
      } catch (e: FileNotFoundException) {
        onError(e.message ?: "Unable to read scanned image")
        return
      }

      if (!outputImage.isNullOrBlank()) {
        images.pushString(outputImage)
      }
      currentIndex += 1
    }

    onComplete()
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

  private fun toWritableTextLine(line: TextLineResult): WritableNativeMap {
    val map = WritableNativeMap()
    map.putString("text", line.text)
    val bbox = toWritableBoundingBox(line.boundingBox)
    if (bbox != null) {
      map.putMap("bbox", bbox)
    }
    return map
  }

  private fun toWritableTextBlock(block: TextBlockResult): WritableNativeMap {
    val map = WritableNativeMap()
    map.putString("text", block.text)
    map.putInt("sourceImageIndex", block.sourceImageIndex)

    val bbox = toWritableBoundingBox(block.boundingBox)
    if (bbox != null) {
      map.putMap("bbox", bbox)
    }

    val lines = WritableNativeArray()
    for (line in block.lines) {
      lines.pushMap(toWritableTextLine(line))
    }
    map.putArray("lines", lines)

    return map
  }

  private fun toWritableBoundingBox(
    boundingBox: NormalizedBoundingBox?
  ): WritableNativeMap? {
    if (boundingBox == null) {
      return null
    }

    val map = WritableNativeMap()
    map.putDouble("left", boundingBox.left)
    map.putDouble("top", boundingBox.top)
    map.putDouble("width", boundingBox.width)
    map.putDouble("height", boundingBox.height)
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
      } else {
        logDebug("buildValidImageSources skip source[$index] empty or invalid")
      }
    }
    logDebug("buildValidImageSources mapped=${validSources.size} from raw=${images.size()}")
    return validSources
  }

  private suspend fun extractBarcodesInParallel(
    context: ReactApplicationContext,
    sources: List<IndexedImageSource>,
    allowedFormats: Set<String>,
    concurrency: Int,
    timeoutMs: Long
  ): List<BarcodeResult> = coroutineScope {
    logDebug(
      "extractBarcodesInParallel start sources=${sources.size} concurrency=$concurrency allowedFormats=${allowedFormats.sorted()}"
    )
    val limiter = Semaphore(concurrency)

    val tasks = sources.map { source ->
      async {
        limiter.withPermit {
          extractBarcodesForSource(
            context = context,
            imageSource = source.imageSource,
            sourceImageIndex = source.sourceImageIndex,
            allowedFormats = allowedFormats,
            timeoutMs = timeoutMs
          )
        }
      }
    }

    val merged = tasks.awaitAll().flatten()
    logDebug("extractBarcodesInParallel completed total=${merged.size}")
    merged
  }

  private suspend fun extractBarcodesForSource(
    context: ReactApplicationContext,
    imageSource: String,
    sourceImageIndex: Int,
    allowedFormats: Set<String>,
    timeoutMs: Long
  ): List<BarcodeResult> {
    logDebug(
      "extractBarcodesForSource start index=$sourceImageIndex sourceLength=${imageSource.length} allowedFormats=${allowedFormats.sorted()}"
    )
    val detected = withTimeoutOrNull(timeoutMs) {
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
    }

    if (detected == null) {
      logWarn(
        "Barcode extraction timed out after ${timeoutMs}ms for sourceImageIndex=$sourceImageIndex"
      )
      return emptyList()
    }

    logDebug("extractBarcodesForSource completed index=$sourceImageIndex detected=${detected.size}")
    return detected
  }

  private suspend fun extractTextInParallel(
    context: ReactApplicationContext,
    sources: List<IndexedImageSource>,
    concurrency: Int,
    timeoutMs: Long,
    ocrRotate180Fallback: Boolean
  ): List<TextBlockResult> = coroutineScope {
    logDebug(
      "extractTextInParallel start sources=${sources.size} concurrency=$concurrency rotate180=$ocrRotate180Fallback"
    )
    val limiter = Semaphore(concurrency)

    val tasks = sources.map { source ->
      async {
        limiter.withPermit {
          extractTextForSource(
            context = context,
            imageSource = source.imageSource,
            sourceImageIndex = source.sourceImageIndex,
            timeoutMs = timeoutMs,
            ocrRotate180Fallback = ocrRotate180Fallback
          )
        }
      }
    }

    val merged = tasks.awaitAll().flatten()
    logDebug("extractTextInParallel completed total=${merged.size}")
    merged
  }

  private suspend fun extractTextForSource(
    context: ReactApplicationContext,
    imageSource: String,
    sourceImageIndex: Int,
    timeoutMs: Long,
    ocrRotate180Fallback: Boolean
  ): List<TextBlockResult> {
    logDebug(
      "extractTextForSource start index=$sourceImageIndex sourceLength=${imageSource.length} rotate180=$ocrRotate180Fallback"
    )
    val detected = withTimeoutOrNull(timeoutMs) {
      suspendCancellableCoroutine { continuation ->
        textExtractor.extractFromSource(
          context = context,
          imageSource = imageSource,
          sourceImageIndex = sourceImageIndex,
          enableRotate180Fallback = ocrRotate180Fallback
        ) { extracted ->
          if (continuation.isActive) {
            continuation.resume(extracted)
          }
        }
      }
    }

    if (detected == null) {
      logWarn(
        "Text extraction timed out after ${timeoutMs}ms for sourceImageIndex=$sourceImageIndex"
      )
      return emptyList()
    }

    logDebug("extractTextForSource completed index=$sourceImageIndex detected=${detected.size}")
    return detected
  }

  private suspend fun runBarcodeAnalysisStage(
    wantsStage: Boolean,
    sources: List<IndexedImageSource>,
    allowedFormats: Set<String>,
    concurrency: Int,
    timeoutMs: Long
  ): AnalysisStageResult<List<BarcodeResult>> {
    if (!wantsStage) {
      logDebug("runBarcodeAnalysisStage skipped")
      return AnalysisStageResult(AnalysisStageStatus.SKIPPED)
    }
    if (!barcodeExtractor.isFeatureEnabled()) {
      logDebug("runBarcodeAnalysisStage not enabled")
      return AnalysisStageResult(AnalysisStageStatus.NOT_ENABLED)
    }

    return try {
      val value = extractBarcodesInParallel(
        context = reactApplicationContext,
        sources = sources,
        allowedFormats = allowedFormats,
        concurrency = concurrency,
        timeoutMs = timeoutMs
      )
      AnalysisStageResult(
        status = AnalysisStageStatus.SUCCESS,
        value = value
      )
    } catch (error: Exception) {
      logWarn("runBarcodeAnalysisStage failed: ${error.message}")
      AnalysisStageResult(AnalysisStageStatus.FAILED)
    }
  }

  private suspend fun runTextAnalysisStage(
    wantsStage: Boolean,
    sources: List<IndexedImageSource>,
    concurrency: Int,
    timeoutMs: Long,
    ocrRotate180Fallback: Boolean
  ): AnalysisStageResult<List<TextBlockResult>> {
    if (!wantsStage) {
      logDebug("runTextAnalysisStage skipped")
      return AnalysisStageResult(AnalysisStageStatus.SKIPPED)
    }
    if (!textExtractor.isFeatureEnabled()) {
      logDebug("runTextAnalysisStage not enabled")
      return AnalysisStageResult(AnalysisStageStatus.NOT_ENABLED)
    }

    return try {
      val value = extractTextInParallel(
        context = reactApplicationContext,
        sources = sources,
        concurrency = concurrency,
        timeoutMs = timeoutMs,
        ocrRotate180Fallback = ocrRotate180Fallback
      )
      AnalysisStageResult(
        status = AnalysisStageStatus.SUCCESS,
        value = value
      )
    } catch (error: Exception) {
      logWarn("runTextAnalysisStage failed: ${error.message}")
      AnalysisStageResult(AnalysisStageStatus.FAILED)
    }
  }

  private fun mergeAnalysisStageStatuses(statuses: List<AnalysisStageStatus>): String {
    val requested = statuses.filter { it != AnalysisStageStatus.SKIPPED }
    if (requested.isEmpty()) {
      return "success"
    }
    if (requested.all { it == AnalysisStageStatus.SUCCESS }) {
      return "success"
    }
    if (requested.all { it == AnalysisStageStatus.NOT_ENABLED }) {
      return "not_enabled"
    }
    if (requested.any { it == AnalysisStageStatus.SUCCESS }) {
      return "partial"
    }
    return "failed"
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

  private fun toWritableRegion(region: SemanticRegion): WritableNativeMap {
    val map = WritableNativeMap()
    map.putString("type", region.type)
    map.putInt("sourceImageIndex", region.sourceImageIndex)
    map.putMap("bbox", toWritableBoundingBox(region.boundingBox))
    region.score?.let { map.putDouble("score", it) }
    region.text?.let { map.putString("text", it) }
    return map
  }

  private fun toWritableRegionArray(regions: List<SemanticRegion>): WritableNativeArray {
    val payload = WritableNativeArray()
    for (region in regions.sortedBy { it.sourceImageIndex }) {
      payload.pushMap(toWritableRegion(region))
    }
    return payload
  }

  private fun toWritableTableCell(cell: SemanticTableCell): WritableNativeMap {
    val map = WritableNativeMap()
    map.putString("text", cell.text)
    map.putInt("row", cell.row)
    map.putInt("column", cell.column)
    map.putInt("sourceImageIndex", cell.sourceImageIndex)
    val bbox = toWritableBoundingBox(cell.boundingBox)
    if (bbox != null) {
      map.putMap("bbox", bbox)
    }
    return map
  }

  private fun toWritableTable(table: SemanticTable): WritableNativeMap {
    val map = WritableNativeMap()
    map.putInt("sourceImageIndex", table.sourceImageIndex)

    val rows = WritableNativeArray()
    for (row in table.rows) {
      val rowArray = WritableNativeArray()
      for (cell in row) {
        rowArray.pushString(cell)
      }
      rows.pushArray(rowArray)
    }
    map.putArray("rows", rows)

    val cells = WritableNativeArray()
    for (cell in table.cells) {
      cells.pushMap(toWritableTableCell(cell))
    }
    map.putArray("cells", cells)

    val bbox = toWritableBoundingBox(table.boundingBox)
    if (bbox != null) {
      map.putMap("bbox", bbox)
    }

    return map
  }

  private fun toWritableTableArray(tables: List<SemanticTable>): WritableNativeArray {
    val payload = WritableNativeArray()
    for (table in tables.sortedBy { it.sourceImageIndex }) {
      payload.pushMap(toWritableTable(table))
    }
    return payload
  }

  private fun toWritableStructuredEntity(entity: SemanticStructuredEntity): WritableNativeMap {
    val map = WritableNativeMap()
    map.putString("type", entity.type)
    map.putString("value", entity.value)
    map.putInt("sourceImageIndex", entity.sourceImageIndex)

    val bbox = toWritableBoundingBox(entity.boundingBox)
    if (bbox != null) {
      map.putMap("bbox", bbox)
    }
    entity.confidence?.let { map.putDouble("confidence", it) }

    return map
  }

  private fun toWritableStructuredData(data: SemanticStructuredData): WritableNativeMap? {
    if (data.entities.isEmpty() && data.fields.isEmpty()) {
      return null
    }

    val map = WritableNativeMap()

    if (data.entities.isNotEmpty()) {
      val entities = WritableNativeArray()
      val sortedEntities = data.entities.sortedWith(
        compareBy<SemanticStructuredEntity>(
          { it.sourceImageIndex },
          { it.type },
          { it.value }
        )
      )
      for (entity in sortedEntities) {
        entities.pushMap(toWritableStructuredEntity(entity))
      }
      map.putArray("entities", entities)
    }

    if (data.fields.isNotEmpty()) {
      val fields = WritableNativeArray()
      for ((key, value) in data.fields.toSortedMap()) {
        val entry = WritableNativeMap()
        entry.putString("key", key)
        entry.putString("value", value)
        fields.pushMap(entry)
      }
      map.putArray("fields", fields)
    }

    return map
  }

  private fun toWritableTextBlockArray(blocks: List<TextBlockResult>): WritableNativeArray {
    val sorted = blocks.sortedWith(
      compareBy<TextBlockResult>(
        { it.sourceImageIndex },
        { it.boundingBox?.top ?: Double.MAX_VALUE },
        { it.boundingBox?.left ?: Double.MAX_VALUE },
        { it.text }
      )
    )

    val payload = WritableNativeArray()
    for (block in sorted) {
      payload.pushMap(toWritableTextBlock(block))
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

  private fun resolveTimeoutMs(rawValue: Int?, fallback: Long): Long {
    val candidate = rawValue?.toLong() ?: fallback
    return candidate.coerceIn(MIN_EXTRACTION_TIMEOUT_MS, MAX_EXTRACTION_TIMEOUT_MS)
  }

  private fun getBooleanOrNull(map: ReadableMap, key: String): Boolean? {
    return try {
      if (!map.hasKey(key) || map.isNull(key)) {
        null
      } else {
        map.getBoolean(key)
      }
    } catch (_: Exception) {
      null
    }
  }

  private fun getStringOrNull(map: ReadableMap, key: String): String? {
    return try {
      if (!map.hasKey(key) || map.isNull(key)) {
        null
      } else {
        map.getString(key)
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
    launcher?.unregister()
    launcher = null
    scanner = null
    barcodeExtractor.release()
    clearPending()
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
