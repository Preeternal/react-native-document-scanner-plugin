import Foundation

enum StructuredDataNormalizer {
  private static let fieldKeySanitizeRegex = compileRegex(
    name: "fieldKeySanitizeRegex",
    pattern: "[^a-z0-9а-я]+",
    options: []
  )

  private static let currencyCodeRegex = compileRegex(
    name: "currencyCodeRegex",
    pattern: "\\b(usd|eur|gbp|uah|rub|brl)\\b",
    options: [.caseInsensitive]
  )

  private static let numericCandidateRegex = compileRegex(
    name: "numericCandidateRegex",
    pattern: "[-+]?\\d[\\d.,\\s]*\\d|[-+]?\\d",
    options: []
  )

  private static let nonIdSymbolRegex = compileRegex(
    name: "nonIdSymbolRegex",
    pattern: "[^A-Z0-9_-]",
    options: []
  )

  private static let nonIdDedupRegex = compileRegex(
    name: "nonIdDedupRegex",
    pattern: "[^A-Z0-9]",
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
      NSLog("[DocumentScanner][StructuredDataNormalizer] regex compile failed name=\(name) error=\(error.localizedDescription)")
      return nil
    }
  }

  private static let idFieldHints: Set<String> = [
    "id",
    "tracking",
    "reference",
    "ref",
    "invoice",
    "order",
    "shipment",
    "waybill",
    "awb",
    "consignment",
    "номер"
  ]

  static func normalizeFieldKey(_ raw: String) -> String {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let fieldKeySanitizeRegex else {
      return normalized
    }

    let ns = normalized as NSString
    let range = NSRange(location: 0, length: ns.length)
    let replaced = fieldKeySanitizeRegex.stringByReplacingMatches(
      in: normalized,
      options: [],
      range: range,
      withTemplate: "_"
    )
    return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
  }

  static func isLikelyIdField(_ normalizedFieldKey: String) -> Bool {
    if normalizedFieldKey.isEmpty {
      return false
    }

    for hint in idFieldHints {
      if normalizedFieldKey == hint ||
        normalizedFieldKey.hasPrefix("\(hint)_") ||
        normalizedFieldKey.hasSuffix("_\(hint)") ||
        normalizedFieldKey.contains("_\(hint)_") {
        return true
      }
    }

    return false
  }

  static func normalizeEntityValue(type: String, value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return ""
    }

    switch type {
    case "phone":
      return normalizePhone(trimmed)
    case "email":
      return trimmed.lowercased()
    case "date":
      return normalizeDate(trimmed)
    case "amount":
      return normalizeAmount(trimmed)
    case "id":
      return normalizeId(trimmed)
    default:
      return normalizeWhitespace(trimmed)
    }
  }

  static func normalizedEntityDedupValue(type: String, normalizedValue: String) -> String {
    let value = normalizedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty {
      return ""
    }

    switch type {
    case "phone":
      return value.filter(\.isNumber)
    case "email":
      return value.lowercased()
    case "id":
      return replaceRegexMatches(
        in: value.uppercased(),
        regex: nonIdDedupRegex,
        with: ""
      )
    case "amount", "date":
      return value
    default:
      return normalizeWhitespace(value).lowercased()
    }
  }

  private static func normalizePhone(_ value: String) -> String {
    let hasPlusPrefix = value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+")
    let digits = value.filter(\.isNumber)
    if digits.count < 8 {
      return normalizeWhitespace(value)
    }
    return hasPlusPrefix ? "+\(digits)" : digits
  }

  private static func normalizeId(_ value: String) -> String {
    let upper = value.uppercased()
    let noWhitespace = upper
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
    let compact = replaceRegexMatches(
      in: noWhitespace,
      regex: nonIdSymbolRegex,
      with: ""
    )
    if compact.isEmpty {
      return upper.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return compact
  }

  private static func normalizeDate(_ value: String) -> String {
    let separators = CharacterSet(charactersIn: "./-")
    let parts = value.components(separatedBy: separators).filter { !$0.isEmpty }
    if parts.count != 3 {
      return value
    }

    if parts[0].count == 4,
       let year = Int(parts[0]),
       let month = Int(parts[1]),
       let day = Int(parts[2]),
       isValidDate(year: year, month: month, day: day) {
      return formatIsoDate(year: year, month: month, day: day)
    }

    guard let first = Int(parts[0]),
          let second = Int(parts[1]),
          let rawYear = Int(parts[2]) else {
      return value
    }

    let year = normalizeYear(rawYear)
    let month: Int
    let day: Int

    if first > 12, (1...12).contains(second) {
      month = second
      day = first
    } else if second > 12, (1...12).contains(first) {
      month = first
      day = second
    } else {
      month = second
      day = first
    }

    guard isValidDate(year: year, month: month, day: day) else {
      return value
    }

    return formatIsoDate(year: year, month: month, day: day)
  }

  private static func normalizeAmount(_ value: String) -> String {
    let currency = detectCurrency(value)
    guard let numericCandidate = firstMatch(in: value, regex: numericCandidateRegex)?
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "\u{00A0}", with: "") else {
      return normalizeWhitespace(value)
    }

    guard let normalizedNumber = normalizeNumericString(numericCandidate) else {
      return normalizeWhitespace(value)
    }

    if let currency {
      return "\(currency) \(normalizedNumber)"
    }

    return normalizedNumber
  }

  private static func detectCurrency(_ value: String) -> String? {
    if value.contains("$") {
      return "USD"
    }
    if value.contains("€") {
      return "EUR"
    }
    if value.contains("£") {
      return "GBP"
    }

    guard let code = firstMatch(in: value, regex: currencyCodeRegex) else {
      return nil
    }
    return code.uppercased()
  }

  private static func normalizeNumericString(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty {
      return nil
    }

    let lastDot = value.lastIndex(of: ".")
    let lastComma = value.lastIndex(of: ",")

    let decimalSeparator: Character? = {
      if let lastDot, let lastComma {
        return lastDot > lastComma ? "." : ","
      }
      if lastDot != nil {
        return inferSingleSeparatorAsDecimal(in: value, separator: ".")
      }
      if lastComma != nil {
        return inferSingleSeparatorAsDecimal(in: value, separator: ",")
      }
      return nil
    }()

    var normalized = ""
    for char in value {
      if char.isNumber {
        normalized.append(char)
        continue
      }
      if (char == "+" || char == "-"), normalized.isEmpty {
        normalized.append(char)
        continue
      }
      if let decimalSeparator, char == decimalSeparator {
        normalized.append(".")
      }
    }

    if normalized.isEmpty || normalized == "+" || normalized == "-" {
      return nil
    }

    let decimal = NSDecimalNumber(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    if decimal == NSDecimalNumber.notANumber {
      return nil
    }

    return decimal.stringValue
  }

  private static func inferSingleSeparatorAsDecimal(in value: String, separator: Character) -> Character? {
    let count = value.filter { $0 == separator }.count
    if count != 1 {
      return nil
    }

    guard let separatorIndex = value.firstIndex(of: separator),
          separatorIndex != value.startIndex else {
      return nil
    }

    let nextIndex = value.index(after: separatorIndex)
    if nextIndex >= value.endIndex {
      return nil
    }

    let digitsAfter = value[nextIndex...].filter(\.isNumber).count
    return (1...2).contains(digitsAfter) ? separator : nil
  }

  private static func normalizeWhitespace(_ value: String) -> String {
    return value
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func normalizeYear(_ value: Int) -> Int {
    if value >= 100 {
      return value
    }
    return value <= 69 ? 2000 + value : 1900 + value
  }

  private static func isValidDate(year: Int, month: Int, day: Int) -> Bool {
    if !(1900...2100).contains(year) {
      return false
    }
    if !(1...12).contains(month) {
      return false
    }
    if day < 1 {
      return false
    }

    let daysInMonth: Int
    switch month {
    case 1, 3, 5, 7, 8, 10, 12:
      daysInMonth = 31
    case 4, 6, 9, 11:
      daysInMonth = 30
    case 2:
      daysInMonth = isLeapYear(year) ? 29 : 28
    default:
      daysInMonth = 0
    }

    return day <= daysInMonth
  }

  private static func isLeapYear(_ year: Int) -> Bool {
    return (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
  }

  private static func formatIsoDate(year: Int, month: Int, day: Int) -> String {
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  private static func firstMatch(in text: String, regex: NSRegularExpression?) -> String? {
    guard let regex else {
      return nil
    }
    let ns = text as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else {
      return nil
    }
    return ns.substring(with: match.range)
  }

  private static func replaceRegexMatches(
    in text: String,
    regex: NSRegularExpression?,
    with replacement: String
  ) -> String {
    guard let regex else {
      return text
    }
    let ns = text as NSString
    let range = NSRange(location: 0, length: ns.length)
    return regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: range,
      withTemplate: replacement
    )
  }
}
