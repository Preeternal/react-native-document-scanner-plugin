import Foundation
import Photos
import UIKit

enum BarcodeImageSource {
  private static let photoKitRequestTimeoutSeconds: TimeInterval = 15

  static func loadImage(from imageSource: String) -> UIImage? {
    let normalized = imageSource.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
      DocScannerDebugLog.log("BarcodeImageSource", "empty source string")
      return nil
    }

    let scheme = URL(string: normalized)?.scheme?.lowercased() ?? "path-or-base64"
    DocScannerDebugLog.log(
      "BarcodeImageSource",
      "load start scheme=\(scheme) length=\(normalized.count)"
    )

    if let localFromUri = loadFromFileUri(normalized) {
      DocScannerDebugLog.log(
        "BarcodeImageSource",
        "loaded from file:// uri size=\(Int(localFromUri.size.width))x\(Int(localFromUri.size.height))"
      )
      return localFromUri
    }
    if let localFromPath = loadFromPath(normalized) {
      DocScannerDebugLog.log(
        "BarcodeImageSource",
        "loaded from path size=\(Int(localFromPath.size.width))x\(Int(localFromPath.size.height))"
      )
      return localFromPath
    }
    if let photoKitImage = loadFromPhotoKitLocalIdentifier(normalized) {
      DocScannerDebugLog.log(
        "BarcodeImageSource",
        "loaded from PhotoKit size=\(Int(photoKitImage.size.width))x\(Int(photoKitImage.size.height))"
      )
      return photoKitImage
    }

    if let data = decodeBase64Data(normalized) {
      let image = UIImage(data: data)
      if let image {
        DocScannerDebugLog.log(
          "BarcodeImageSource",
          "loaded from base64 size=\(Int(image.size.width))x\(Int(image.size.height))"
        )
      } else {
        DocScannerDebugLog.log("BarcodeImageSource", "base64 decode ok, UIImage init failed")
      }
      return image
    }

    DocScannerDebugLog.log("BarcodeImageSource", "all loaders failed")
    return nil
  }

  private static func loadFromFileUri(_ value: String) -> UIImage? {
    guard let url = URL(string: value), url.isFileURL else {
      return nil
    }

    if let image = loadFromPath(url.path) {
      return image
    }

    if let data = loadDataFromSecurityScopedURL(url) {
      DocScannerDebugLog.log("BarcodeImageSource", "loaded file:// via security-scoped data")
      return UIImage(data: data)
    }

    return nil
  }

  private static func loadFromPath(_ value: String) -> UIImage? {
    let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      return nil
    }

    if FileManager.default.fileExists(atPath: path) {
      return UIImage(contentsOfFile: path)
    }

    if let decoded = path.removingPercentEncoding,
       decoded != path,
       FileManager.default.fileExists(atPath: decoded) {
      return UIImage(contentsOfFile: decoded)
    }

    return nil
  }

  private static func loadFromPhotoKitLocalIdentifier(_ value: String) -> UIImage? {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          scheme == "ph" || scheme == "photos" else {
      return nil
    }

    var localIdentifier = value.replacingOccurrences(of: "\(scheme)://", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if localIdentifier.hasPrefix("/") {
      localIdentifier.removeFirst()
    }
    if let decoded = localIdentifier.removingPercentEncoding, !decoded.isEmpty {
      localIdentifier = decoded
    }
    guard !localIdentifier.isEmpty else {
      return nil
    }

    let fetchResult = PHAsset.fetchAssets(
      withLocalIdentifiers: [localIdentifier],
      options: nil
    )
    guard let asset = fetchResult.firstObject else {
      DocScannerDebugLog.log("BarcodeImageSource", "PhotoKit asset not found for local identifier")
      return nil
    }

    let options = PHImageRequestOptions()
    options.isSynchronous = false
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    options.version = .current

    var imageData: Data?
    let semaphore = DispatchSemaphore(value: 0)
    let imageManager = PHImageManager.default()
    let requestId = imageManager.requestImageDataAndOrientation(
      for: asset,
      options: options
    ) { data, _, _, _ in
      imageData = data
      semaphore.signal()
    }

    let waitResult = semaphore.wait(timeout: .now() + photoKitRequestTimeoutSeconds)
    if waitResult == .timedOut {
      imageManager.cancelImageRequest(requestId)
      DocScannerDebugLog.log("BarcodeImageSource", "PhotoKit request timed out")
      return nil
    }

    guard let imageData else {
      DocScannerDebugLog.log("BarcodeImageSource", "PhotoKit returned no image data")
      return nil
    }
    return UIImage(data: imageData)
  }

  private static func decodeBase64Data(_ value: String) -> Data? {
    let payload: String
    if let marker = value.range(of: "base64,") {
      payload = String(value[marker.upperBound...])
    } else {
      payload = value
    }

    let decoded = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
    if decoded == nil {
      DocScannerDebugLog.log("BarcodeImageSource", "base64 decode failed")
    }
    return decoded
  }

  private static func loadDataFromSecurityScopedURL(_ url: URL) -> Data? {
    var startedSecurityScope = false
    if url.isFileURL {
      startedSecurityScope = url.startAccessingSecurityScopedResource()
    }

    defer {
      if startedSecurityScope {
        url.stopAccessingSecurityScopedResource()
      }
    }

    ensureUbiquitousItemDownloadStarted(url)

    var coordinatedData: Data?
    var coordinationError: NSError?
    let coordinator = NSFileCoordinator(filePresenter: nil)

    coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
      coordinatedData = try? Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
    }

    if let coordinatedData {
      return coordinatedData
    }

    if coordinationError == nil {
      return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    DocScannerDebugLog.log("BarcodeImageSource", "security-scoped read failed for url=\(url.absoluteString)")
    return nil
  }

  private static func ensureUbiquitousItemDownloadStarted(_ url: URL) {
    guard url.isFileURL else {
      return
    }

    let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
    guard let values = try? url.resourceValues(forKeys: keys),
          values.isUbiquitousItem == true else {
      return
    }

    if values.ubiquitousItemDownloadingStatus == .notDownloaded {
      try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
  }
}
