import Foundation
import UIKit

enum BarcodeImageSource {
  static func loadImage(from imageSource: String) -> UIImage? {
    let normalized = imageSource.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
      return nil
    }

    if let localFromUri = loadFromFileUri(normalized) {
      return localFromUri
    }

    if let localFromPath = loadFromPath(normalized) {
      return localFromPath
    }

    if let data = decodeBase64Data(normalized) {
      return UIImage(data: data)
    }

    return nil
  }

  private static func loadFromFileUri(_ value: String) -> UIImage? {
    guard let url = URL(string: value), url.isFileURL else {
      return nil
    }
    return UIImage(contentsOfFile: url.path)
  }

  private static func loadFromPath(_ value: String) -> UIImage? {
    guard FileManager.default.fileExists(atPath: value) else {
      return nil
    }
    return UIImage(contentsOfFile: value)
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
}
