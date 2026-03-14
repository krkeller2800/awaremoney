//  QIFStatementExtractor.swift
//  awaremoney
//
//  Stub extractor for QIF files. Converts parsed content into a CSV-like rows/headers pair
//  compatible with the existing StatementParser pipeline.

import Foundation

enum QIFImportError: Error { case unreadable, parseFailed }

enum QIFStatementExtractor {
    /// Parses a QIF file into (rows, headers) using a simple CSV-like schema.
    /// Supported tags: D (date), T (amount), P (payee), M (memo). Transactions end with '^'.
    static func parse(url: URL) throws -> ([[String]], [String]) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // Canonical headers expected by downstream parsers
        let headers = ["date", "description", "amount", "balance", "account"]

        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw QIFImportError.unreadable
        }

        // Split into lines preserving order; handle CRLF/CR/LF
        let lines: [Substring] = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })

        var rows: [[String]] = []
        var currentDate: String? = nil
        var currentAmount: String? = nil
        var currentPayee: String? = nil
        var currentMemo: String? = nil
        var currentAccountLabel: String? = nil

        func finalizeIfNeeded() {
            guard let d = currentDate, let a = currentAmount else { return }
            let desc: String = {
                let p = (currentPayee ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let m = (currentMemo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if p.isEmpty { return cleanDesc(m) }
                if m.isEmpty { return cleanDesc(p) }
                if p.caseInsensitiveCompare(m) == .orderedSame { return cleanDesc(p) }
                return cleanDesc(p + " — " + m)
            }()
            let dateOut = normalizeQIFDate(d)
            let amountOut = sanitizeAmount(currentAmount)
            let acct = (currentAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !dateOut.isEmpty && !amountOut.isEmpty {
                rows.append([dateOut, desc, amountOut, "", acct])
            }
            currentDate = nil
            currentAmount = nil
            currentPayee = nil
            currentMemo = nil
        }

        for lineSub in lines {
            let line = String(lineSub).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("!") {
                // Section headers like !Type:Bank, !Account, etc.
                if line.lowercased().hasPrefix("!type:") {
                    let type = String(line.dropFirst("!Type:".count))
                    currentAccountLabel = inferAccountLabel(fromTypeHeader: type)
                }
                continue
            }
            if line == "^" { finalizeIfNeeded(); continue }
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "D": currentDate = value
            case "T": currentAmount = value
            case "P": currentPayee = value
            case "M": currentMemo = value
            default: break // ignore other tags (N, L, S, E, $...)
            }
        }
        // Finalize if file doesn't end with '^'
        finalizeIfNeeded()

        return (rows, headers)
    }
}
// MARK: - Helpers

private func normalizeQIFDate(_ raw: String) -> String {
    // QIF dates are commonly like MM/DD'YY or MM/DD/YYYY. Remove apostrophes and normalize.
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    s = s.replacingOccurrences(of: "'", with: "/") // turn 12/31'25 into 12/31/25 to parse uniformly
    // Try several formats
    let fmts = ["MM/dd/yyyy", "M/d/yyyy", "MM/dd/yy", "M/d/yy"]
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(secondsFromGMT: 0)

    var parsed: Date? = nil
    for f in fmts {
        df.dateFormat = f
        if let d = df.date(from: s) { parsed = d; break }
    }
    if parsed == nil {
        // Handle two-digit years with apostrophe not converted (e.g., 12/31'25)
        if let apos = raw.firstIndex(of: "'") {
            let base = raw[..<apos]
            let year2 = raw[raw.index(after: apos)...]
            let composed = String(base + "/" + year2)
            for f in ["MM/dd/yy", "M/d/yy"] {
                df.dateFormat = f
                if let d = df.date(from: composed) { parsed = d; break }
            }
        }
    }
    if let d = parsed {
        df.dateFormat = "MM/dd/yyyy"
        return df.string(from: d)
    }
    return s // return as-is if parsing fails
}

private func sanitizeAmount(_ raw: String?) -> String {
    guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return "" }
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

private func inferAccountLabel(fromTypeHeader type: String) -> String? {
    let lower = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Common QIF types: Bank, Cash, CCard, Invst, Oth A, Oth L, Acct
    if lower.contains("bank") { return "checking" }
    if lower.contains("cash") { return "checking" }
    if lower.contains("ccard") { return "creditcard" }
    if lower.contains("invst") { return "brokerage" }
    if lower.contains("oth a") { return nil }
    if lower.contains("oth l") { return nil }
    return nil
}

