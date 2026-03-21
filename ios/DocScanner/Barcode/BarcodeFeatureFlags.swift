enum BarcodeFeatureFlags {
  #if DOCUMENT_SCANNER_ENABLE_BARCODE
  static let isEnabled = true
  #else
  static let isEnabled = false
  #endif
}
