import Foundation
#if canImport(OSLog)
import OSLog
#endif

// File-local logging shim to avoid cross-target dependencies.
private enum AMLog {
    private static func logger(for component: String?, file: String) -> Any? {
        #if canImport(OSLog)
        if #available(iOS 14.0, macOS 11.0, *) {
            let comp = component ?? ((file as NSString).lastPathComponent)
            return Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.awaremoney.app", category: comp)
        }
        #endif
        return nil
    }

    static func log(
        _ message: @autoclosure @escaping () -> String,
        component: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        #if canImport(OSLog)
        if #available(iOS 14.0, macOS 11.0, *), let logger = logger(for: component, file: file) as? Logger {
            logger.debug("\(message()) — \(function, privacy: .public):\(line)")
            return
        }
        #endif
        print("[\(component ?? "General")] \(message()) — \(function):\(line)")
    }

    static func always(
        _ message: @autoclosure @escaping () -> String,
        component: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        #if canImport(OSLog)
        if #available(iOS 14.0, macOS 11.0, *), let logger = logger(for: component, file: file) as? Logger {
            logger.notice("\(message()) — \(function, privacy: .public):\(line)")
            return
        }
        #endif
        print("[\(component ?? "General")] \(message()) — \(function):\(line)")
    }

    static func error(
        _ message: @autoclosure @escaping () -> String,
        component: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        #if canImport(OSLog)
        if #available(iOS 14.0, macOS 11.0, *), let logger = logger(for: component, file: file) as? Logger {
            logger.error("\(message()) — \(function, privacy: .public):\(line)")
            return
        }
        #endif
        fputs("ERROR [\(component ?? "General")] \(message()) — \(function):\(line)\n", stderr)
    }
}

// MARK: - QIF Statement Extractor
// Parses a QIF file into a CSV-like (rows, headers) pair compatible with the existing pipeline.
// This implementation strictly follows QIF's one-tag-per-line convention and avoids regex joins.

enum QIFStatementExtractor {
    /// Parses a QIF file and returns (rows, headers) using canonical headers:
    /// ["date", "description", "amount", "balance", "account"].
    /// Rows may leave some fields empty when not provided by the QIF source.
    static func parse(url: URL) throws -> ([[String]], [String]) {
        let component = "QIFExtractor"
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // Try UTF-8, fall back to ISO Latin 1
        let data = try Data(contentsOf: url)
        let text: String = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? (String(decoding: data, as: UTF8.self))

        // Normalize newlines to \n
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
          // Expand into logical per-tag lines to handle both multi-line and single-line-per-record QIFs
          let lines = Self.expandToLogicalLines(normalized)

        // Canonical headers expected by downstream CSV pipeline
        let headers = ["date", "description", "amount", "balance", "account"]
        var rows: [[String]] = []

        // Current record state (until '^')
        var curDate: Date? = nil
        var curPayee: String? = nil
        var curMemo: String? = nil
        var curAmount: Decimal? = nil
        var curBalance: Decimal? = nil
        var curAccount: String? = nil // QIF doesn't typically carry account per-transaction; reserved for future use

        // Optional: current !Type section (e.g., !Type:Bank, !Type:CCard)
        var currentType: String? = nil

        func resetRecord() {
            curDate = nil
            curPayee = nil
            curMemo = nil
            curAmount = nil
            curBalance = nil
            curAccount = nil
        }

        func finalizeRecord() {
            // Only emit if we have at least a date or amount or payee
            let hasContent = (curDate != nil) || (curAmount != nil) || ((curPayee?.isEmpty == false) || (curMemo?.isEmpty == false))
            guard hasContent else { return }
            let dateOut = curDate.map { Self.formatDate($0) } ?? ""
            let descOut: String = {
                let p = (curPayee?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                let m = (curMemo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                if !p.isEmpty && !m.isEmpty { return p + " — " + m }
                if !p.isEmpty { return p }
                if !m.isEmpty { return m }
                return ""
            }()
            let amountOut = curAmount.map { Self.decimalToString($0) } ?? ""
            let balanceOut = curBalance.map { Self.decimalToString($0) } ?? ""
            let accountOut = curAccount ?? ""
            rows.append([dateOut, descOut, amountOut, balanceOut, accountOut])
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            // Section/type headers (e.g., !Type:Bank) — track and skip
            if line.hasPrefix("!") {
                if line.lowercased().hasPrefix("!type:") {
                    currentType = String(line.dropFirst("!Type:".count))
                }
                continue
            }

            // Record terminator: '^'
            if line == "^" {
                finalizeRecord()
                resetRecord()
                continue
            }

            // One tag per line: first character is the tag, remainder is the value
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())

            switch tag {
            case "D":
                if let d = Self.parseQIFDate(value) { curDate = d }
            case "T":
                if let dec = Self.parseDecimal(value) { curAmount = dec }
            case "U":
                // Sometimes 'U' carries amount as well
                if curAmount == nil, let dec = Self.parseDecimal(value) { curAmount = dec }
            case "P":
                curPayee = value
            case "M":
                curMemo = value
            case "B":
                if let dec = Self.parseDecimal(value) { curBalance = dec }
            case "L":
                // Category; append to memo if present to preserve info
                let cat = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cat.isEmpty {
                    if let m = curMemo, !m.isEmpty { curMemo = m + " [" + cat + "]" }
                    else { curMemo = "[" + cat + "]" }
                }
            case "N":
                // Check/reference number — tack onto memo for diagnostics
                let num = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !num.isEmpty {
                    if let m = curMemo, !m.isEmpty { curMemo = m + " (#" + num + ")" }
                    else { curMemo = "#" + num }
                }
            case "S", "E", "$":
                // Split category/memo/amount — best-effort: append to memo so user can see detail in Review
                let chunk = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !chunk.isEmpty {
                    if let m = curMemo, !m.isEmpty { curMemo = m + " | " + chunk }
                    else { curMemo = chunk }
                }
            default:
                // Ignore other tags for now
                break
            }
        }

        // Flush last record if file did not end with '^'
        finalizeRecord()

        AMLog.log("QIF parsed — type=\(currentType ?? "unknown") rows=\(rows.count) file=\(url.lastPathComponent)", component: component)
        return (rows, headers)
    }

    // MARK: - Helpers

    private static func parseQIFDate(_ s: String) -> Date? {
        // QIF commonly uses MM/dd'yy (e.g., 12/31'25), but variants exist.
        // Try a handful of formats conservatively.
        let candidates = [
            "MM/dd''yy", // mm/dd'yy
            "MM/dd/yy",
            "MM/dd/yyyy",
            "M/d/yy",
            "M/d/yyyy",
            "dd/MM/yyyy",
            "d/M/yyyy",
            "yyyy-MM-dd"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in candidates {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        // Heuristic: if we see an apostrophe and two trailing digits, remove apostrophe and try again
        if s.contains("'") {
            let cleaned = s.replacingOccurrences(of: "'", with: "")
            for fmt in ["MM/dd/yy", "M/d/yy"] {
                df.dateFormat = fmt
                if let d = df.date(from: cleaned) { return d }
            }
        }
        return nil
    }

    private static func parseDecimal(_ s: String) -> Decimal? {
        var raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        // Parentheses indicate negative
        var negative = false
        if raw.hasPrefix("(") && raw.hasSuffix(")") {
            negative = true
            raw.removeFirst(); raw.removeLast()
        }
        // Remove currency/commas/spaces
        var cleaned = raw
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: " ", with: "")
        // Some exports include plus signs
        cleaned = cleaned.replacingOccurrences(of: "+", with: "")
        if negative && !cleaned.hasPrefix("-") { cleaned = "-" + cleaned }
        return Decimal(string: cleaned)
    }

    private static func decimalToString(_ d: Decimal) -> String {
        // Emit a plain, unformatted string to keep CSV-friendly semantics
        return NSDecimalNumber(decimal: d).stringValue
    }

    private static func formatDate(_ date: Date) -> String {
        // Normalize to MM/dd/yyyy to align with other extractors
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "MM/dd/yyyy"
        return df.string(from: date)
    }
    private static func expandToLogicalLines(_ input: String) -> [String] {
          // 1) Ensure '^' record terminators are on their own line even if they appear inline
          let isolated = input.replacingOccurrences(of: "^", with: "\n^\n")

          // 2) Split into physical lines, then optionally expand single-line records split by common delimiters
          let baseLines = isolated.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
          var out: [String] = []

          let knownTags: Set<Character> = ["D","T","U","P","M","B","L","N","S","E","$","!","^"]
          let delimiters: [Character] = ["\t", "|", ";"]

          func isTagToken(_ token: Substring) -> Bool {
              guard let first = token.first else { return false }
              if first == "!" || first == "^" { return true }
              return knownTags.contains(first)
          }

          for rawLine in baseLines {
              let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
              if line.isEmpty { continue }

              if line == "^" || line.hasPrefix("!") {
                  out.append(line)
                  continue
              }

              var splitApplied = false
              for delim in delimiters {
                  if line.contains(delim) {
                      let parts = line.split(separator: delim, omittingEmptySubsequences: true)
                      if !parts.isEmpty && parts.allSatisfy({ isTagToken($0) }) {
                          for p in parts {
                              let token = p.trimmingCharacters(in: .whitespaces)
                              if !token.isEmpty { out.append(token) }
                          }
                          splitApplied = true
                          break
                      }
                  }
              }

              if !splitApplied {
                  out.append(line)
              }
          }

          return out
      }
}

