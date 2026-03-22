import DataDetection
import Foundation
import UIKit
import Vision

@available(iOS 26.0, *)
enum RecognizeDocumentsAnalyzer {
  struct Options {
    let includeBarcodes: Bool
    let includeText: Bool
    let includeTables: Bool
    let includeRegions: Bool
    let includeStructuredData: Bool
    let allowedBarcodeFormats: [String]
  }

  struct PageAnalysis {
    let barcodes: [AnalysisBarcode]
    let textBlocks: [AnalysisTextBlock]
    let tables: [AnalysisTable]
    let regions: [AnalysisRegion]
    let structuredData: AnalysisStructuredData
  }

  static func analyzeImageBlocking(
    _ image: UIImage,
    sourceImageIndex: Int,
    options: Options
  ) -> PageAnalysis {
    let semaphore = DispatchSemaphore(value: 0)
    var output = PageAnalysis(
      barcodes: [],
      textBlocks: [],
      tables: [],
      regions: [],
      structuredData: AnalysisStructuredData(entities: [], fields: [:])
    )

    Task {
      output = await analyzeImage(
        image,
        sourceImageIndex: sourceImageIndex,
        options: options
      )
      semaphore.signal()
    }

    semaphore.wait()
    return output
  }

  private static func analyzeImage(
    _ image: UIImage,
    sourceImageIndex: Int,
    options: Options
  ) async -> PageAnalysis {
    guard let cgImage = image.cgImage else {
      return PageAnalysis(
        barcodes: [],
        textBlocks: [],
        tables: [],
        regions: [],
        structuredData: AnalysisStructuredData(entities: [], fields: [:])
      )
    }

    var request = RecognizeDocumentsRequest()
    var barcodeOptions = request.barcodeDetectionOptions
    barcodeOptions.enabled = options.includeBarcodes

    let allowedFormats = Set(options.allowedBarcodeFormats.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    })
    let allowedSymbologies = symbologies(from: allowedFormats)
    if !allowedSymbologies.isEmpty {
      barcodeOptions.symbologies = allowedSymbologies
    }
    request.barcodeDetectionOptions = barcodeOptions

    let handler = ImageRequestHandler(cgImage)

    let observations: [DocumentObservation]
    do {
      observations = try await handler.perform(request)
    } catch {
      return PageAnalysis(
        barcodes: [],
        textBlocks: [],
        tables: [],
        regions: [],
        structuredData: AnalysisStructuredData(entities: [], fields: [:])
      )
    }

    var textBlocks: [AnalysisTextBlock] = []
    var tables: [AnalysisTable] = []
    var barcodes: [AnalysisBarcode] = []
    var entities: [AnalysisStructuredEntity] = []
    var fields: [String: String] = [:]
    var dedupEntities = Set<String>()
    var dedupBarcodes = Set<String>()
    var dedupTextBlocks = Set<String>()

    for observation in observations {
      let document = observation.document

      if options.includeText || options.includeRegions || options.includeStructuredData {
        let extractedText = extractTextBlocks(from: document, sourceImageIndex: sourceImageIndex)
        appendDeduplicatedTextBlocks(
          extractedText,
          dedup: &dedupTextBlocks,
          output: &textBlocks
        )
      }

      if options.includeTables || options.includeStructuredData {
        let extractedTables = extractTables(
          from: document,
          sourceImageIndex: sourceImageIndex
        )
        tables.append(contentsOf: extractedTables.tables)
        for (key, value) in extractedTables.fields {
          fields[key] = value
        }
      }

      if options.includeBarcodes {
        for barcode in document.barcodes {
          let value = normalizedBarcodeValue(from: barcode)
          guard !value.isEmpty else {
            continue
          }

          let format = normalizeBarcodeSymbology(barcode.symbology)
          if !allowedFormats.isEmpty && !allowedFormats.contains(format) {
            continue
          }

          let boundingBox = toBoundingBox(barcode.boundingRegion.boundingBox)
          let dedupKey = barcodeInstanceKey(
            format: format,
            value: value,
            sourceImageIndex: sourceImageIndex,
            boundingBox: boundingBox
          )
          if !dedupBarcodes.insert(dedupKey).inserted {
            continue
          }

          barcodes.append(
            AnalysisBarcode(
              value: value,
              format: format,
              sourceImageIndex: sourceImageIndex,
              boundingBox: boundingBox
            )
          )
        }
      }

      if options.includeStructuredData {
        collectStructuredEntities(
          from: document,
          sourceImageIndex: sourceImageIndex,
          entities: &entities,
          dedup: &dedupEntities
        )
      }
    }

    let sortedTextBlocks = textBlocks.sorted { lhs, rhs in
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

    let regions = options.includeRegions
      ? DocumentSemantics.inferRegions(from: sortedTextBlocks)
      : []

    return PageAnalysis(
      barcodes: barcodes.sorted { lhs, rhs in
        if lhs.sourceImageIndex != rhs.sourceImageIndex {
          return lhs.sourceImageIndex < rhs.sourceImageIndex
        }
        if lhs.value != rhs.value {
          return lhs.value < rhs.value
        }
        return lhs.format < rhs.format
      },
      textBlocks: sortedTextBlocks,
      tables: tables.sorted { lhs, rhs in
        lhs.sourceImageIndex < rhs.sourceImageIndex
      },
      regions: regions,
      structuredData: AnalysisStructuredData(
        entities: entities,
        fields: fields
      )
    )
  }

  private static func extractTextBlocks(
    from document: DocumentObservation.Container,
    sourceImageIndex: Int
  ) -> [AnalysisTextBlock] {
    var blocks: [AnalysisTextBlock] = []

    let paragraphs = document.paragraphs.isEmpty ? [document.text] : document.paragraphs

    for paragraph in paragraphs {
      let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty {
        continue
      }

      let lines: [AnalysisTextLine] = paragraph.lines.compactMap { line in
        let lineText = line.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if lineText.isEmpty {
          return nil
        }

        return AnalysisTextLine(
          text: lineText,
          sourceImageIndex: sourceImageIndex,
          boundingBox: toBoundingBox(line.boundingRegion.boundingBox),
          confidence: Double(line.confidence)
        )
      }

      blocks.append(
        AnalysisTextBlock(
          text: text,
          sourceImageIndex: sourceImageIndex,
          boundingBox: toBoundingBox(paragraph.boundingRegion.boundingBox),
          confidence: nil,
          lines: lines
        )
      )
    }

    if let title = document.title {
      let titleText = title.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
      if !titleText.isEmpty {
        blocks.insert(
          AnalysisTextBlock(
            text: titleText,
            sourceImageIndex: sourceImageIndex,
            boundingBox: toBoundingBox(title.boundingRegion.boundingBox),
            confidence: nil,
            lines: []
          ),
          at: 0
        )
      }
    }

    return blocks
  }

  private static func appendDeduplicatedTextBlocks(
    _ blocks: [AnalysisTextBlock],
    dedup: inout Set<String>,
    output: inout [AnalysisTextBlock]
  ) {
    for block in blocks {
      if let dedupKey = textBlockInstanceKey(block),
         !dedup.insert(dedupKey).inserted {
        continue
      }
      output.append(block)
    }
  }

  private struct TableExtractionResult {
    let tables: [AnalysisTable]
    let fields: [String: String]
  }

  private static func extractTables(
    from document: DocumentObservation.Container,
    sourceImageIndex: Int
  ) -> TableExtractionResult {
    var outputTables: [AnalysisTable] = []
    var fields: [String: String] = [:]

    for table in document.tables {
      var rows: [[String]] = []
      var cells: [AnalysisTableCell] = []

      for (rowIndex, row) in table.rows.enumerated() {
        var rowValues: [String] = []

        for (columnIndex, cell) in row.enumerated() {
          let value = cell.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
          rowValues.append(value)

          cells.append(
            AnalysisTableCell(
              text: value,
              row: rowIndex,
              column: columnIndex,
              sourceImageIndex: sourceImageIndex,
              boundingBox: toBoundingBox(cell.content.boundingRegion.boundingBox)
            )
          )
        }

        if rowValues.count >= 2 {
          let key = rowValues[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9а-я]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
          let value = rowValues[1].trimmingCharacters(in: .whitespacesAndNewlines)
          if !key.isEmpty && !value.isEmpty {
            fields[key] = value
          }
        }

        rows.append(rowValues)
      }

      outputTables.append(
        AnalysisTable(
          sourceImageIndex: sourceImageIndex,
          rows: rows,
          cells: cells,
          boundingBox: toBoundingBox(table.boundingRegion.boundingBox)
        )
      )
    }

    return TableExtractionResult(tables: outputTables, fields: fields)
  }

  private static func collectStructuredEntities(
    from document: DocumentObservation.Container,
    sourceImageIndex: Int,
    entities: inout [AnalysisStructuredEntity],
    dedup: inout Set<String>
  ) {
    appendEntities(
      from: document.text.detectedData,
      sourceImageIndex: sourceImageIndex,
      entities: &entities,
      dedup: &dedup
    )

    for paragraph in document.paragraphs {
      appendEntities(
        from: paragraph.detectedData,
        sourceImageIndex: sourceImageIndex,
        entities: &entities,
        dedup: &dedup
      )
    }

    for table in document.tables {
      for row in table.rows {
        for cell in row {
          appendEntities(
            from: cell.content.text.detectedData,
            sourceImageIndex: sourceImageIndex,
            entities: &entities,
            dedup: &dedup
          )
        }
      }
    }
  }

  private static func appendEntities(
    from matches: [DocumentObservation.Container.DataDetectorMatch],
    sourceImageIndex: Int,
    entities: inout [AnalysisStructuredEntity],
    dedup: inout Set<String>
  ) {
    for data in matches {
      let mapped: (type: String, value: String)?

      switch data.match.details {
      case .emailAddress(let email):
        mapped = ("email", email.emailAddress)
      case .phoneNumber(let phone):
        mapped = ("phone", phone.phoneNumber)
      case .calendarEvent(let event):
        if let startDate = event.startDate {
          mapped = ("date", iso8601String(from: startDate))
        } else {
          mapped = nil
        }
      case .moneyAmount(let money):
        mapped = ("amount", "\(money.currency.identifier) \(money.amount)")
      case .shipmentTrackingNumber(let tracking):
        mapped = ("id", tracking.trackingNumber)
      case .flightNumber(let flight):
        mapped = ("id", "\(flight.airlineCode)\(flight.flightNumber)")
      case .paymentIdentifier(let payment):
        mapped = ("id", payment.identifier)
      default:
        mapped = nil
      }

      guard let mapped else {
        continue
      }

      let value = mapped.value.trimmingCharacters(in: .whitespacesAndNewlines)
      if value.isEmpty {
        continue
      }

      let dedupKey = "\(mapped.type)|\(sourceImageIndex)|\(value)"
      if !dedup.insert(dedupKey).inserted {
        continue
      }

      entities.append(
        AnalysisStructuredEntity(
          type: mapped.type,
          value: value,
          sourceImageIndex: sourceImageIndex,
          boundingBox: toBoundingBox(data.boundingRegion.boundingBox),
          confidence: nil
        )
      )
    }
  }

  private static func normalizedBarcodeValue(from barcode: BarcodeObservation) -> String {
    if let payload = barcode.payloadString?.trimmingCharacters(in: .whitespacesAndNewlines),
       !payload.isEmpty {
      return payload
    }

    if let payloadData = barcode.payloadData,
       let text = String(data: payloadData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
      return text
    }

    return ""
  }

  private static func symbologies(from formats: Set<String>) -> [BarcodeSymbology] {
    if formats.isEmpty {
      return []
    }

    var values = Set<BarcodeSymbology>()

    for format in formats {
      switch format {
      case "aztec":
        values.insert(.aztec)
      case "codabar":
        values.insert(.codabar)
      case "code39":
        values.insert(.code39)
        values.insert(.code39Checksum)
        values.insert(.code39FullASCII)
        values.insert(.code39FullASCIIChecksum)
      case "code93":
        values.insert(.code93)
        values.insert(.code93i)
      case "code128":
        values.insert(.code128)
      case "dataMatrix":
        values.insert(.dataMatrix)
      case "ean8":
        values.insert(.ean8)
      case "ean13":
        values.insert(.ean13)
      case "itf":
        values.insert(.i2of5)
        values.insert(.i2of5Checksum)
        values.insert(.itf14)
      case "pdf417":
        values.insert(.pdf417)
        values.insert(.microPDF417)
      case "qr":
        values.insert(.qr)
        values.insert(.microQR)
      case "upce":
        values.insert(.upce)
      default:
        continue
      }
    }

    return Array(values)
  }

  private static func normalizeBarcodeSymbology(_ symbology: BarcodeSymbology) -> String {
    switch symbology {
    case .aztec:
      return "aztec"
    case .codabar:
      return "codabar"
    case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum:
      return "code39"
    case .code93, .code93i:
      return "code93"
    case .code128:
      return "code128"
    case .dataMatrix:
      return "dataMatrix"
    case .ean8:
      return "ean8"
    case .ean13:
      return "ean13"
    case .i2of5, .i2of5Checksum, .itf14:
      return "itf"
    case .pdf417, .microPDF417:
      return "pdf417"
    case .qr, .microQR:
      return "qr"
    case .upce:
      return "upce"
    default:
      return "unknown"
    }
  }

  private static func barcodeInstanceKey(
    format: String,
    value: String,
    sourceImageIndex: Int,
    boundingBox: AnalysisBoundingBox
  ) -> String {
    let centerX = boundingBox.left + (boundingBox.width * 0.5)
    let centerY = boundingBox.top + (boundingBox.height * 0.5)
    let xBucket = quantize(centerX, bucketCount: 24)
    let yBucket = quantize(centerY, bucketCount: 24)
    return "\(format)|\(sourceImageIndex)|\(value)|\(xBucket):\(yBucket)"
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
    let xBucket = quantize(centerX, bucketCount: 24)
    let yBucket = quantize(centerY, bucketCount: 24)
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

  private static func toBoundingBox(_ rect: NormalizedRect) -> AnalysisBoundingBox {
    let cgRect = rect.cgRect
    let left = cgRect.minX.clamped(to: 0 ... 1)
    let top = (1 - cgRect.maxY).clamped(to: 0 ... 1)
    let width = cgRect.width.clamped(to: 0 ... 1)
    let height = cgRect.height.clamped(to: 0 ... 1)

    return AnalysisBoundingBox(
      left: Double(left),
      top: Double(top),
      width: Double(width),
      height: Double(height)
    )
  }

  private static func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}

private extension CGFloat {
  func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
    return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}
