import Foundation
import UIKit
import React

@objc(DocumentScannerImpl)
public class DocumentScannerImpl: NSObject {
  private var docScanner: DocScanner?
  private let barcodeQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.preeternal.document-scanner.barcode"
    queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .utility
    return queue
  }()

  @objc static func requiresMainQueueSetup() -> Bool { true }

  @objc(scanDocument:resolve:reject:)
  public func scanDocument(
    _ options: NSDictionary,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    guard #available(iOS 13.0, *) else {
      reject("unsupported_ios", "iOS 13.0 or higher required", nil)
      return
    }

    let opts = options as? [String: Any] ?? [:]
    let responseType = opts["responseType"] as? String
    let quality = opts["croppedImageQuality"] as? Int
    let isBase64Response = responseType?.lowercased() == "base64"

    DispatchQueue.main.async {
      self.docScanner = DocScanner()
      self.docScanner?.startScan(
        RCTPresentedViewController(),
        successHandler: { (scannedData: [[String: Any]]) in
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
                continue
              }
            }

            sanitizedImages.append(trimmed)
          }

          resolve([
            "status": "success",
            "scannedImages": sanitizedImages
          ])
          self.docScanner = nil
        },
        errorHandler: { msg in
          reject("document_scan_error", msg, nil)
          self.docScanner = nil
        },
        cancelHandler: {
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
    guard #available(iOS 13.0, *) else {
      reject("unsupported_ios", "iOS 13.0 or higher required", nil)
      return
    }

    let opts = options as? [String: Any] ?? [:]
    let rawImages = opts["images"] as? [Any] ?? []
    let allowedFormats = (opts["barcodeFormats"] as? [Any] ?? [])
      .compactMap { $0 as? String }

    let requestedConcurrency = opts["concurrency"] as? Int ?? 2
    let concurrency = max(1, min(2, requestedConcurrency))

    if rawImages.isEmpty {
      resolve([])
      return
    }

    let requestLimiter = DispatchSemaphore(value: concurrency)
    let lock = NSLock()
    let group = DispatchGroup()
    var extractedBarcodes: [[String: Any]] = []

    for (sourceImageIndex, source) in rawImages.enumerated() {
      guard let imageSource = source as? String,
            !imageSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue
      }

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

        guard let image = BarcodeImageSource.loadImage(from: imageSource) else {
          return
        }

        let detected = BarcodeExtractor.extractFromImage(
          image,
          allowedFormats: allowedFormats
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
            "sourceImageIndex": sourceImageIndex
          ]
        }

        guard !mapped.isEmpty else {
          return
        }

        lock.lock()
        extractedBarcodes.append(contentsOf: mapped)
        lock.unlock()
      }
      barcodeQueue.addOperation(operation)
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

      resolve(sorted)
    }
  }

  @objc
  public func invalidate() {
    docScanner = nil
    barcodeQueue.cancelAllOperations()
  }
}
