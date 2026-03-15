//  OFXStatementExtractor.swift
//  awaremoney
//
//  Minimal extractor for OFX/QFX files. Parses BANKTRANLIST/CCSTMTTRNRS transactions
//  and converts them into CSV-like (rows, headers) compatible with existing parsers.

import Foundation

enum OFXImportError: Error { case unreadable, parseFailed }

enum OFXStatementExtractor {
    /// Parses an OFX/QFX file into (rows, headers) using a simple CSV-like schema.
    /// Extracts transactions found inside BANKTRANLIST (bank) and CCSTMTTRNRS (credit card) sections.
    static func parse(url: URL) throws -> ([[String]], [String]) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url), var raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw OFXImportError.unreadable
        }

        // Strip any QFX/OFX preamble before the first '<'
        if let firstTagIndex = raw.firstIndex(of: "<") {
            raw = String(raw[firstTagIndex...])
        }

        // Canonical headers expected by CSV pipeline
        let headers = ["date", "description", "amount", "balance", "account"]
        var rows: [[String]] = []

        // Streaming parse: split by '<' and process tokens of the form TAG>value
        // This works for both SGML-style (no explicit closing tags on leaf nodes) and XML-style.
        var currentAccount: String? = nil
        var inTransaction = false
        var pendingDate: String? = nil
        var pendingAmount: String? = nil
        var pendingName: String? = nil
        var pendingMemo: String? = nil

        func finalizeTransactionIfNeeded() {
            guard inTransaction else { return }
            // Build description
            let name = (pendingName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let memo = (pendingMemo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let desc: String = {
                if name.isEmpty { return cleanDesc(memo) }
                if memo.isEmpty { return cleanDesc(name) }
                if name.caseInsensitiveCompare(memo) == .orderedSame { return cleanDesc(name) }
                return cleanDesc(name + " — " + memo)
            }()
            let date = normalizeOFXDate(pendingDate)
            let amount = sanitizeAmount(pendingAmount)
            let account = normalizeAccount(currentAccount)
            if !(date.isEmpty) && !(amount.isEmpty) {
                rows.append([date, desc, amount, "", account ?? ""])
            }
            // Reset transaction state
            inTransaction = false
            pendingDate = nil
            pendingAmount = nil
            pendingName = nil
            pendingMemo = nil
        }

        // Split into tokens by '<'
        let tokens = raw.split(separator: "<", omittingEmptySubsequences: true)
        for tokSub in tokens {
            let token = String(tokSub)
            // token typically like: TAG>value... or /TAG> ...
            // Separate tag and value at first '>'
            guard let gt = token.firstIndex(of: ">") else { continue }
            let tagRaw = token[..<gt]
            var value = String(token[token.index(after: gt)...])
            // Trim trailing closing tag markers from value if present (e.g., "value</TAG")
            if let closeRange = value.range(of: "</") {
                value = String(value[..<closeRange.lowerBound])
            }
            let tag = tagRaw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

            switch tag {
            case "STMTTRN":
                // If a previous transaction was open but not explicitly closed, finalize it defensively
                if inTransaction { finalizeTransactionIfNeeded() }
                inTransaction = true
                pendingDate = nil; pendingAmount = nil; pendingName = nil; pendingMemo = nil
            case "/STMTTRN":
                finalizeTransactionIfNeeded()
            case "DTPOSTED":
                if inTransaction { pendingDate = trimmedValue }
            case "TRNAMT":
                if inTransaction { pendingAmount = trimmedValue }
            case "NAME":
                if inTransaction && pendingName == nil { pendingName = trimmedValue } // prefer first NAME
            case "MEMO":
                if inTransaction { pendingMemo = trimmedValue }
            case "ACCTID", "CARDNUM":
                // Track current account context; use last4 when possible
                currentAccount = trimmedValue
            default:
                break
            }
        }
        // Finalize if file ended inside a transaction
        if inTransaction { finalizeTransactionIfNeeded() }

        return (rows, headers)
    }
}
// MARK: - Helpers

private func normalizeOFXDate(_ raw: String?) -> String {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
    // Extract leading digits (ignore timezone/suffix like [0:GMT])
    let digits = raw.prefix { $0.isNumber }
    let s = String(digits)
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(secondsFromGMT: 0)
    var parsed: Date? = nil
    if s.count >= 14 {
        df.dateFormat = "yyyyMMddHHmmss"
        parsed = df.date(from: String(s.prefix(14)))
    }
    if parsed == nil && s.count >= 8 {
        df.dateFormat = "yyyyMMdd"
        parsed = df.date(from: String(s.prefix(8)))
    }
    if let d = parsed {
        df.dateFormat = "MM/dd/yyyy"
        return df.string(from: d)
    }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func sanitizeAmount(_ raw: String?) -> String {
    guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return "" }
    // OFX amounts are usually simple decimals with optional sign; still strip currency and commas defensively
    s = s.replacingOccurrences(of: ",", with: "")
         .replacingOccurrences(of: "$", with: "")
         .replacingOccurrences(of: " ", with: "")
    return s
}

private func cleanDesc(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "\n", with: " ")
             .replacingOccurrences(of: "\r", with: " ")
             .replacingOccurrences(of: "\t", with: " ")
             .trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count > 120 { t = String(t.prefix(120)) }
    return t
}

private func normalizeAccount(_ s: String?) -> String? {
    guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    let digits = s.filter { $0.isNumber }
    if digits.count >= 4 { return String(digits.suffix(4)) }
    return s
}

