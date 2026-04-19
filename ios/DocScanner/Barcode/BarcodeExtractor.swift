import CoreGraphics
import CoreImage
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
  let instanceKey: String
}

enum BarcodeExtractor {
  private static func log(_ message: @autoclosure () -> String) {
    DocScannerDebugLog.log("BarcodeExtractor", message())
  }

  private static func trace(_ message: @autoclosure () -> String) {
    DocScannerDebugLog.trace("BarcodeExtractor", message())
  }

  static func extractFromImage(
    _ image: UIImage,
    allowedFormats: [String] = []
  ) -> [ExtractedBarcode] {
    let preparedImage = image.normalizedForVision()
    let normalizedAllowedFormats = normalizeAllowedFormats(allowedFormats)
    // When Vision cannot create an inference context for a given image,
    // short-circuit remaining Vision attempts for this image and continue with fallbacks.
    var visionEnabled = true
    log(
      "extract start image=\(Int(preparedImage.size.width))x\(Int(preparedImage.size.height)) allowedRaw=\(allowedFormats) allowedNormalized=\(Array(normalizedAllowedFormats).sorted())"
    )
    var deduplicated = Set<String>()
    var aggregated: [ExtractedBarcode] = []

    let firstPass = detectInTopRightROI(
      preparedImage,
      allowedFormats: normalizedAllowedFormats,
      visionEnabled: &visionEnabled,
      attemptIndex: 0
    )
    appendUnique(
      firstPass,
      deduplicated: &deduplicated,
      aggregated: &aggregated
    )
    if !aggregated.isEmpty {
      log("extract resolved after attempt=0 total=\(aggregated.count)")
      return aggregated
    }

    if let rotated180 = preparedImage.rotated(by: .pi) {
      let secondPass = detectInTopRightROI(
        rotated180,
        allowedFormats: normalizedAllowedFormats,
        visionEnabled: &visionEnabled,
        attemptIndex: 1
      )
      appendUnique(
        secondPass,
        deduplicated: &deduplicated,
        aggregated: &aggregated
      )
      if !aggregated.isEmpty {
        log("extract resolved after attempt=1 total=\(aggregated.count)")
        return aggregated
      }
    }

    if !aggregated.isEmpty {
      log("extract resolved in ROI stage total=\(aggregated.count)")
      return aggregated
    }

    // Gallery images often don't place barcodes in the expected corner ROI.
    // Run full-frame fallback only when ROI pipeline found nothing.
    let fullFrameFirstPass = detectInFullFrame(
      preparedImage,
      allowedFormats: normalizedAllowedFormats,
      visionEnabled: &visionEnabled,
      attemptIndex: 2
    )
    appendUnique(
      fullFrameFirstPass,
      deduplicated: &deduplicated,
      aggregated: &aggregated
    )
    if !aggregated.isEmpty {
      log("extract resolved full-frame stage total=\(aggregated.count)")
      return aggregated
    }

    if let rotated180 = preparedImage.rotated(by: .pi) {
      let fullFrameSecondPass = detectInFullFrame(
        rotated180,
        allowedFormats: normalizedAllowedFormats,
        visionEnabled: &visionEnabled,
        attemptIndex: 3
      )
      appendUnique(
        fullFrameSecondPass,
        deduplicated: &deduplicated,
        aggregated: &aggregated
      )
      if !aggregated.isEmpty {
        log("extract resolved after full-frame 180 total=\(aggregated.count)")
        return aggregated
      }
    }

#if targetEnvironment(simulator)
    // Simulator Vision barcode detection can miss valid 1D codes in static gallery assets.
    // When all barcode passes fail, recover common 1D formats from OCR with checksum validation.
    let ocr1D = detectWithNumericOcrFallback(
      preparedImage,
      allowedFormats: normalizedAllowedFormats,
      attemptIndex: 99
    )
    appendUnique(
      ocr1D,
      deduplicated: &deduplicated,
      aggregated: &aggregated
    )
    if !aggregated.isEmpty {
      log("extract resolved with OCR 1D fallback total=\(aggregated.count)")
      return aggregated
    }
#endif

    // Extra QR-only fallback via CoreImage. This helps when Vision barcode
    // request misses gallery-generated QR assets.
    let coreImageQr = detectQrWithCoreImage(
      preparedImage,
      attemptIndex: 100
    )
    appendUnique(
      coreImageQr,
      deduplicated: &deduplicated,
      aggregated: &aggregated
    )
    log("extract completed total=\(aggregated.count)")

    return aggregated
  }

  private static func appendUnique(
    _ detected: [ExtractedBarcode],
    deduplicated: inout Set<String>,
    aggregated: inout [ExtractedBarcode]
  ) {
    let before = aggregated.count
    for barcode in detected {
      if deduplicated.insert(barcode.instanceKey).inserted {
        aggregated.append(barcode)
      }
    }
    let added = aggregated.count - before
    trace("appendUnique detected=\(detected.count) added=\(added) total=\(aggregated.count)")
  }

  private static func detectInTopRightROI(
    _ image: UIImage,
    allowedFormats: Set<String>,
    visionEnabled: inout Bool,
    attemptIndex: Int
  ) -> [ExtractedBarcode] {
    guard let cgImage = image.cgImage else {
      trace("attempt=\(attemptIndex) roi skip: missing cgImage")
      return []
    }

    let roi = roiRect(forWidth: CGFloat(cgImage.width), height: CGFloat(cgImage.height)).integral
    guard roi.width > 1, roi.height > 1 else {
      trace("attempt=\(attemptIndex) roi skip: invalid roi \(roi)")
      return []
    }

    guard let croppedCgImage = cgImage.cropping(to: roi) else {
      trace("attempt=\(attemptIndex) roi crop failed roi=\(roi)")
      return []
    }
    trace(
      "attempt=\(attemptIndex) roi detect source=\(cgImage.width)x\(cgImage.height) roi=\(Int(roi.origin.x)),\(Int(roi.origin.y)),\(Int(roi.size.width))x\(Int(roi.size.height))"
    )

    return detectInCgImage(
      croppedCgImage,
      allowedFormats: allowedFormats,
      visionEnabled: &visionEnabled,
      attemptIndex: attemptIndex
    )
  }

  private static func detectInFullFrame(
    _ image: UIImage,
    allowedFormats: Set<String>,
    visionEnabled: inout Bool,
    attemptIndex: Int
  ) -> [ExtractedBarcode] {
    guard let cgImage = image.cgImage else {
      trace("attempt=\(attemptIndex) full-frame skip: missing cgImage")
      return []
    }
    trace("attempt=\(attemptIndex) full-frame detect size=\(cgImage.width)x\(cgImage.height)")

    return detectInCgImage(
      cgImage,
      allowedFormats: allowedFormats,
      visionEnabled: &visionEnabled,
      attemptIndex: attemptIndex
    )
  }

  private static func detectInCgImage(
    _ cgImage: CGImage,
    allowedFormats: Set<String>,
    visionEnabled: inout Bool,
    attemptIndex: Int,
    forcedSymbologies: [VNBarcodeSymbology]? = nil,
    regionOfInterest: CGRect? = nil
  ) -> [ExtractedBarcode] {
    if !visionEnabled {
      trace("attempt=\(attemptIndex) skip Vision detect: disabled after fatal inference-context failure")
      return []
    }

    let request = VNDetectBarcodesRequest()
    var configuredSymbologies = 0
    if let forcedSymbologies {
      let supported = Set(VNDetectBarcodesRequest.supportedSymbologies)
      let filtered = forcedSymbologies.filter { supported.contains($0) }
      if !filtered.isEmpty {
        request.symbologies = filtered
        configuredSymbologies = filtered.count
      }
    } else {
      if allowedFormats.isEmpty {
        request.symbologies = VNDetectBarcodesRequest.supportedSymbologies
        configuredSymbologies = request.symbologies.count
      } else {
        let requestedSymbologies = VNDetectBarcodesRequest.supportedSymbologies.filter {
          allowedFormats.contains(normalizeFormat($0))
        }
        if !requestedSymbologies.isEmpty {
          request.symbologies = requestedSymbologies
          configuredSymbologies = requestedSymbologies.count
        }
      }
    }

    if let regionOfInterest {
      request.regionOfInterest = regionOfInterest
    }

#if targetEnvironment(simulator)
    request.usesCPUOnly = true
#endif

    let roiDescription = regionOfInterest.map {
      String(
        format: "%.2f,%.2f,%.2f,%.2f",
        $0.origin.x,
        $0.origin.y,
        $0.size.width,
        $0.size.height
      )
    } ?? "full"

    trace(
      "attempt=\(attemptIndex) perform detect allowedFormats=\(Array(allowedFormats).sorted()) configuredSymbologies=\(configuredSymbologies) forced=\(forcedSymbologies != nil) roi=\(roiDescription)"
    )

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

    do {
      try handler.perform([request])
    } catch {
      trace("attempt=\(attemptIndex) Vision perform failed error=\(error.localizedDescription)")
      if isFatalInferenceContextError(error) {
        visionEnabled = false
        log("disabling Vision for current image due to fatal inference-context failure (attempt=\(attemptIndex))")
      }
      return []
    }

    guard let observations = request.results as? [VNBarcodeObservation] else {
      trace("attempt=\(attemptIndex) no observations array")
      return []
    }
    trace("attempt=\(attemptIndex) observations=\(observations.count)")

    var deduplicated = Set<String>()
    var results: [ExtractedBarcode] = []
    var filteredByAllowed = 0
    var filteredEmptyPayload = 0

    for observation in observations {
      guard let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !payload.isEmpty else {
        filteredEmptyPayload += 1
        continue
      }

      let normalizedFormat = normalizeFormat(observation.symbology)
      if !allowedFormats.isEmpty && !allowedFormats.contains(normalizedFormat) {
        filteredByAllowed += 1
        continue
      }

      let centerBucket = bucketKey(for: observation.boundingBox)
      let dedupKey = "\(normalizedFormat)|\(payload)|\(centerBucket)"
      if deduplicated.insert(dedupKey).inserted {
        results.append(
          ExtractedBarcode(
            value: payload,
            format: normalizedFormat,
            instanceKey: dedupKey
          )
        )
      }
    }
    trace(
      "attempt=\(attemptIndex) results=\(results.count) filtered(emptyPayload=\(filteredEmptyPayload), byAllowed=\(filteredByAllowed))"
    )

    return results
  }

  private static func isFatalInferenceContextError(_ error: Error) -> Bool {
    let message = error.localizedDescription.lowercased()
    return message.contains("inference context")
  }

  private static func bucketKey(for rect: CGRect, bucketCount: Int = 24) -> String {
    let centerX = min(max((rect.minX + rect.maxX) * 0.5, 0), 1)
    let centerY = min(max((rect.minY + rect.maxY) * 0.5, 0), 1)

    let xBucket = quantize(centerX, bucketCount: bucketCount)
    let yBucket = quantize(centerY, bucketCount: bucketCount)
    return "\(xBucket):\(yBucket)"
  }

  private static func quantize(_ value: CGFloat, bucketCount: Int) -> Int {
    guard bucketCount > 1 else {
      return 0
    }

    let clamped = min(max(value, 0), 1)
    let scaled = Int(floor(clamped * CGFloat(bucketCount)))
    return min(bucketCount - 1, max(0, scaled))
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

  private static func detectQrWithCoreImage(
    _ image: UIImage,
    attemptIndex: Int
  ) -> [ExtractedBarcode] {
    guard let ciImage = image.ciImage ?? CIImage(image: image) else {
      trace("attempt=\(attemptIndex) CoreImage QR skip: cannot build CIImage")
      return []
    }

    let detector = CIDetector(
      ofType: CIDetectorTypeQRCode,
      context: nil,
      options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )
    guard let features = detector?.features(in: ciImage) as? [CIQRCodeFeature] else {
      trace("attempt=\(attemptIndex) CoreImage QR no features")
      return []
    }
    trace("attempt=\(attemptIndex) CoreImage QR features=\(features.count)")

    var deduplicated = Set<String>()
    var results: [ExtractedBarcode] = []
    let extent = ciImage.extent
    let width = max(1.0, extent.width)
    let height = max(1.0, extent.height)

    for feature in features {
      let value = feature.messageString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if value.isEmpty {
        continue
      }

      let bounds = feature.bounds
      let centerX = (bounds.midX - extent.minX) / width
      let centerY = (bounds.midY - extent.minY) / height
      let xBucket = quantize(centerX, bucketCount: 24)
      let yBucket = quantize(centerY, bucketCount: 24)
      let dedupKey = "qr|\(value)|\(xBucket):\(yBucket)"

      if deduplicated.insert(dedupKey).inserted {
        trace("attempt=\(attemptIndex) CoreImage QR value=\(value)")
        results.append(
          ExtractedBarcode(
            value: value,
            format: "qr",
            instanceKey: dedupKey
          )
        )
      }
    }

    trace("attempt=\(attemptIndex) CoreImage QR results=\(results.count)")
    return results
  }

  private static func detectWithNumericOcrFallback(
    _ image: UIImage,
    allowedFormats: Set<String>,
    attemptIndex: Int
  ) -> [ExtractedBarcode] {
    let supportedFormats: Set<String> = ["ean8", "ean13", "upca", "itf"]
    let targetFormats: Set<String> = {
      if allowedFormats.isEmpty {
        return supportedFormats
      }
      return allowedFormats.intersection(supportedFormats)
    }()

    guard !targetFormats.isEmpty else {
      trace("attempt=\(attemptIndex) OCR 1D skip: no supported target formats")
      return []
    }

    guard let cgImage = image.cgImage else {
      trace("attempt=\(attemptIndex) OCR 1D skip: missing cgImage")
      return []
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.02

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
      try handler.perform([request])
    } catch {
      trace("attempt=\(attemptIndex) OCR 1D perform failed error=\(error.localizedDescription)")
      return []
    }

    guard let observations = request.results as? [VNRecognizedTextObservation], !observations.isEmpty else {
      trace("attempt=\(attemptIndex) OCR 1D no observations")
      return []
    }

    var rawCandidates: [String] = []
    rawCandidates.reserveCapacity(observations.count * 3)

    for observation in observations {
      for candidate in observation.topCandidates(3) {
        rawCandidates.append(candidate.string)
      }
    }

    let combinedTopLineOrder = observations
      .compactMap { observation -> (box: CGRect, text: String)? in
        guard let top = observation.topCandidates(1).first else {
          return nil
        }
        return (observation.boundingBox, top.string)
      }
      .sorted { lhs, rhs in
        let lhsMidY = lhs.box.midY
        let rhsMidY = rhs.box.midY
        if abs(lhsMidY - rhsMidY) > 0.03 {
          return lhsMidY > rhsMidY
        }
        return lhs.box.minX < rhs.box.minX
      }
      .map(\.text)
      .joined(separator: " ")

    if !combinedTopLineOrder.isEmpty {
      rawCandidates.append(combinedTopLineOrder)
    }

    var dedup = Set<String>()
    var results: [ExtractedBarcode] = []

    for raw in rawCandidates {
      let digits = digitsOnly(raw)
      guard digits.count >= 8 else {
        continue
      }

      for detected in parseGtinCandidates(
        from: digits,
        allowedFormats: targetFormats
      ) {
        let dedupKey = "\(detected.format)|\(detected.value)|ocr"
        if dedup.insert(dedupKey).inserted {
          results.append(
            ExtractedBarcode(
              value: detected.value,
              format: detected.format,
              instanceKey: dedupKey
            )
          )
        }
      }
    }

    trace("attempt=\(attemptIndex) OCR 1D results=\(results.count)")
    return results
  }

  private static func parseGtinCandidates(
    from digits: String,
    allowedFormats: Set<String>
  ) -> [(value: String, format: String)] {
    let allowedLengths = candidateLengths(forAllowedFormats: allowedFormats)
    guard !allowedLengths.isEmpty else {
      return []
    }

    let scalars = Array(digits)
    guard scalars.count >= allowedLengths.min() ?? 0 else {
      return []
    }

    var dedup = Set<String>()
    var output: [(value: String, format: String)] = []

    for length in allowedLengths where scalars.count >= length {
      for start in 0...(scalars.count - length) {
        let candidate = String(scalars[start..<(start + length)])
        guard hasValidGTINCheckDigit(candidate) else {
          continue
        }
        guard let format = formatForValidatedCandidate(
          candidate,
          allowedFormats: allowedFormats
        ) else {
          continue
        }

        let dedupKey = "\(format)|\(candidate)"
        if dedup.insert(dedupKey).inserted {
          output.append((candidate, format))
        }
      }
    }

    return output
  }

  private static func candidateLengths(forAllowedFormats allowedFormats: Set<String>) -> [Int] {
    var lengths = Set<Int>()
    if allowedFormats.contains("itf") {
      lengths.insert(14)
    }
    if allowedFormats.contains("ean13") {
      lengths.insert(13)
    }
    if allowedFormats.contains("upca") {
      lengths.insert(12)
    }
    if allowedFormats.contains("ean8") {
      lengths.insert(8)
    }
    return lengths.sorted(by: >)
  }

  private static func formatForValidatedCandidate(
    _ value: String,
    allowedFormats: Set<String>
  ) -> String? {
    switch value.count {
    case 14 where allowedFormats.contains("itf"):
      return "itf"
    case 13 where allowedFormats.contains("ean13"):
      return "ean13"
    case 12 where allowedFormats.contains("upca"):
      return "upca"
    case 8 where allowedFormats.contains("ean8"):
      return "ean8"
    default:
      return nil
    }
  }

  private static func hasValidGTINCheckDigit(_ value: String) -> Bool {
    let digits = value.compactMap(\.wholeNumberValue)
    guard digits.count == value.count,
          [8, 12, 13, 14].contains(digits.count),
          let checkDigit = digits.last else {
      return false
    }

    let payload = digits.dropLast().reversed()
    let weightedSum = payload.enumerated().reduce(0) { partial, entry in
      let (index, digit) = entry
      let weight = (index % 2 == 0) ? 3 : 1
      return partial + (digit * weight)
    }
    let computed = (10 - (weightedSum % 10)) % 10
    return computed == checkDigit
  }

  private static func digitsOnly(_ value: String) -> String {
    let scalars = value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
    return String(String.UnicodeScalarView(scalars))
  }
}

extension UIImage {
  func normalizedForVision() -> UIImage {
    if imageOrientation == .up {
      return self
    }

    UIGraphicsBeginImageContextWithOptions(size, false, scale)
    defer { UIGraphicsEndImageContext() }
    draw(in: CGRect(origin: .zero, size: size))
    return UIGraphicsGetImageFromCurrentImageContext() ?? self
  }

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
