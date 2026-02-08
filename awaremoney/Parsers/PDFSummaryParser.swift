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

        func decimalPlaces(in token: String) -> Int {
            if let dot = token.firstIndex(of: ".") {
                return token.distance(from: token.index(after: dot), to: token.endIndex)
            }
            return 0
        }

        func extractAPRAndScale(from text: String) -> (value: Decimal, scale: Int)? {
            // Match patterns like "Interest Rate 8.250%" or "APR 6.99"
            // Capture the numeric token so we can determine scale precisely
            let pattern = #"(?:(?:interest\s*rate)|apr)[^0-9%]{0,64}([0-9]{1,3}(?:\.[0-9]{1,4})?)\s*%?"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let lower = text.lowercased()
            let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            if let match = regex.firstMatch(in: lower, options: [], range: range), match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: lower) {
                let token = String(lower[r])
                guard var val = Decimal(string: token) else { return nil }
                let scale = decimalPlaces(in: token)
                if val > 1 { val /= 100 } // convert percent to fraction when given as percent number
                return (val, scale)
            }
            return nil
        }

        // Pre-scan all rows for a global APR/interest rate token present in summary blocks
        let globalAPR: (value: Decimal, scale: Int)? = {
            for row in rows {
                let joined = row.joined(separator: " ")
                if let found = extractAPRAndScale(from: joined) { return found }
            }
            return nil
        }()
        AMLogging.log("PDFSummaryParser: globalAPR=\(String(describing: globalAPR))", component: LOG_COMPONENT)

        // Pre-scan all rows for credit card context indicators
        let hasCreditCardIndicators: Bool = {
            let tokens = [
                "new balance",
                "previous balance",
                "minimum payment due",
                "payment due date",
                "credit limit",
                "available credit",
                "card ending"
            ]
            for row in rows {
                let joined = row.joined(separator: " ").lowercased()
                if tokens.contains(where: { joined.contains($0) }) {
                    return true
                }
            }
            return false
        }()
        AMLogging.log("PDFSummaryParser: ccIndicators=\(hasCreditCardIndicators)", component: LOG_COMPONENT)

        // Collect only rows whose description clearly indicates statement summary lines
        for row in rows {
            let desc = value(row, map, key: "description")?.lowercased() ?? ""
            let lower = desc
            // Detect credit-card style summary lines
            let isCreditCardSummary = lower.contains("new balance")
                || lower.contains("previous balance")
                || lower.contains("minimum payment due")
                || lower.contains("payment due date")
                || lower.contains("credit limit")
                || lower.contains("available credit")
                || lower.contains("card ending")

            let isStatementSummary = lower.contains("statement beginning balance") || lower.contains("statement ending balance")
            let isLoanSummary = lower.contains("beginning balance") || lower.contains("ending balance") || lower.contains("current amount due") || lower.contains("amount due") || lower.contains("payment due") || lower.contains("principal balance") || lower.contains("outstanding principal")
            guard isStatementSummary || isLoanSummary || isCreditCardSummary else { continue }
            guard let dateStr = value(row, map, key: "date"), let date = parseDate(dateStr) else { continue }

            // Prefer the explicit balance column if present; otherwise fall back to amount (should be 0)
            let balStr = value(row, map, key: "balance") ?? value(row, map, key: "amount")
            guard let balRaw = balStr else { continue }
            let cleaned = balRaw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            guard let dec = Decimal(string: cleaned) else { continue }

            var sb = StagedBalance(asOfDate: date, balance: dec)
            if let aprInfo = extractAPRAndScale(from: desc) {
                sb.interestRateAPR = aprInfo.value
                sb.interestRateScale = aprInfo.scale
                AMLogging.log("Row APR extracted from description: apr=\(aprInfo.value) scale=\(aprInfo.scale) date=\(date)", component: LOG_COMPONENT)
            }
            // If we didn't pick up APR from the row description, fall back to global APR detected from the page
            if sb.interestRateAPR == nil, let aprInfo = globalAPR {
                sb.interestRateAPR = aprInfo.value
                if sb.interestRateScale == nil { sb.interestRateScale = aprInfo.scale }
                AMLogging.log("Applied global APR to snapshot: apr=\(aprInfo.value) scale=\(aprInfo.scale) date=\(date)", component: LOG_COMPONENT)
            }
            // Prefer explicit Account column, fallback to description text; bias to credit card when CC context is present anywhere in the document
            if isCreditCardSummary || hasCreditCardIndicators {
                sb.sourceAccountLabel = "creditcard"
            } else {
                var accountKey = normalizedLabel(value(row, map, key: "account")) ?? normalizedLabel(desc)
                // Bias to loan when loan phrases are present
                let loanPhrases = ["loan", "mortgage", "principal balance", "outstanding principal", "amount due", "payment due"]
                if accountKey == nil {
                    if loanPhrases.contains(where: { lower.contains($0) }) {
                        accountKey = "loan"
                    }
                }
                sb.sourceAccountLabel = accountKey
            }
            balances.append(sb)
        }

        AMLogging.log("PDFSummaryParser — parsed balances: \(balances.count)", component: LOG_COMPONENT)

        // Final coercion: if the document contains clear credit card indicators, treat all summary balances as credit card snapshots
        if hasCreditCardIndicators && !balances.isEmpty {
            AMLogging.log("PDFSummaryParser: coercing \(balances.count) snapshot label(s) to creditcard due to document-level CC indicators", component: LOG_COMPONENT)
            for i in balances.indices {
                balances[i].sourceAccountLabel = "creditcard"
            }
        }

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

