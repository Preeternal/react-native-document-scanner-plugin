package com.preeternal.scanner.analysis

import com.preeternal.scanner.text.NormalizedBoundingBox
import com.preeternal.scanner.text.TextBlockResult

data class SemanticRegion(
  val type: String,
  val sourceImageIndex: Int,
  val boundingBox: NormalizedBoundingBox,
  val score: Double? = null,
  val text: String? = null
)

data class SemanticTableCell(
  val text: String,
  val row: Int,
  val column: Int,
  val sourceImageIndex: Int,
  val boundingBox: NormalizedBoundingBox?
)

data class SemanticTable(
  val sourceImageIndex: Int,
  val rows: List<List<String>>,
  val cells: List<SemanticTableCell>,
  val boundingBox: NormalizedBoundingBox?
)

data class SemanticStructuredEntity(
  val type: String,
  val value: String,
  val sourceImageIndex: Int,
  val boundingBox: NormalizedBoundingBox?,
  val confidence: Double? = null
)

data class SemanticStructuredData(
  val entities: List<SemanticStructuredEntity>,
  val fields: Map<String, String>
)

private data class TextLineEntry(
  val text: String,
  val sourceImageIndex: Int,
  val boundingBox: NormalizedBoundingBox?
)

object DocumentSemantics {
  private val tableSplitRegex = Regex("\\s{2,}|\\t|\\|")
  private val fieldRegex = Regex("^([A-Za-z0-9А-Яа-я _./-]{2,40})\\s*[:-]\\s*(.+)$")
  private val phoneRegex = Regex("(?:\\+?\\d[\\d\\s().-]{7,}\\d)")
  private val emailRegex = Regex("[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", RegexOption.IGNORE_CASE)
  private val dateRegex = Regex("\\b(?:\\d{1,2}[./-]\\d{1,2}[./-]\\d{2,4}|\\d{4}[./-]\\d{1,2}[./-]\\d{1,2})\\b")
  private val amountRegex = Regex("\\b(?:[$€£]\\s?)?\\d{1,3}(?:[ ,]\\d{3})*(?:[.,]\\d{2})\\b")

  fun inferRegions(textBlocks: List<TextBlockResult>): List<SemanticRegion> {
    return textBlocks.mapNotNull { block ->
      val box = block.boundingBox ?: return@mapNotNull null
      val bottom = box.top + box.height
      val type = when {
        box.top < 0.18 -> "header"
        bottom > 0.84 -> "footer"
        else -> "paragraph"
      }

      SemanticRegion(
        type = type,
        sourceImageIndex = block.sourceImageIndex,
        boundingBox = box,
        score = 0.6,
        text = block.text
      )
    }
  }

  fun inferTables(textBlocks: List<TextBlockResult>): List<SemanticTable> {
    val lines = flattenTextLines(textBlocks)
    val grouped = lines.groupBy { it.sourceImageIndex }

    return grouped.entries.mapNotNull { (sourceImageIndex, sourceLines) ->
      val parsedRows = sourceLines.mapNotNull { line ->
        val cells = line.text
          .split(tableSplitRegex)
          .map { it.trim() }
          .filter { it.isNotEmpty() }

        if (cells.size >= 2) {
          Pair(cells, line.boundingBox)
        } else {
          null
        }
      }

      if (parsedRows.size < 2) {
        return@mapNotNull null
      }

      val rows = parsedRows.map { it.first }
      val cells = parsedRows.flatMapIndexed { rowIndex, row ->
        row.first.mapIndexed { columnIndex, value ->
          SemanticTableCell(
            text = value,
            row = rowIndex,
            column = columnIndex,
            sourceImageIndex = sourceImageIndex,
            boundingBox = row.second
          )
        }
      }

      SemanticTable(
        sourceImageIndex = sourceImageIndex,
        rows = rows,
        cells = cells,
        boundingBox = mergeBoundingBoxes(parsedRows.mapNotNull { it.second })
      )
    }.sortedBy { it.sourceImageIndex }
  }

  fun inferStructuredData(textBlocks: List<TextBlockResult>): SemanticStructuredData {
    val lines = flattenTextLines(textBlocks)
    val entities = mutableListOf<SemanticStructuredEntity>()
    val fields = mutableMapOf<String, String>()
    val dedup = mutableSetOf<String>()

    for (line in lines) {
      val text = line.text

      fieldRegex.find(text)?.let { match ->
        val rawKey = match.groupValues.getOrNull(1)?.trim()?.lowercase().orEmpty()
        val value = match.groupValues.getOrNull(2)?.trim().orEmpty()
        val key = rawKey
          .replace(Regex("[^a-z0-9а-я]+"), "_")
          .trim('_')

        if (key.isNotEmpty() && value.isNotEmpty()) {
          fields[key] = value
        }
      }

      appendEntityMatches(phoneRegex, "phone", text, line, entities, dedup)
      appendEntityMatches(emailRegex, "email", text, line, entities, dedup)
      appendEntityMatches(dateRegex, "date", text, line, entities, dedup)
      appendEntityMatches(amountRegex, "amount", text, line, entities, dedup)
    }

    return SemanticStructuredData(
      entities = entities,
      fields = fields
    )
  }

  private fun appendEntityMatches(
    regex: Regex,
    type: String,
    text: String,
    line: TextLineEntry,
    entities: MutableList<SemanticStructuredEntity>,
    dedup: MutableSet<String>
  ) {
    regex.findAll(text).forEach { match ->
      val value = match.value.trim()
      if (value.isEmpty()) {
        return@forEach
      }

      val dedupKey = "$type|${line.sourceImageIndex}|$value"
      if (!dedup.add(dedupKey)) {
        return@forEach
      }

      entities.add(
        SemanticStructuredEntity(
          type = type,
          value = value,
          sourceImageIndex = line.sourceImageIndex,
          boundingBox = line.boundingBox
        )
      )
    }
  }

  private fun flattenTextLines(textBlocks: List<TextBlockResult>): List<TextLineEntry> {
    val lines = mutableListOf<TextLineEntry>()

    for (block in textBlocks) {
      if (block.lines.isNotEmpty()) {
        for (line in block.lines) {
          val normalizedText = line.text.trim()
          if (normalizedText.isEmpty()) {
            continue
          }

          lines.add(
            TextLineEntry(
              text = normalizedText,
              sourceImageIndex = block.sourceImageIndex,
              boundingBox = line.boundingBox ?: block.boundingBox
            )
          )
        }
      } else {
        val normalizedText = block.text.trim()
        if (normalizedText.isEmpty()) {
          continue
        }

        lines.add(
          TextLineEntry(
            text = normalizedText,
            sourceImageIndex = block.sourceImageIndex,
            boundingBox = block.boundingBox
          )
        )
      }
    }

    return lines
  }

  private fun mergeBoundingBoxes(boxes: List<NormalizedBoundingBox>): NormalizedBoundingBox? {
    if (boxes.isEmpty()) {
      return null
    }

    val left = boxes.minOf { it.left }
    val top = boxes.minOf { it.top }
    val right = boxes.maxOf { it.left + it.width }
    val bottom = boxes.maxOf { it.top + it.height }

    return NormalizedBoundingBox(
      left = left,
      top = top,
      width = (right - left).coerceAtLeast(0.0),
      height = (bottom - top).coerceAtLeast(0.0)
    )
  }
}
