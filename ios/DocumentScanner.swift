import Foundation
import UIKit
import React

@objc(DocumentScannerImpl)
public class DocumentScannerImpl: NSObject {
  private var docScanner: DocScanner?

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

    DispatchQueue.main.async {
      self.docScanner = DocScanner()
      self.docScanner?.startScan(
        RCTPresentedViewController(),
        successHandler: { images in
          let sanitized = images.compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
          }
          resolve([
            "status": "success",
            "scannedImages": sanitized
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
}