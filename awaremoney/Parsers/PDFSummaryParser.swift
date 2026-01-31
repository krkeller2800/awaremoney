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

        func normalizedLabel(_ raw: String?) -> String? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
            if s.contains("checking") { return "checking" }
            if s.contains("savings") { return "savings" }
            // Recognize brokerage/investment-related labels
            if s.contains("brokerage") || s.contains("investment") || s.contains("ira") || s.contains("roth") || s.contains("401k") || s.contains("stock") || s.contains("options") || s.contains("portfolio") {
                return "brokerage"
            }
            return nil
        }

        // Collect only rows whose description clearly indicates statement summary lines
        for row in rows {
            let desc = value(row, map, key: "description")?.lowercased() ?? ""
            let isStatementSummary = desc.contains("statement beginning balance") || desc.contains("statement ending balance")
            let isLoanSummary = desc.contains("beginning balance") || desc.contains("ending balance") || desc.contains("current amount due") || desc.contains("amount due") || desc.contains("payment due") || desc.contains("principal balance") || desc.contains("outstanding principal")
            guard isStatementSummary || isLoanSummary else { continue }
            guard let dateStr = value(row, map, key: "date"), let date = parseDate(dateStr) else { continue }

            // Prefer the explicit balance column if present; otherwise fall back to amount (should be 0)
            let balStr = value(row, map, key: "balance") ?? value(row, map, key: "amount")
            guard let balRaw = balStr else { continue }
            let cleaned = balRaw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            guard let dec = Decimal(string: cleaned) else { continue }

            var sb = StagedBalance(asOfDate: date, balance: dec)
            // Prefer explicit Account column, fallback to description text
            var accountKey = normalizedLabel(value(row, map, key: "account")) ?? normalizedLabel(desc)
            // Bias to loan when loan phrases are present
            let loanPhrases = ["loan", "mortgage", "principal balance", "outstanding principal", "amount due", "payment due"]
            if accountKey == nil {
                let lower = desc
                if loanPhrases.contains(where: { lower.contains($0) }) {
                    accountKey = "loan"
                }
            }
            sb.sourceAccountLabel = accountKey
            balances.append(sb)
        }

        AMLogging.always("PDFSummaryParser — parsed balances: \(balances.count)", component: LOG_COMPONENT)

        // If we didn't find any summary rows, surface a helpful message
        if balances.isEmpty {
            throw ImportError.parseFailure("We couldn't detect statement balances in this PDF. Try Transactions mode to import activity, or export a CSV for best results.")
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

