package com.preeternal.scanner.barcode

object BarcodeFormats {
  const val AZTEC = "aztec"
  const val CODABAR = "codabar"
  const val CODE_39 = "code39"
  const val CODE_93 = "code93"
  const val CODE_128 = "code128"
  const val DATA_MATRIX = "dataMatrix"
  const val EAN_8 = "ean8"
  const val EAN_13 = "ean13"
  const val ITF = "itf"
  const val PDF_417 = "pdf417"
  const val QR = "qr"
  const val UPC_A = "upca"
  const val UPC_E = "upce"
  const val UNKNOWN = "unknown"

  private val aliases = mapOf(
    "aztec" to AZTEC,
    "codabar" to CODABAR,
    "code39" to CODE_39,
    "code93" to CODE_93,
    "code128" to CODE_128,
    "datamatrix" to DATA_MATRIX,
    "ean8" to EAN_8,
    "ean13" to EAN_13,
    "itf" to ITF,
    "i2of5" to ITF,
    "interleaved2of5" to ITF,
    "pdf417" to PDF_417,
    "micropdf417" to PDF_417,
    "qr" to QR,
    "microqr" to QR,
    "upca" to UPC_A,
    "upce" to UPC_E
  )

  fun normalizeRequestedFormat(value: String): String? {
    val compact = value
      .trim()
      .lowercase()
      .replace("_", "")
      .replace("-", "")
      .replace(" ", "")

    return aliases[compact]
  }

  fun normalizeRequestedFormats(values: List<String>): Set<String> {
    if (values.isEmpty()) {
      return emptySet()
    }

    return values
      .mapNotNull(::normalizeRequestedFormat)
      .toSet()
  }
}
