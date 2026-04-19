import Foundation

enum DocScannerDebugLog {
  private static var isEnabled: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["DOCUMENT_SCANNER_DEBUG_LOGS"] == "1" ||
      env["DOCUMENT_SCANNER_TRACE_LOGS"] == "1"
  }

  private static var isTraceEnabled: Bool {
    guard isEnabled else {
      return false
    }

    return ProcessInfo.processInfo.environment["DOCUMENT_SCANNER_TRACE_LOGS"] == "1"
  }

  static func log(_ scope: String, _ message: @autoclosure () -> String) {
    guard isEnabled else {
      return
    }

    NSLog("[DocumentScanner][\(scope)] \(message())")
  }

  static func trace(_ scope: String, _ message: @autoclosure () -> String) {
    guard isTraceEnabled else {
      return
    }

    NSLog("[DocumentScanner][\(scope)][trace] \(message())")
  }
}
