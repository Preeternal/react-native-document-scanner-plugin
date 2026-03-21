import Foundation
import UIKit
import React

@objc(DocumentScannerImpl)
public class DocumentScannerImpl: NSObject {
  private var docScanner: DocScanner?
  private let barcodeQueue = DispatchQueue(
    label: "com.preeternal.document-scanner.barcode",
    qos: .userInitiated
  )

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
    let shouldExtractBarcodes = opts["extractBarcodes"] as? Bool ?? false
    let barcodeFormats = (opts["barcodeFormats"] as? [Any] ?? [])
      .compactMap { $0 as? String }

    DispatchQueue.main.async {
      self.docScanner = DocScanner()
      self.docScanner?.startScan(
        RCTPresentedViewController(),
        successHandler: { (scannedData: [[String: Any]]) in
          let fm = FileManager.default
          var sanitizedImages: [String] = []
          var extractedBarcodes: [[String: Any]] = []

          // Keep the same sanitization guarantees as the original API.
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

            let sourceImageIndex = sanitizedImages.count
            sanitizedImages.append(trimmed)

            guard shouldExtractBarcodes && BarcodeFeatureFlags.isEnabled else {
              continue
            }

            guard let pageBarcodes = item["barcodes"] as? [[String: Any]] else {
              continue
            }

            // Flatten page-local barcodes into API-level barcodes with sourceImageIndex.
            for barcode in pageBarcodes {
              guard let value = barcode["value"] as? String,
                    !value.isEmpty else {
                continue
              }

              let format = (barcode["format"] as? String) ?? "unknown"
              extractedBarcodes.append([
                "value": value,
                "format": format,
                "sourceImageIndex": sourceImageIndex
              ])
            }
          }

          var payload: [String: Any] = [
            "status": "success",
            "scannedImages": sanitizedImages
          ]

          // Barcode payload is optional and only returned when explicitly requested.
          if shouldExtractBarcodes {
            if BarcodeFeatureFlags.isEnabled {
              payload["barcodes"] = extractedBarcodes
              payload["barcodeExtractionStatus"] = "success"
            } else {
              payload["barcodeExtractionStatus"] = "not_enabled"
            }
          }

          resolve(payload)
          self.docScanner = nil
        },
        errorHandler: { msg in
          reject("document_scan_error", msg, nil)
          self.docScanner = nil
        },
        cancelHandler: {
          var payload: [String: Any] = [
            "status": "cancel",
            "scannedImages": []
          ]
          if shouldExtractBarcodes && !BarcodeFeatureFlags.isEnabled {
            payload["barcodeExtractionStatus"] = "not_enabled"
          }
          resolve(payload)
          self.docScanner = nil
        },
        responseType: responseType,
        croppedImageQuality: quality,
        extractBarcodes: shouldExtractBarcodes,
        barcodeFormats: barcodeFormats
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

    guard BarcodeFeatureFlags.isEnabled else {
      reject(
        "barcode_not_enabled",
        "Barcode extraction feature is disabled. Enable DOCUMENT_SCANNER_ENABLE_BARCODE=1 before pod install.",
        nil
      )
      return
    }

    let opts = options as? [String: Any] ?? [:]
    let rawImages = opts["images"] as? [Any] ?? []
    let allowedFormats = (opts["barcodeFormats"] as? [Any] ?? [])
      .compactMap { $0 as? String }

    if rawImages.isEmpty {
      resolve([])
      return
    }

    barcodeQueue.async {
      #if DOCUMENT_SCANNER_ENABLE_BARCODE
      var extractedBarcodes: [[String: Any]] = []

      for (sourceImageIndex, source) in rawImages.enumerated() {
        guard let imageSource = source as? String else {
          continue
        }

        guard let image = BarcodeImageSource.loadImage(from: imageSource) else {
          continue
        }

        let detected = BarcodeExtractor.extractFromImage(
          image,
          allowedFormats: allowedFormats
        )

        for barcode in detected where !barcode.value.isEmpty {
          extractedBarcodes.append([
            "value": barcode.value,
            "format": barcode.format,
            "sourceImageIndex": sourceImageIndex
          ])
        }
      }

      DispatchQueue.main.async {
        resolve(extractedBarcodes)
      }
      #else
      DispatchQueue.main.async {
        reject(
          "barcode_not_enabled",
          "Barcode extraction feature is disabled. Enable DOCUMENT_SCANNER_ENABLE_BARCODE=1 before pod install.",
          nil
        )
      }
      #endif
    }
  }
}
