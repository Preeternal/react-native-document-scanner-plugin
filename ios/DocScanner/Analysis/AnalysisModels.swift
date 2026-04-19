import Foundation

struct AnalysisBarcode {
  let value: String
  let format: String
  let sourceImageIndex: Int
  let boundingBox: AnalysisBoundingBox?
}

struct AnalysisBoundingBox {
  let left: Double
  let top: Double
  let width: Double
  let height: Double
}

struct AnalysisTextLine {
  let text: String
  let sourceImageIndex: Int
  let boundingBox: AnalysisBoundingBox?
  let confidence: Double?
}

struct AnalysisTextBlock {
  let text: String
  let sourceImageIndex: Int
  let boundingBox: AnalysisBoundingBox?
  let confidence: Double?
  let lines: [AnalysisTextLine]
}

struct AnalysisRegion {
  let type: String
  let sourceImageIndex: Int
  let boundingBox: AnalysisBoundingBox
  let score: Double?
  let text: String?
}

struct AnalysisTableCell {
  let text: String
  let row: Int
  let column: Int
  let sourceImageIndex: Int
  let boundingBox: AnalysisBoundingBox?
}

struct AnalysisTable {
  let sourceImageIndex: Int
  let rows: [[String]]
  let cells: [AnalysisTableCell]
  let boundingBox: AnalysisBoundingBox?
}

struct AnalysisStructuredEntity {
  let type: String
  let value: String
  let sourceImageIndex: Int
  let boundingBox: AnalysisBoundingBox?
  let confidence: Double?
}

struct AnalysisStructuredData {
  let entities: [AnalysisStructuredEntity]
  let fields: [String: String]
}
