import Foundation

private struct TextLineEntry {
  let text: String
  let sourceImageIndex: Int
  let boundingBox: AnalysisBoundingBox?
}

enum DocumentSemantics {
  private static let fieldRegex = compileRegex(
    name: "fieldRegex",
    pattern: "^([A-Za-z0-9А-Яа-я _./-]{2,40})\\s*[:-]\\s*(.+)$",
    options: []
  )

  private static let phoneRegex = compileRegex(
    name: "phoneRegex",
    pattern: "(?:\\+?\\d[\\d\\s().-]{7,}\\d)",
    options: []
  )

  private static let emailRegex = compileRegex(
    name: "emailRegex",
    pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
    options: [.caseInsensitive]
  )

  private static let dateRegex = compileRegex(
    name: "dateRegex",
    pattern: "\\b(?:\\d{1,2}[./-]\\d{1,2}[./-]\\d{2,4}|\\d{4}[./-]\\d{1,2}[./-]\\d{1,2})\\b",
    options: []
  )

  private static let amountRegex = compileRegex(
    name: "amountRegex",
    pattern: "\\b(?:[$€£]\\s?)?\\d{1,3}(?:[ ,]\\d{3})*(?:[.,]\\d{2})\\b",
    options: []
  )

  private static let tableSplitRegex = compileRegex(
    name: "tableSplitRegex",
    pattern: "\\s{2,}|\\t|\\|",
    options: []
  )

  private static func compileRegex(
    name: String,
    pattern: String,
    options: NSRegularExpression.Options
  ) -> NSRegularExpression? {
    do {
      return try NSRegularExpression(pattern: pattern, options: options)
    } catch {
      assertionFailure("Invalid regex '\(name)': \(error)")
      NSLog("[DocumentScanner][DocumentSemantics] regex compile failed name=\(name) error=\(error.localizedDescription)")
      return nil
    }
  }

  static func inferRegions(from textBlocks: [AnalysisTextBlock]) -> [AnalysisRegion] {
    var regions: [AnalysisRegion] = []

    for block in textBlocks {
      guard let box = block.boundingBox else {
        continue
      }

      let bottom = box.top + box.height
      let type: String
      if box.top < 0.18 {
        type = "header"
      } else if bottom > 0.84 {
        type = "footer"
      } else {
        type = "paragraph"
      }

      regions.append(
        AnalysisRegion(
          type: type,
          sourceImageIndex: block.sourceImageIndex,
          boundingBox: box,
          score: 0.6,
          text: block.text
        )
      )
    }

    return regions
  }

  static func inferTables(from textBlocks: [AnalysisTextBlock]) -> [AnalysisTable] {
    let lines = flattenTextLines(from: textBlocks)
    let grouped = Dictionary(grouping: lines) { $0.sourceImageIndex }
    var tables: [AnalysisTable] = []

    for (sourceImageIndex, sourceLines) in grouped {
      var parsedRows: [(cells: [String], boundingBox: AnalysisBoundingBox?)] = []

      for line in sourceLines {
        let cells = splitTableCells(line.text)
        if cells.count >= 2 {
          parsedRows.append((cells: cells, boundingBox: line.boundingBox))
        }
      }

      if parsedRows.count < 2 {
        continue
      }

      let rows = parsedRows.map(\.cells)
      var cells: [AnalysisTableCell] = []

      for (rowIndex, row) in parsedRows.enumerated() {
        for (columnIndex, value) in row.cells.enumerated() {
          cells.append(
            AnalysisTableCell(
              text: value,
              row: rowIndex,
              column: columnIndex,
              sourceImageIndex: sourceImageIndex,
              boundingBox: row.boundingBox
            )
          )
        }
      }

      tables.append(
        AnalysisTable(
          sourceImageIndex: sourceImageIndex,
          rows: rows,
          cells: cells,
          boundingBox: mergeBoundingBoxes(parsedRows.compactMap(\.boundingBox))
        )
      )
    }

    return tables.sorted { lhs, rhs in
      lhs.sourceImageIndex < rhs.sourceImageIndex
    }
  }

  static func inferStructuredData(from textBlocks: [AnalysisTextBlock]) -> AnalysisStructuredData {
    let lines = flattenTextLines(from: textBlocks)
    var entities: [AnalysisStructuredEntity] = []
    var fields: [String: String] = [:]
    var dedup = Set<String>()

    for line in lines {
      let text = line.text

      if let match = firstMatchGroups(using: fieldRegex, in: text), match.count >= 2 {
        let rawKey = match[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = match[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let key = StructuredDataNormalizer.normalizeFieldKey(rawKey)
        if !key.isEmpty && !value.isEmpty {
          fields[key] = value
          if StructuredDataNormalizer.isLikelyIdField(key) {
            appendEntityValue(
              type: "id",
              rawValue: value,
              line: line,
              entities: &entities,
              dedup: &dedup
            )
          }
        }
      }

      appendEntityMatches(
        using: phoneRegex,
        type: "phone",
        text: text,
        line: line,
        entities: &entities,
        dedup: &dedup
      )
      appendEntityMatches(
        using: emailRegex,
        type: "email",
        text: text,
        line: line,
        entities: &entities,
        dedup: &dedup
      )
      appendEntityMatches(
        using: dateRegex,
        type: "date",
        text: text,
        line: line,
        entities: &entities,
        dedup: &dedup
      )
      appendEntityMatches(
        using: amountRegex,
        type: "amount",
        text: text,
        line: line,
        entities: &entities,
        dedup: &dedup
      )
    }

    return AnalysisStructuredData(entities: entities, fields: fields)
  }

  private static func flattenTextLines(from textBlocks: [AnalysisTextBlock]) -> [TextLineEntry] {
    var lines: [TextLineEntry] = []

    for block in textBlocks {
      if !block.lines.isEmpty {
        for line in block.lines {
          let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
          if text.isEmpty {
            continue
          }
          lines.append(
            TextLineEntry(
              text: text,
              sourceImageIndex: block.sourceImageIndex,
              boundingBox: line.boundingBox ?? block.boundingBox
            )
          )
        }
        continue
      }

      let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty {
        continue
      }
      lines.append(
        TextLineEntry(
          text: text,
          sourceImageIndex: block.sourceImageIndex,
          boundingBox: block.boundingBox
        )
      )
    }

    return lines
  }

  private static func mergeBoundingBoxes(_ boxes: [AnalysisBoundingBox]) -> AnalysisBoundingBox? {
    guard !boxes.isEmpty else {
      return nil
    }

    let left = boxes.map(\.left).min() ?? 0
    let top = boxes.map(\.top).min() ?? 0
    let right = boxes.map { $0.left + $0.width }.max() ?? 0
    let bottom = boxes.map { $0.top + $0.height }.max() ?? 0

    return AnalysisBoundingBox(
      left: left,
      top: top,
      width: max(0, right - left),
      height: max(0, bottom - top)
    )
  }

  private static func splitTableCells(_ text: String) -> [String] {
    guard let regex = tableSplitRegex else {
      return [text]
    }

    let ns = text as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    let normalized = regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: fullRange,
      withTemplate: "\u{001F}"
    )

    return normalized
      .split(separator: "\u{001F}")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func firstMatchGroups(
    using regex: NSRegularExpression?,
    in text: String
  ) -> [String]? {
    guard let regex else {
      return nil
    }

    let ns = text as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else {
      return nil
    }

    var groups: [String] = []
    if match.numberOfRanges <= 1 {
      return groups
    }

    for index in 1..<match.numberOfRanges {
      let groupRange = match.range(at: index)
      if groupRange.location != NSNotFound {
        groups.append(ns.substring(with: groupRange))
      } else {
        groups.append("")
      }
    }

    return groups
  }

  private static func appendEntityMatches(
    using regex: NSRegularExpression?,
    type: String,
    text: String,
    line: TextLineEntry,
    entities: inout [AnalysisStructuredEntity],
    dedup: inout Set<String>
  ) {
    guard let regex else {
      return
    }

    let ns = text as NSString
    let range = NSRange(location: 0, length: ns.length)
    let matches = regex.matches(in: text, options: [], range: range)

    for match in matches {
      appendEntityValue(
        type: type,
        rawValue: ns.substring(with: match.range),
        line: line,
        entities: &entities,
        dedup: &dedup
      )
    }
  }

  private static func appendEntityValue(
    type: String,
    rawValue: String,
    line: TextLineEntry,
    entities: inout [AnalysisStructuredEntity],
    dedup: inout Set<String>
  ) {
    let normalizedValue = StructuredDataNormalizer.normalizeEntityValue(type: type, value: rawValue)
    if normalizedValue.isEmpty {
      return
    }

    let dedupValue = StructuredDataNormalizer.normalizedEntityDedupValue(
      type: type,
      normalizedValue: normalizedValue
    )
    if dedupValue.isEmpty {
      return
    }

    let dedupKey = "\(type)|\(line.sourceImageIndex)|\(dedupValue)"
    if dedup.contains(dedupKey) {
      return
    }
    dedup.insert(dedupKey)

    entities.append(
      AnalysisStructuredEntity(
        type: type,
        value: normalizedValue,
        sourceImageIndex: line.sourceImageIndex,
        boundingBox: line.boundingBox,
        confidence: nil
      )
    )
  }
}
