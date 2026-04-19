package com.preeternal.scanner.analysis

import java.math.BigDecimal
import java.util.Locale

object StructuredDataNormalizer {
  private val fieldKeySanitizeRegex = Regex("[^a-z0-9а-я]+")
  private val whitespaceRegex = Regex("\\s+")
  private val dateYmdRegex = Regex("^\\s*(\\d{4})[./-](\\d{1,2})[./-](\\d{1,2})\\s*$")
  private val dateDmyRegex = Regex("^\\s*(\\d{1,2})[./-](\\d{1,2})[./-](\\d{2,4})\\s*$")
  private val numericCandidateRegex = Regex("[-+]?\\d[\\d.,\\s]*\\d|[-+]?\\d")
  private val currencyCodeRegex = Regex("\\b(usd|eur|gbp|uah|rub|brl)\\b", RegexOption.IGNORE_CASE)
  private val nonIdSymbolRegex = Regex("[^A-Z0-9_-]")
  private val nonIdDedupRegex = Regex("[^A-Z0-9]")

  private val idFieldHints = setOf(
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
  )

  fun normalizeFieldKey(raw: String): String {
    return raw
      .trim()
      .lowercase(Locale.ROOT)
      .replace(fieldKeySanitizeRegex, "_")
      .trim('_')
  }

  fun isLikelyIdField(normalizedFieldKey: String): Boolean {
    if (normalizedFieldKey.isEmpty()) {
      return false
    }
    return idFieldHints.any { hint ->
      normalizedFieldKey == hint ||
        normalizedFieldKey.startsWith("${hint}_") ||
        normalizedFieldKey.endsWith("_$hint") ||
        normalizedFieldKey.contains("_${hint}_")
    }
  }

  fun normalizeEntityValue(type: String, rawValue: String): String {
    val trimmed = rawValue.trim()
    if (trimmed.isEmpty()) {
      return ""
    }

    return when (type) {
      "phone" -> normalizePhone(trimmed)
      "email" -> trimmed.lowercase(Locale.ROOT)
      "date" -> normalizeDate(trimmed)
      "amount" -> normalizeAmount(trimmed)
      "id" -> normalizeId(trimmed)
      else -> normalizeWhitespace(trimmed)
    }
  }

  fun normalizedEntityDedupValue(type: String, normalizedValue: String): String {
    val value = normalizedValue.trim()
    if (value.isEmpty()) {
      return ""
    }

    return when (type) {
      "phone" -> value.filter { it.isDigit() }
      "email" -> value.lowercase(Locale.ROOT)
      "id" -> value.uppercase(Locale.ROOT).replace(nonIdDedupRegex, "")
      "amount", "date" -> value
      else -> normalizeWhitespace(value).lowercase(Locale.ROOT)
    }
  }

  private fun normalizeWhitespace(value: String): String {
    return value.trim().replace(whitespaceRegex, " ")
  }

  private fun normalizePhone(value: String): String {
    val hasPlusPrefix = value.trimStart().startsWith("+")
    val digits = value.filter { it.isDigit() }
    if (digits.length < 8) {
      return normalizeWhitespace(value)
    }
    return if (hasPlusPrefix) "+$digits" else digits
  }

  private fun normalizeId(value: String): String {
    val compact = value
      .trim()
      .uppercase(Locale.ROOT)
      .replace(whitespaceRegex, "")
      .replace(nonIdSymbolRegex, "")
    if (compact.isEmpty()) {
      return value.trim().uppercase(Locale.ROOT)
    }
    return compact
  }

  private fun normalizeDate(value: String): String {
    dateYmdRegex.matchEntire(value)?.let { match ->
      val year = match.groupValues[1].toIntOrNull() ?: return@let
      val month = match.groupValues[2].toIntOrNull() ?: return@let
      val day = match.groupValues[3].toIntOrNull() ?: return@let
      if (isValidDate(year, month, day)) {
        return formatIsoDate(year, month, day)
      }
    }

    dateDmyRegex.matchEntire(value)?.let { match ->
      val first = match.groupValues[1].toIntOrNull() ?: return@let
      val second = match.groupValues[2].toIntOrNull() ?: return@let
      val year = normalizeYear(match.groupValues[3].toIntOrNull() ?: return@let)

      val (month, day) = when {
        first > 12 && second in 1..12 -> second to first
        second > 12 && first in 1..12 -> first to second
        else -> second to first
      }

      if (isValidDate(year, month, day)) {
        return formatIsoDate(year, month, day)
      }
    }

    return value
  }

  private fun normalizeAmount(value: String): String {
    val currency = detectCurrency(value)
    val numericCandidate = numericCandidateRegex.find(value)?.value
      ?.replace(whitespaceRegex, "")
      ?: return normalizeWhitespace(value)

    val normalizedNumber = normalizeNumericString(numericCandidate) ?: return normalizeWhitespace(value)
    return if (currency != null) {
      "$currency $normalizedNumber"
    } else {
      normalizedNumber
    }
  }

  private fun detectCurrency(value: String): String? {
    if (value.contains("$")) {
      return "USD"
    }
    if (value.contains("€")) {
      return "EUR"
    }
    if (value.contains("£")) {
      return "GBP"
    }

    val code = currencyCodeRegex.find(value)?.groupValues?.getOrNull(1)?.uppercase(Locale.ROOT)
    return code
  }

  private fun normalizeNumericString(raw: String): String? {
    val value = raw.trim()
    if (value.isEmpty()) {
      return null
    }

    val lastDot = value.lastIndexOf('.')
    val lastComma = value.lastIndexOf(',')

    val decimalSeparator: Char? = when {
      lastDot >= 0 && lastComma >= 0 -> if (lastDot > lastComma) '.' else ','
      lastDot >= 0 -> inferSingleSeparatorAsDecimal(value, '.')
      lastComma >= 0 -> inferSingleSeparatorAsDecimal(value, ',')
      else -> null
    }

    val normalized = buildString(value.length) {
      value.forEach { char ->
        when {
          char.isDigit() -> append(char)
          (char == '+' || char == '-') && isEmpty() -> append(char)
          decimalSeparator != null && char == decimalSeparator -> append('.')
        }
      }
    }

    if (normalized.isEmpty() || normalized == "-" || normalized == "+") {
      return null
    }

    return try {
      BigDecimal(normalized).stripTrailingZeros().toPlainString()
    } catch (_: NumberFormatException) {
      null
    }
  }

  private fun inferSingleSeparatorAsDecimal(value: String, separator: Char): Char? {
    val count = value.count { it == separator }
    if (count != 1) {
      return null
    }

    val index = value.indexOf(separator)
    if (index <= 0 || index >= value.length - 1) {
      return null
    }

    val digitsAfter = value.substring(index + 1).count { it.isDigit() }
    return if (digitsAfter in 1..2) separator else null
  }

  private fun normalizeYear(value: Int): Int {
    if (value >= 100) {
      return value
    }
    return if (value <= 69) {
      2000 + value
    } else {
      1900 + value
    }
  }

  private fun formatIsoDate(year: Int, month: Int, day: Int): String {
    return "%04d-%02d-%02d".format(Locale.US, year, month, day)
  }

  private fun isValidDate(year: Int, month: Int, day: Int): Boolean {
    if (year !in 1900..2100) {
      return false
    }
    if (month !in 1..12) {
      return false
    }
    if (day < 1) {
      return false
    }

    val daysInMonth = when (month) {
      1, 3, 5, 7, 8, 10, 12 -> 31
      4, 6, 9, 11 -> 30
      2 -> if (isLeapYear(year)) 29 else 28
      else -> 0
    }

    return day <= daysInMonth
  }

  private fun isLeapYear(year: Int): Boolean {
    return (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0)
  }
}
