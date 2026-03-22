import Foundation
import UIKit

enum BarcodeImageSource {
  static func loadImage(from imageSource: String) -> UIImage? {
    let normalized = imageSource.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
      return nil
    }

    if let localFromUri = loadFromFileUri(normalized) { return localFromUri }
    if let localFromPath = loadFromPath(normalized) { return localFromPath }

    if let data = decodeBase64Data(normalized) {
      return UIImage(data: data)
    }

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

  private static func decodeBase64Data(_ value: String) -> Data? {
    let payload: String
    if let marker = value.range(of: "base64,") {
      payload = String(value[marker.upperBound...])
    } else {
      payload = value
    }

    return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
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
