import Foundation
import UIKit
import React

@objc(DocumentScannerImpl)
public class DocumentScannerImpl: NSObject {
  private var docScanner: DocScanner?
  private let analysisQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.preeternal.document-scanner.analysis"
    queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .utility
    return queue
  }()

  private enum AnalysisStageStatus {
    case success
    case notEnabled
    case failed
    case skipped
  }

  private struct IndexedImageSource {
    let sourceImageIndex: Int
    let imageSource: String
  }

  private func log(_ scope: String, _ message: @autoclosure () -> String) {
    DocScannerDebugLog.log(scope, message())
  }

  @objc static func requiresMainQueueSetup() -> Bool { true }

  @objc(scanDocument:resolve:reject:)
  public func scanDocument(
    _ options: NSDictionary,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    log("scanDocument", "invoked")
    guard #available(iOS 13.0, *) else {
      reject("unsupported_ios", "iOS 13.0 or higher required", nil)
      return
    }

    let opts = options as? [String: Any] ?? [:]
    let responseType = opts["responseType"] as? String
    let quality = opts["croppedImageQuality"] as? Int
    let isBase64Response = responseType?.lowercased() == "base64"
    log(
      "scanDocument",
      "responseType=\(responseType ?? "default") quality=\(quality ?? 100) base64=\(isBase64Response)"
    )

    DispatchQueue.main.async {
      self.docScanner = DocScanner()
      self.docScanner?.startScan(
        RCTPresentedViewController(),
        successHandler: { (scannedData: [[String: Any]]) in
          self.log("scanDocument", "native scanner returned pages=\(scannedData.count)")
          let fm = FileManager.default
          var sanitizedImages: [String] = []

          for item in scannedData {
            guard let rawImage = item["image"] as? String else { continue }
            let trimmed = rawImage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if !isBase64Response {
              let path: String
              if let url = URL(string: trimmed), url.isFileURL {
                path = url.path
              } else {
                path = trimmed
              }
              if !fm.fileExists(atPath: path) {
                self.log("scanDocument", "skip non-existing file path for scanned page")
                continue
              }
            }

            sanitizedImages.append(trimmed)
          }

          resolve([
            "status": "success",
            "scannedImages": sanitizedImages
          ])
          self.log("scanDocument", "resolved scannedImages=\(sanitizedImages.count)")
          self.docScanner = nil
        },
        errorHandler: { msg in
          self.log("scanDocument", "error=\(msg)")
          reject("document_scan_error", msg, nil)
          self.docScanner = nil
        },
        cancelHandler: {
          self.log("scanDocument", "cancelled")
          resolve([
            "status": "cancel",
            "scannedImages": []
          ])
          self.docScanner = nil
        },
        responseType: responseType,
        croppedImageQuality: quality
      )
    }
  }

  @objc(extractBarcodesFromImages:resolve:reject:)
  public func extractBarcodesFromImages(
    _ options: NSDictionary,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    log("extractBarcodesFromImages", "invoked")
    guard #available(iOS 13.0, *) else {
      reject("unsupported_ios", "iOS 13.0 or higher required", nil)
      return
    }

    let opts = options as? [String: Any] ?? [:]
    let rawImages = opts["images"] as? [Any] ?? []
    let sources = buildImageSources(rawImages)
    let allowedFormats = (opts["barcodeFormats"] as? [Any] ?? [])
      .compactMap { $0 as? String }

    let requestedConcurrency = opts["concurrency"] as? Int ?? 2
    let concurrency = max(1, min(2, requestedConcurrency))
    log(
      "extractBarcodesFromImages",
      "rawImages=\(rawImages.count) validSources=\(sources.count) concurrency=\(concurrency) allowedFormats=\(allowedFormats)"
    )

    if sources.isEmpty {
      log("extractBarcodesFromImages", "no valid sources, resolve []")
      resolve([])
      return
    }

    if #available(iOS 26.0, *) {
      let modernOptions = RecognizeDocumentsAnalyzer.Options(
        includeBarcodes: true,
        includeText: false,
        includeTables: false,
        includeRegions: false,
        includeStructuredData: false,
        allowedBarcodeFormats: allowedFormats
      )

      performModernAnalysis(
        sources: sources,
        options: modernOptions,
        concurrency: concurrency
      ) { analysis in
        let modernBarcodes = analysis.barcodes.map(self.toDictionary)
        self.log(
          "extractBarcodesFromImages",
          "modern analysis barcodes=\(modernBarcodes.count)"
        )
        if !modernBarcodes.isEmpty {
          self.log("extractBarcodesFromImages", "resolved with modern barcodes")
          resolve(modernBarcodes)
          return
        }

        // Fallback for non-document gallery assets where RecognizeDocuments may miss 1D barcodes.
        self.log("extractBarcodesFromImages", "modern empty, starting legacy fallback")
        self.performBarcodeExtraction(
          sources: sources,
          allowedFormats: allowedFormats,
          concurrency: concurrency
        ) { legacyBarcodes in
          self.log(
            "extractBarcodesFromImages",
            "legacy fallback barcodes=\(legacyBarcodes.count)"
          )
          resolve(legacyBarcodes)
        }
      }
      return
    }

    // TODO(preeternal): Remove this legacy barcode path when iOS 26+ becomes the practical baseline.
    log("extractBarcodesFromImages", "using legacy path (iOS < 26)")
    performBarcodeExtraction(
      sources: sources,
      allowedFormats: allowedFormats,
      concurrency: concurrency
    ) { extractedBarcodes in
      self.log(
        "extractBarcodesFromImages",
        "legacy path resolved barcodes=\(extractedBarcodes.count)"
      )
      resolve(extractedBarcodes)
    }
  }

  @objc(extractTextFromImages:resolve:reject:)
  public func extractTextFromImages(
    _ options: NSDictionary,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    log("extractTextFromImages", "invoked")
    guard #available(iOS 13.0, *) else {
      reject("unsupported_ios", "iOS 13.0 or higher required", nil)
      return
    }

    let opts = options as? [String: Any] ?? [:]
    let rawImages = opts["images"] as? [Any] ?? []
    let sources = buildImageSources(rawImages)
    let ocrRotate180Fallback = opts["ocrRotate180Fallback"] as? Bool ?? false
    let requestedConcurrency = opts["concurrency"] as? Int ?? 2
    let concurrency = max(1, min(2, requestedConcurrency))
    log(
      "extractTextFromImages",
      "rawImages=\(rawImages.count) validSources=\(sources.count) concurrency=\(concurrency) rotate180=\(ocrRotate180Fallback)"
    )

    if sources.isEmpty {
      log("extractTextFromImages", "no valid sources, resolve []")
      resolve([])
      return
    }

    if #available(iOS 26.0, *) {
      let modernOptions = RecognizeDocumentsAnalyzer.Options(
        includeBarcodes: false,
        includeText: true,
        includeTables: false,
        includeRegions: false,
        includeStructuredData: false,
        allowedBarcodeFormats: []
      )

      performModernAnalysis(
        sources: sources,
        options: modernOptions,
        concurrency: concurrency
      ) { analysis in
        self.log("extractTextFromImages", "modern textBlocks=\(analysis.textBlocks.count)")
        resolve(self.toDictionaryArray(analysis.textBlocks))
      }
      return
    }

    // TODO(preeternal): Remove this legacy OCR path when iOS 26+ becomes the practical baseline.
    performTextExtraction(
      sources: sources,
      ocrRotate180Fallback: ocrRotate180Fallback,
      concurrency: concurrency
    ) { textBlocks in
      self.log("extractTextFromImages", "legacy textBlocks=\(textBlocks.count)")
      resolve(self.toDictionaryArray(textBlocks))
    }
  }

  @objc(analyzeScannedImages:resolve:reject:)
  public func analyzeScannedImages(
    _ options: NSDictionary,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    log("analyzeScannedImages", "invoked")
    guard #available(iOS 13.0, *) else {
      reject("unsupported_ios", "iOS 13.0 or higher required", nil)
      return
    }

    let opts = options as? [String: Any] ?? [:]
    let rawImages = opts["images"] as? [Any] ?? []
    let sources = buildImageSources(rawImages)

    let wantsBarcodes = opts["extractBarcodes"] as? Bool ?? false
    let wantsText = opts["extractText"] as? Bool ?? false
    let wantsTables = opts["extractTables"] as? Bool ?? false
    let wantsRegions = opts["extractRegions"] as? Bool ?? false
    let wantsStructuredData = opts["extractStructuredData"] as? Bool ?? false
    let wantsTextPipeline = wantsText || wantsTables || wantsRegions || wantsStructuredData
    let ocrRotate180Fallback = opts["ocrRotate180Fallback"] as? Bool ?? true
    log(
      "analyzeScannedImages",
      "rawImages=\(rawImages.count) validSources=\(sources.count) extract(barcodes=\(wantsBarcodes), text=\(wantsText), tables=\(wantsTables), regions=\(wantsRegions), structured=\(wantsStructuredData)) rotate180=\(ocrRotate180Fallback)"
    )

    if sources.isEmpty || (!wantsBarcodes && !wantsTextPipeline) {
      log("analyzeScannedImages", "nothing to analyze, resolve success")
      resolve(["status": "success"])
      return
    }

    let requestedConcurrency = opts["concurrency"] as? Int ?? 2
    let concurrency = max(1, min(2, requestedConcurrency))
    let allowedFormats = (opts["barcodeFormats"] as? [Any] ?? [])
      .compactMap { $0 as? String }
    log(
      "analyzeScannedImages",
      "concurrency=\(concurrency) allowedFormats=\(allowedFormats)"
    )

    if #available(iOS 26.0, *) {
      let modernOptions = RecognizeDocumentsAnalyzer.Options(
        includeBarcodes: wantsBarcodes,
        includeText: wantsText,
        includeTables: wantsTables,
        includeRegions: wantsRegions,
        includeStructuredData: wantsStructuredData,
        allowedBarcodeFormats: allowedFormats
      )

      performModernAnalysis(
        sources: sources,
        options: modernOptions,
        concurrency: concurrency
      ) { analysis in
        self.log(
          "analyzeScannedImages",
          "modern result barcodes=\(analysis.barcodes.count) textBlocks=\(analysis.textBlocks.count) tables=\(analysis.tables.count) regions=\(analysis.regions.count)"
        )
        let finalize: ([[String: Any]]) -> Void = { barcodePayload in
          var response: [String: Any] = [
            "status": "success"
          ]

          if wantsBarcodes {
            response["barcodes"] = barcodePayload
          }

          if wantsText {
            let mappedText = self.toDictionaryArray(analysis.textBlocks)
            response["textBlocks"] = mappedText
            response["text"] = mappedText
          }

          if wantsTables {
            response["tables"] = analysis.tables.map(self.toDictionary)
          }

          if wantsRegions {
            response["regions"] = analysis.regions.map(self.toDictionary)
          }

          if wantsStructuredData {
            let mapped = self.toDictionary(analysis.structuredData)
            if mapped["entities"] != nil || mapped["fields"] != nil {
              response["structuredData"] = mapped
            }
          }

          resolve(response)
          self.log(
            "analyzeScannedImages",
            "resolved status=success barcodes=\(barcodePayload.count)"
          )
        }

        let modernBarcodes = analysis.barcodes.map(self.toDictionary)
        if wantsBarcodes && modernBarcodes.isEmpty {
          // Fallback for non-document gallery assets where RecognizeDocuments may miss 1D barcodes.
          self.log("analyzeScannedImages", "modern barcodes empty, starting legacy barcode fallback")
          self.performBarcodeExtraction(
            sources: sources,
            allowedFormats: allowedFormats,
            concurrency: concurrency
          ) { legacyBarcodes in
            self.log(
              "analyzeScannedImages",
              "legacy barcode fallback count=\(legacyBarcodes.count)"
            )
            finalize(legacyBarcodes)
          }
          return
        }

        finalize(modernBarcodes)
      }
      return
    }

    // TODO(preeternal): Remove this legacy mixed analysis fallback when iOS 26+ becomes the practical baseline.
    let group = DispatchGroup()
    var barcodeStage: AnalysisStageStatus = .skipped
    var textStage: AnalysisStageStatus = .skipped
    var barcodes: [[String: Any]] = []
    var textBlocks: [AnalysisTextBlock] = []

    if wantsBarcodes {
      barcodeStage = .failed
      group.enter()
      performBarcodeExtraction(
        sources: sources,
        allowedFormats: allowedFormats,
        concurrency: concurrency
      ) { extracted in
        barcodes = extracted
        barcodeStage = .success
        self.log(
          "analyzeScannedImages",
          "legacy barcode stage finished count=\(extracted.count)"
        )
        group.leave()
      }
    }

    if wantsTextPipeline {
      textStage = .failed
      group.enter()
      performTextExtraction(
        sources: sources,
        ocrRotate180Fallback: ocrRotate180Fallback,
        concurrency: concurrency
      ) { extracted in
        textBlocks = extracted
        textStage = .success
        self.log(
          "analyzeScannedImages",
          "legacy text stage finished count=\(extracted.count)"
        )
        group.leave()
      }
    }

    group.notify(queue: .main) {
      var response: [String: Any] = [
        "status": self.mergeStageStatuses([barcodeStage, textStage])
      ]

      if wantsBarcodes && barcodeStage == .success {
        response["barcodes"] = barcodes
      }

      if textStage == .success {
        if wantsText {
          let mappedText = self.toDictionaryArray(textBlocks)
          response["textBlocks"] = mappedText
          response["text"] = mappedText
        }

        if wantsTables {
          let tables = DocumentSemantics.inferTables(from: textBlocks)
          response["tables"] = tables.map(self.toDictionary)
        }

        if wantsRegions {
          let regions = DocumentSemantics.inferRegions(from: textBlocks)
          response["regions"] = regions.map(self.toDictionary)
        }

        if wantsStructuredData {
          let structured = DocumentSemantics.inferStructuredData(from: textBlocks)
          let mapped = self.toDictionary(structured)
          if mapped["entities"] != nil || mapped["fields"] != nil {
            response["structuredData"] = mapped
          }
        }
      }

      resolve(response)
      self.log(
        "analyzeScannedImages",
        "legacy resolved status=\(response["status"] as? String ?? "unknown") barcodes=\(barcodes.count) textBlocks=\(textBlocks.count)"
      )
    }
  }

  @objc
  public func invalidate() {
    log("lifecycle", "invalidate called, cancelling analysis queue")
    docScanner = nil
    analysisQueue.cancelAllOperations()
  }

  private func buildImageSources(_ rawImages: [Any]) -> [IndexedImageSource] {
    let mapped = rawImages.enumerated().compactMap { entry -> IndexedImageSource? in
      let (index, source) = entry
      guard let imageSource = source as? String else {
        self.log("sources", "skip source[\(index)] not a string")
        return nil
      }
      let normalized = imageSource.trimmingCharacters(in: .whitespacesAndNewlines)
      if normalized.isEmpty {
        self.log("sources", "skip source[\(index)] empty")
        return nil
      }
      return IndexedImageSource(sourceImageIndex: index, imageSource: normalized)
    }
    log("sources", "mapped valid sources=\(mapped.count) from raw=\(rawImages.count)")
    return mapped
  }

  @available(iOS 26.0, *)
  private struct ModernAnalysisResult {
    var barcodes: [AnalysisBarcode] = []
    var textBlocks: [AnalysisTextBlock] = []
    var tables: [AnalysisTable] = []
    var regions: [AnalysisRegion] = []
    var structuredData: AnalysisStructuredData = AnalysisStructuredData(entities: [], fields: [:])
  }

  @available(iOS 26.0, *)
  private func performModernAnalysis(
    sources: [IndexedImageSource],
    options: RecognizeDocumentsAnalyzer.Options,
    concurrency: Int,
    completion: @escaping (ModernAnalysisResult) -> Void
  ) {
    log(
      "performModernAnalysis",
      "start sources=\(sources.count) concurrency=\(concurrency) include(barcodes=\(options.includeBarcodes), text=\(options.includeText), tables=\(options.includeTables), regions=\(options.includeRegions), structured=\(options.includeStructuredData)) allowedFormats=\(options.allowedBarcodeFormats)"
    )
    if sources.isEmpty {
      DispatchQueue.main.async {
        completion(ModernAnalysisResult())
      }
      return
    }

    let requestLimiter = DispatchSemaphore(value: concurrency)
    let lock = NSLock()
    let group = DispatchGroup()
    var pages: [RecognizeDocumentsAnalyzer.PageAnalysis] = []

    for source in sources {
      let operation = BlockOperation()
      group.enter()
      operation.completionBlock = {
        group.leave()
      }
      operation.addExecutionBlock { [weak operation] in
        guard let operation = operation, !operation.isCancelled else {
          return
        }

        requestLimiter.wait()
        defer { requestLimiter.signal() }

        guard !operation.isCancelled else {
          return
        }

        guard let image = BarcodeImageSource.loadImage(from: source.imageSource) else {
          self.log("performModernAnalysis", "source[\(source.sourceImageIndex)] image load failed")
          return
        }
        self.log(
          "performModernAnalysis",
          "source[\(source.sourceImageIndex)] image loaded size=\(Int(image.size.width))x\(Int(image.size.height))"
        )

        let page = RecognizeDocumentsAnalyzer.analyzeImageBlocking(
          image,
          sourceImageIndex: source.sourceImageIndex,
          options: options
        )
        self.log(
          "performModernAnalysis",
          "source[\(source.sourceImageIndex)] page result barcodes=\(page.barcodes.count) textBlocks=\(page.textBlocks.count) tables=\(page.tables.count) regions=\(page.regions.count)"
        )

        lock.lock()
        pages.append(page)
        lock.unlock()
      }
      analysisQueue.addOperation(operation)
    }

    group.notify(queue: .main) {
      var merged = ModernAnalysisResult()
      var entities: [AnalysisStructuredEntity] = []
      var fields: [String: String] = [:]

      let sortedPages = pages.sorted { lhs, rhs in
        let lhsIndex = lhs.textBlocks.first?.sourceImageIndex ??
          lhs.tables.first?.sourceImageIndex ??
          lhs.barcodes.first?.sourceImageIndex ?? Int.max
        let rhsIndex = rhs.textBlocks.first?.sourceImageIndex ??
          rhs.tables.first?.sourceImageIndex ??
          rhs.barcodes.first?.sourceImageIndex ?? Int.max
        return lhsIndex < rhsIndex
      }

      for page in sortedPages {
        merged.barcodes.append(contentsOf: page.barcodes)
        merged.textBlocks.append(contentsOf: page.textBlocks)
        merged.tables.append(contentsOf: page.tables)
        merged.regions.append(contentsOf: page.regions)
        entities.append(contentsOf: page.structuredData.entities)
        for (key, value) in page.structuredData.fields {
          fields[key] = value
        }
      }

      merged.barcodes.sort { lhs, rhs in
        if lhs.sourceImageIndex != rhs.sourceImageIndex {
          return lhs.sourceImageIndex < rhs.sourceImageIndex
        }
        if lhs.value != rhs.value {
          return lhs.value < rhs.value
        }
        return lhs.format < rhs.format
      }

      merged.textBlocks.sort { lhs, rhs in
        if lhs.sourceImageIndex != rhs.sourceImageIndex {
          return lhs.sourceImageIndex < rhs.sourceImageIndex
        }
        let lhsTop = lhs.boundingBox?.top ?? .greatestFiniteMagnitude
        let rhsTop = rhs.boundingBox?.top ?? .greatestFiniteMagnitude
        if lhsTop != rhsTop {
          return lhsTop < rhsTop
        }
        let lhsLeft = lhs.boundingBox?.left ?? .greatestFiniteMagnitude
        let rhsLeft = rhs.boundingBox?.left ?? .greatestFiniteMagnitude
        if lhsLeft != rhsLeft {
          return lhsLeft < rhsLeft
        }
        return lhs.text < rhs.text
      }

      merged.tables.sort { lhs, rhs in
        lhs.sourceImageIndex < rhs.sourceImageIndex
      }
      merged.regions.sort { lhs, rhs in
        lhs.sourceImageIndex < rhs.sourceImageIndex
      }
      merged.structuredData = AnalysisStructuredData(
        entities: entities,
        fields: fields
      )
      self.log(
        "performModernAnalysis",
        "merged barcodes=\(merged.barcodes.count) textBlocks=\(merged.textBlocks.count) tables=\(merged.tables.count) regions=\(merged.regions.count)"
      )

      completion(merged)
    }
  }

  private func performBarcodeExtraction(
    sources: [IndexedImageSource],
    allowedFormats: [String],
    concurrency: Int,
    completion: @escaping ([[String: Any]]) -> Void
  ) {
    log(
      "performBarcodeExtraction",
      "start sources=\(sources.count) concurrency=\(concurrency) allowedFormats=\(allowedFormats)"
    )
    if sources.isEmpty {
      DispatchQueue.main.async {
        completion([])
      }
      return
    }

    let requestLimiter = DispatchSemaphore(value: concurrency)
    let lock = NSLock()
    let group = DispatchGroup()
    var extractedBarcodes: [[String: Any]] = []

    for source in sources {
      let operation = BlockOperation()
      group.enter()
      operation.completionBlock = {
        group.leave()
      }
      operation.addExecutionBlock { [weak operation] in
        guard let operation = operation, !operation.isCancelled else {
          return
        }

        requestLimiter.wait()
        defer { requestLimiter.signal() }

        guard !operation.isCancelled else {
          return
        }

        guard let image = BarcodeImageSource.loadImage(from: source.imageSource) else {
          self.log("performBarcodeExtraction", "source[\(source.sourceImageIndex)] image load failed")
          return
        }
        self.log(
          "performBarcodeExtraction",
          "source[\(source.sourceImageIndex)] image loaded size=\(Int(image.size.width))x\(Int(image.size.height))"
        )

        let detected = BarcodeExtractor.extractFromImage(
          image,
          allowedFormats: allowedFormats
        )
        self.log(
          "performBarcodeExtraction",
          "source[\(source.sourceImageIndex)] raw detected=\(detected.count)"
        )

        guard !detected.isEmpty else {
          return
        }

        let mapped = detected.compactMap { barcode -> [String: Any]? in
          let value = barcode.value.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !value.isEmpty else {
            return nil
          }

          return [
            "value": value,
            "format": barcode.format,
            "sourceImageIndex": source.sourceImageIndex
          ]
        }

        guard !mapped.isEmpty else {
          self.log(
            "performBarcodeExtraction",
            "source[\(source.sourceImageIndex)] mapped empty after sanitization"
          )
          return
        }

        lock.lock()
        extractedBarcodes.append(contentsOf: mapped)
        lock.unlock()
      }
      analysisQueue.addOperation(operation)
    }

    group.notify(queue: .main) {
      let sorted = extractedBarcodes.sorted { lhs, rhs in
        let lhsIndex = lhs["sourceImageIndex"] as? Int ?? Int.max
        let rhsIndex = rhs["sourceImageIndex"] as? Int ?? Int.max

        if lhsIndex != rhsIndex {
          return lhsIndex < rhsIndex
        }

        let lhsValue = lhs["value"] as? String ?? ""
        let rhsValue = rhs["value"] as? String ?? ""
        return lhsValue < rhsValue
      }

      completion(sorted)
      self.log("performBarcodeExtraction", "completed total barcodes=\(sorted.count)")
    }
  }

  private func performTextExtraction(
    sources: [IndexedImageSource],
    ocrRotate180Fallback: Bool,
    concurrency: Int,
    completion: @escaping ([AnalysisTextBlock]) -> Void
  ) {
    log(
      "performTextExtraction",
      "start sources=\(sources.count) concurrency=\(concurrency) rotate180=\(ocrRotate180Fallback)"
    )
    if sources.isEmpty {
      DispatchQueue.main.async {
        completion([])
      }
      return
    }

    let requestLimiter = DispatchSemaphore(value: concurrency)
    let lock = NSLock()
    let group = DispatchGroup()
    var extractedTextBlocks: [AnalysisTextBlock] = []

    for source in sources {
      let operation = BlockOperation()
      group.enter()
      operation.completionBlock = {
        group.leave()
      }
      operation.addExecutionBlock { [weak operation] in
        guard let operation = operation, !operation.isCancelled else {
          return
        }

        requestLimiter.wait()
        defer { requestLimiter.signal() }

        guard !operation.isCancelled else {
          return
        }

        guard let image = BarcodeImageSource.loadImage(from: source.imageSource) else {
          self.log("performTextExtraction", "source[\(source.sourceImageIndex)] image load failed")
          return
        }

        let detected = TextExtractor.extractFromImage(
          image,
          sourceImageIndex: source.sourceImageIndex,
          enableRotate180Fallback: ocrRotate180Fallback
        )
        self.log(
          "performTextExtraction",
          "source[\(source.sourceImageIndex)] text blocks=\(detected.count)"
        )

        guard !detected.isEmpty else {
          return
        }

        lock.lock()
        extractedTextBlocks.append(contentsOf: detected)
        lock.unlock()
      }
      analysisQueue.addOperation(operation)
    }

    group.notify(queue: .main) {
      let sorted = extractedTextBlocks.sorted { lhs, rhs in
        if lhs.sourceImageIndex != rhs.sourceImageIndex {
          return lhs.sourceImageIndex < rhs.sourceImageIndex
        }

        let lhsTop = lhs.boundingBox?.top ?? .greatestFiniteMagnitude
        let rhsTop = rhs.boundingBox?.top ?? .greatestFiniteMagnitude
        if lhsTop != rhsTop {
          return lhsTop < rhsTop
        }

        let lhsLeft = lhs.boundingBox?.left ?? .greatestFiniteMagnitude
        let rhsLeft = rhs.boundingBox?.left ?? .greatestFiniteMagnitude
        if lhsLeft != rhsLeft {
          return lhsLeft < rhsLeft
        }

        return lhs.text < rhs.text
      }

      completion(sorted)
      self.log("performTextExtraction", "completed total textBlocks=\(sorted.count)")
    }
  }

  private func mergeStageStatuses(_ statuses: [AnalysisStageStatus]) -> String {
    let requested = statuses.filter { $0 != .skipped }
    if requested.isEmpty {
      return "success"
    }
    if requested.allSatisfy({ $0 == .success }) {
      return "success"
    }
    if requested.allSatisfy({ $0 == .notEnabled }) {
      return "not_enabled"
    }
    if requested.contains(.success) {
      return "partial"
    }
    return "failed"
  }

  private func toDictionaryArray(_ textBlocks: [AnalysisTextBlock]) -> [[String: Any]] {
    return textBlocks.map(toDictionary)
  }

  private func toDictionary(_ barcode: AnalysisBarcode) -> [String: Any] {
    var map: [String: Any] = [
      "value": barcode.value,
      "format": barcode.format,
      "sourceImageIndex": barcode.sourceImageIndex
    ]

    if let boundingBox = barcode.boundingBox {
      map["bbox"] = toDictionary(boundingBox)
    }

    return map
  }

  private func toDictionary(_ textBlock: AnalysisTextBlock) -> [String: Any] {
    var map: [String: Any] = [
      "text": textBlock.text,
      "sourceImageIndex": textBlock.sourceImageIndex,
      "lines": textBlock.lines.map(toDictionary)
    ]

    if let boundingBox = textBlock.boundingBox {
      map["bbox"] = toDictionary(boundingBox)
    }
    if let confidence = textBlock.confidence {
      map["confidence"] = confidence
    }

    return map
  }

  private func toDictionary(_ textLine: AnalysisTextLine) -> [String: Any] {
    var map: [String: Any] = [
      "text": textLine.text
    ]

    if let boundingBox = textLine.boundingBox {
      map["bbox"] = toDictionary(boundingBox)
    }
    if let confidence = textLine.confidence {
      map["confidence"] = confidence
    }

    return map
  }

  private func toDictionary(_ region: AnalysisRegion) -> [String: Any] {
    var map: [String: Any] = [
      "type": region.type,
      "sourceImageIndex": region.sourceImageIndex,
      "bbox": toDictionary(region.boundingBox)
    ]

    if let score = region.score {
      map["score"] = score
    }
    if let text = region.text, !text.isEmpty {
      map["text"] = text
    }

    return map
  }

  private func toDictionary(_ table: AnalysisTable) -> [String: Any] {
    var map: [String: Any] = [
      "sourceImageIndex": table.sourceImageIndex,
      "rows": table.rows,
      "cells": table.cells.map(toDictionary)
    ]

    if let boundingBox = table.boundingBox {
      map["bbox"] = toDictionary(boundingBox)
    }

    return map
  }

  private func toDictionary(_ cell: AnalysisTableCell) -> [String: Any] {
    var map: [String: Any] = [
      "text": cell.text,
      "row": cell.row,
      "column": cell.column,
      "sourceImageIndex": cell.sourceImageIndex
    ]

    if let boundingBox = cell.boundingBox {
      map["bbox"] = toDictionary(boundingBox)
    }

    return map
  }

  private func toDictionary(_ structuredData: AnalysisStructuredData) -> [String: Any] {
    var map: [String: Any] = [:]

    if !structuredData.entities.isEmpty {
      let sortedEntities = structuredData.entities.sorted { lhs, rhs in
        if lhs.sourceImageIndex != rhs.sourceImageIndex {
          return lhs.sourceImageIndex < rhs.sourceImageIndex
        }
        if lhs.type != rhs.type {
          return lhs.type < rhs.type
        }
        return lhs.value < rhs.value
      }
      map["entities"] = sortedEntities.map(toDictionary)
    }
    if !structuredData.fields.isEmpty {
      let fields = structuredData.fields.keys.sorted().map { key in
        [
          "key": key,
          "value": structuredData.fields[key] ?? ""
        ]
      }
      map["fields"] = fields
    }

    return map
  }

  private func toDictionary(_ entity: AnalysisStructuredEntity) -> [String: Any] {
    var map: [String: Any] = [
      "type": entity.type,
      "value": entity.value,
      "sourceImageIndex": entity.sourceImageIndex
    ]

    if let boundingBox = entity.boundingBox {
      map["bbox"] = toDictionary(boundingBox)
    }
    if let confidence = entity.confidence {
      map["confidence"] = confidence
    }

    return map
  }

  private func toDictionary(_ boundingBox: AnalysisBoundingBox) -> [String: Any] {
    return [
      "left": boundingBox.left,
      "top": boundingBox.top,
      "width": boundingBox.width,
      "height": boundingBox.height
    ]
  }
}
