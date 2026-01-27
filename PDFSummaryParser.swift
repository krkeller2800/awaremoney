import Foundation

private let LOG_COMPONENT = "PDFSummaryParser"

struct PDFSummaryParser: StatementParser {
    static var id: String { "pdf.summary" }

    func canParse(headers: [String]) -> Bool {
        // Expect normalized headers from PDFStatementExtractor: date, description, amount, balance
        let lower = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard lower.contains("date"), lower.contains("description"), lower.contains("amount"), lower.contains(where: { $0.contains("balance") }) else {
            return false
        }
        // Heuristic: look for summary description tokens in the first few rows if available
        // The ImportViewModel passes all rows, but we can't see them here; canParse is headers-only.
        // We'll be permissive here and rely on parse() to validate rows strictly.
        return true
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        // Build a header map for robust access
        let map = headerMap(headers)
        var balances: [StagedBalance] = []

        // Helper to parse dates in the normalized format from PDFStatementExtractor (MM/dd/yyyy)
        func parseDate(_ s: String) -> Date? {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "MM/dd/yyyy"
            return df.date(from: s)
        }

        // Collect only rows whose description clearly indicates statement summary lines
        for row in rows {
            let desc = value(row, map, key: "description")?.lowercased() ?? ""
            guard desc.contains("statement beginning balance") || desc.contains("statement ending balance") else { continue }
            guard let dateStr = value(row, map, key: "date"), let date = parseDate(dateStr) else { continue }

            // Prefer the explicit balance column if present; otherwise fall back to amount (should be 0)
            let balStr = value(row, map, key: "balance") ?? value(row, map, key: "amount")
            guard let balRaw = balStr else { continue }
            let cleaned = balRaw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            guard let dec = Decimal(string: cleaned) else { continue }

            balances.append(StagedBalance(asOfDate: date, balance: dec))
        }

        AMLogging.always("PDFSummaryParser — parsed balances: \(balances.count)", component: LOG_COMPONENT)

        // If we didn't find any summary rows, fail so other parsers can try (e.g., BankCSVParser)
        if balances.isEmpty {
            throw ImportError.unknownFormat
        }

        return StagedImport(
            parserId: Self.id,
            sourceFileName: "Unknown.pdf",
            suggestedAccountType: nil,
            transactions: [],
            holdings: [],
            balances: balances
        )
    }

    // MARK: - Helpers

    private func headerMap(_ headers: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (idx, h) in headers.enumerated() {
            let key = h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            map[key] = idx
        }
        return map
    }

    private func value(_ row: [String], _ map: [String: Int], key: String) -> String? {
        if let idx = map.first(where: { $0.key.contains(key) })?.value, idx < row.count {
            let v = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        return nil
    }
}
