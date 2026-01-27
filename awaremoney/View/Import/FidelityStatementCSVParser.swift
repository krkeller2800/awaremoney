import Foundation

private let LOG_COMPONENT = "FidelityStatementCSVParser"

struct FidelityStatementCSVParser: StatementParser {
    static var id: String { "fidelity.statement.csv" }

    // We detect the top-of-file summary header for Fidelity statements
    func canParse(headers: [String]) -> Bool {
        let lower = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        // Expect something like: "Account Type,Account,Beginning mkt Value,Change in Investment,Ending mkt Value,Short Balance,Ending Net Value,..."
        let hasAccountType = lower.contains(where: { $0.contains("account type") })
        let hasEndingValue = lower.contains(where: { $0.contains("ending mkt value") || $0.contains("ending net value") })
        AMLogging.always("canParse? headers: \(lower)", component: LOG_COMPONENT)
        return hasAccountType && hasEndingValue
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        // Map the top summary row to extract ending value
        let map = headerMap(headers)
        AMLogging.always("parse() — rows: \(rows.count), headers: \(headers)", component: LOG_COMPONENT)
        AMLogging.always("header map keys: \(Array(map.keys))", component: LOG_COMPONENT)
        var balances: [StagedBalance] = []
        var holdings: [StagedHolding] = []

        // Use 'now' as the as-of date when statements don't include one in the CSV body
        let asOf = Date()
        AMLogging.always("Using as-of date: \(asOf)", component: LOG_COMPONENT)

        // 1) Parse the first data row under the summary header (if present)
        if let summaryRow = rows.first, !summaryRow.isEmpty {
            if let endNet = value(summaryRow, map, key: "ending net value"), let dec = Decimal(string: sanitize(endNet)) {
                balances.append(StagedBalance(asOfDate: asOf, balance: dec))
            } else if let endMkt = value(summaryRow, map, key: "ending mkt value"), let dec = Decimal(string: sanitize(endMkt)) {
                balances.append(StagedBalance(asOfDate: asOf, balance: dec))
            }
            AMLogging.always("After summary parse — balances: \(balances.count)", component: LOG_COMPONENT)
        }

        // 2) Scan the remaining rows for a second header block indicating holdings
        // Expected header: "Symbol/CUSIP,Description,Quantity,Price,Beginning Value,Ending Value,Cost Basis"
        let holdingsHeaderTokens = [
            "symbol/cusip", "description", "quantity", "price", "beginning value", "ending value", "cost basis"
        ]

        var i = 0
        while i < rows.count {
            let row = rows[i].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let lowerRow = row.map { $0.lowercased() }

            // Detect holdings header by matching tokens in order (allowing missing trailing columns)
            if matchesHoldingsHeader(lowerRow, expected: holdingsHeaderTokens) {
                // Process subsequent rows until a subtotal or blank section
                i += 1
                while i < rows.count {
                    let r = rows[i].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if r.isEmpty || r.allSatisfy({ $0.isEmpty }) { i += 1; continue }

                    let first = r.first?.lowercased() ?? ""
                    if first.hasPrefix("subtotal") { break }
                    // Section separators like account number or category names
                    if r.count == 1 && (first.isEmpty || CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: first.replacingOccurrences(of: ",", with: "")))) {
                        i += 1; continue
                    }
                    if first == "stocks" || first == "core account" { i += 1; continue }

                    // Expect: symbol, description, quantity, price, beginning value, ending value, cost basis
                    if r.count >= 3 {
                        let symbol = r[safe: 0] ?? ""
                        let description = r[safe: 1] ?? ""
                        let quantityStr = r[safe: 2] ?? ""
                        let endingValueStr = r[safe: 5] ?? "" // column 6 if present

                        let qty = Decimal(string: sanitize(quantityStr)) ?? 0
                        let mv = Decimal(string: sanitize(endingValueStr))

                        // Skip header echoes or non-holding rows
                        if symbol.lowercased().contains("symbol") || symbol.lowercased().hasPrefix("subtotal") {
                            i += 1; continue
                        }

                        AMLogging.log("Holding row — symbol: \(symbol), qty: \(qty), mv: \(String(describing: mv))", component: LOG_COMPONENT)
                        let holding = StagedHolding(
                            asOfDate: asOf,
                            symbol: symbol,
                            quantity: qty,
                            marketValue: mv,
                            include: true
                        )
                        holdings.append(holding)
                    }

                    i += 1
                }
            }

            i += 1
        }

        AMLogging.always("parse() result — tx: 0, holdings: \(holdings.count), balances: \(balances.count)", component: LOG_COMPONENT)
        return StagedImport(
            parserId: Self.id,
            sourceFileName: "Unknown.csv",
            suggestedAccountType: .brokerage,
            transactions: [],
            holdings: holdings,
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

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
    }

    private func matchesHoldingsHeader(_ row: [String], expected: [String]) -> Bool {
        // Row should start with the expected sequence, allowing row to be equal or longer
        let count = min(row.count, expected.count)
        guard count >= 3 else { return false }
        for j in 0..<count {
            if !row[j].contains(expected[j]) { return false }
        }
        return true
    }
}

// Safe index helper
private extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
