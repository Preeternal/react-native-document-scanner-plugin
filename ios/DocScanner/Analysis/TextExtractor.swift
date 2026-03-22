import CoreGraphics
import Foundation
import UIKit
import Vision

enum TextExtractor {
  private enum FallbackThreshold {
    static let minimumTotalCharacters = 24
  }

  private enum DedupThreshold {
    static let centerBucketCount = 24
  }

  static func extractFromImage(
    _ image: UIImage,
    sourceImageIndex: Int,
    enableRotate180Fallback: Bool = false
  ) -> [AnalysisTextBlock] {
    let firstPass = extractSinglePass(
      image,
      sourceImageIndex: sourceImageIndex
    )

    guard enableRotate180Fallback else {
      return firstPass
    }
    guard shouldRunRotateFallback(firstPass) else {
      return firstPass
    }
    guard let rotated = rotate180(image) else {
      return firstPass
    }

    let secondPass = extractSinglePass(
      rotated,
      sourceImageIndex: sourceImageIndex
    )

    return totalCharacterCount(secondPass) > totalCharacterCount(firstPass)
      ? secondPass
      : firstPass
  }

  private static func extractSinglePass(
    _ image: UIImage,
    sourceImageIndex: Int
  ) -> [AnalysisTextBlock] {
    guard let cgImage = image.cgImage else {
      return []
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return []
    }

    guard let observations = request.results as? [VNRecognizedTextObservation] else {
      return []
    }

    var blocks: [AnalysisTextBlock] = []
    var deduplicated = Set<String>()

    for observation in observations {
      guard let candidate = observation.topCandidates(1).first else {
        continue
      }

      let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty {
        continue
      }

      let bbox = normalizeBoundingBox(observation.boundingBox)
      let confidence = Double(candidate.confidence)
      let line = AnalysisTextLine(
        text: text,
        sourceImageIndex: sourceImageIndex,
        boundingBox: bbox,
        confidence: confidence
      )

      let block = AnalysisTextBlock(
        text: text,
        sourceImageIndex: sourceImageIndex,
        boundingBox: bbox,
        confidence: confidence,
        lines: [line]
      )

      if let dedupKey = textBlockInstanceKey(block),
         !deduplicated.insert(dedupKey).inserted {
        continue
      }

      blocks.append(block)
    }

    return blocks.sorted { lhs, rhs in
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
  }

  private static func shouldRunRotateFallback(_ blocks: [AnalysisTextBlock]) -> Bool {
    if blocks.isEmpty {
      return true
    }

    return totalCharacterCount(blocks) < FallbackThreshold.minimumTotalCharacters
  }

  private static func totalCharacterCount(_ blocks: [AnalysisTextBlock]) -> Int {
    return blocks.reduce(0) { partial, block in
      partial + block.text.count
    }
  }

  private static func textBlockInstanceKey(_ block: AnalysisTextBlock) -> String? {
    let normalizedText = normalizeTextForDedup(block.text)
    guard !normalizedText.isEmpty else {
      return nil
    }
    guard let boundingBox = block.boundingBox else {
      return nil
    }

    let centerX = boundingBox.left + (boundingBox.width * 0.5)
    let centerY = boundingBox.top + (boundingBox.height * 0.5)
    let xBucket = quantize(centerX, bucketCount: DedupThreshold.centerBucketCount)
    let yBucket = quantize(centerY, bucketCount: DedupThreshold.centerBucketCount)
    return "\(block.sourceImageIndex)|\(normalizedText)|\(xBucket):\(yBucket)"
  }

  private static func normalizeTextForDedup(_ value: String) -> String {
    let parts = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
    return parts.joined(separator: " ")
  }

  private static func quantize(_ value: Double, bucketCount: Int) -> Int {
    guard bucketCount > 1 else {
      return 0
    }

    let clamped = min(max(value, 0), 1)
    let scaled = Int(floor(clamped * Double(bucketCount)))
    return min(bucketCount - 1, max(0, scaled))
  }

  private static func rotate180(_ image: UIImage) -> UIImage? {
    guard let cgImage = image.cgImage else {
      return nil
    }

    let size = CGSize(width: cgImage.width, height: cgImage.height)
    UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
    guard let context = UIGraphicsGetCurrentContext() else {
      UIGraphicsEndImageContext()
      return nil
    }

    context.translateBy(x: size.width / 2, y: size.height / 2)
    context.rotate(by: .pi)
    image.draw(in: CGRect(
      x: -size.width / 2,
      y: -size.height / 2,
      width: size.width,
      height: size.height
    ))

    let rotated = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return rotated
  }

  private static func normalizeBoundingBox(_ rect: CGRect) -> AnalysisBoundingBox {
    let left = rect.minX.clamped(to: 0.0 ... 1.0)
    let top = (1.0 - rect.maxY).clamped(to: 0.0 ... 1.0)
    let width = rect.width.clamped(to: 0.0 ... 1.0)
    let height = rect.height.clamped(to: 0.0 ... 1.0)

    return AnalysisBoundingBox(
      left: Double(left),
      top: Double(top),
      width: Double(width),
      height: Double(height)
    )
  }
}

private extension CGFloat {
  func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
    return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}
