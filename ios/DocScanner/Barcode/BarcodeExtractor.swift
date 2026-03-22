import CoreGraphics
import Foundation
import UIKit
import Vision

private enum BarcodeExtractionConstants {
  static let cropWidthPercent: CGFloat = 25.0
  static let cropHeightPercent: CGFloat = 20.0
  static let cornerMarginPercent: CGFloat = 0.03
}

private let supportedNormalizedFormats: Set<String> = [
  "aztec",
  "codabar",
  "code39",
  "code93",
  "code128",
  "dataMatrix",
  "ean8",
  "ean13",
  "itf",
  "pdf417",
  "qr",
  "upca",
  "upce"
]

struct ExtractedBarcode {
  let value: String
  let format: String
}

enum BarcodeExtractor {
  static func extractFromImage(
    _ image: UIImage,
    allowedFormats: [String] = []
  ) -> [ExtractedBarcode] {
    let normalizedAllowedFormats = normalizeAllowedFormats(allowedFormats)
    let candidates = rotationCandidates(for: image)

    for candidate in candidates {
      let detected = detectInTopRightROI(candidate, allowedFormats: normalizedAllowedFormats)
      if !detected.isEmpty {
        return detected
      }
    }

    return []
  }

  private static func rotationCandidates(for image: UIImage) -> [UIImage] {
    var candidates: [UIImage] = [image]

    if let rotated90 = image.rotated(by: .pi / 2) {
      candidates.append(rotated90)
    }
    if let rotatedMinus90 = image.rotated(by: -.pi / 2) {
      candidates.append(rotatedMinus90)
    }
    if let rotated180 = image.rotated(by: .pi) {
      candidates.append(rotated180)
    }

    return candidates
  }

  private static func detectInTopRightROI(
    _ image: UIImage,
    allowedFormats: Set<String>
  ) -> [ExtractedBarcode] {
    guard let cgImage = image.cgImage else { return [] }

    let roi = roiRect(forWidth: CGFloat(cgImage.width), height: CGFloat(cgImage.height)).integral
    guard roi.width > 1, roi.height > 1 else { return [] }

    guard let croppedCgImage = cgImage.cropping(to: roi) else { return [] }

    let request = VNDetectBarcodesRequest()
    if !allowedFormats.isEmpty {
      let requestedSymbologies = request.supportedSymbologies.filter {
        allowedFormats.contains(normalizeFormat($0))
      }
      if !requestedSymbologies.isEmpty {
        request.symbologies = requestedSymbologies
      }
    }

    let handler = VNImageRequestHandler(cgImage: croppedCgImage, options: [:])

    do {
      try handler.perform([request])
    } catch {
      return []
    }

    guard let observations = request.results as? [VNBarcodeObservation] else {
      return []
    }

    var deduplicated = Set<String>()
    var results: [ExtractedBarcode] = []

    for observation in observations {
      guard let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !payload.isEmpty else {
        continue
      }

      let normalizedFormat = normalizeFormat(observation.symbology)
      if !allowedFormats.isEmpty && !allowedFormats.contains(normalizedFormat) {
        continue
      }

      let dedupKey = "\(normalizedFormat)|\(payload)"
      if deduplicated.insert(dedupKey).inserted {
        results.append(ExtractedBarcode(value: payload, format: normalizedFormat))
      }
    }

    return results
  }

  private static func roiRect(forWidth width: CGFloat, height: CGFloat) -> CGRect {
    let cropWidth = width * BarcodeExtractionConstants.cropWidthPercent / 100.0
    let cropHeight = height * BarcodeExtractionConstants.cropHeightPercent / 100.0
    let marginX = width * BarcodeExtractionConstants.cornerMarginPercent
    let marginY = height * BarcodeExtractionConstants.cornerMarginPercent

    let originX = max(0, width - cropWidth - marginX)
    let originY = max(0, marginY)
    let finalWidth = min(cropWidth, width - originX)
    let finalHeight = min(cropHeight, height - originY)

    return CGRect(x: originX, y: originY, width: finalWidth, height: finalHeight)
  }

  private static func normalizeAllowedFormats(_ rawFormats: [String]) -> Set<String> {
    guard !rawFormats.isEmpty else {
      return []
    }

    let normalized = rawFormats.compactMap { normalizeRequestedFormat($0) }
    return Set(normalized).intersection(supportedNormalizedFormats)
  }

  private static func normalizeRequestedFormat(_ format: String) -> String? {
    let compact = format
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: " ", with: "")

    switch compact {
    case "aztec":
      return "aztec"
    case "codabar":
      return "codabar"
    case "code39":
      return "code39"
    case "code93":
      return "code93"
    case "code128":
      return "code128"
    case "datamatrix":
      return "dataMatrix"
    case "ean8":
      return "ean8"
    case "ean13":
      return "ean13"
    case "itf", "i2of5", "interleaved2of5":
      return "itf"
    case "pdf417", "micropdf417":
      return "pdf417"
    case "qr", "microqr":
      return "qr"
    case "upca":
      return "upca"
    case "upce":
      return "upce"
    default:
      return nil
    }
  }

  private static func normalizeFormat(_ symbology: VNBarcodeSymbology) -> String {
    let raw = symbology.rawValue.lowercased()
    if raw.contains("aztec") { return "aztec" }
    if raw.contains("codabar") { return "codabar" }
    if raw.contains("code39") { return "code39" }
    if raw.contains("code93") { return "code93" }
    if raw.contains("code128") { return "code128" }
    if raw.contains("datamatrix") { return "dataMatrix" }
    if raw.contains("ean8") { return "ean8" }
    if raw.contains("ean13") { return "ean13" }
    if raw.contains("itf") || raw.contains("i2of5") || raw.contains("interleaved2of5") { return "itf" }
    if raw.contains("pdf417") || raw.contains("micropdf417") { return "pdf417" }
    if raw.contains("qr") || raw.contains("microqr") { return "qr" }
    if raw.contains("upca") { return "upca" }
    if raw.contains("upce") { return "upce" }
    return "unknown"
  }
}

private extension UIImage {
  func rotated(by radians: CGFloat) -> UIImage? {
    var newSize = CGRect(origin: .zero, size: size)
      .applying(CGAffineTransform(rotationAngle: radians))
      .integral
      .size

    newSize.width = floor(newSize.width)
    newSize.height = floor(newSize.height)

    UIGraphicsBeginImageContextWithOptions(newSize, false, scale)
    guard let context = UIGraphicsGetCurrentContext() else {
      UIGraphicsEndImageContext()
      return nil
    }

    context.translateBy(x: newSize.width / 2, y: newSize.height / 2)
    context.rotate(by: radians)

    draw(in: CGRect(
      x: -size.width / 2,
      y: -size.height / 2,
      width: size.width,
      height: size.height
    ))

    let rotated = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    return rotated
  }
}
