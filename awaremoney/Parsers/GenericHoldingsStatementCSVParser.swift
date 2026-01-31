import Foundation

struct GenericHoldingsStatementCSVParser: StatementParser {
    static var id: String { "generic.holdings.statement.csv" }

    // Be permissive: recognize either a summary header (account type / ending value)
    // or a holdings header (symbol/description/quantity/...)
    func canParse(headers: [String]) -> Bool {
        let lower = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let headerString = lower.joined(separator: ",")

        // Summary-style signals
        let hasAccountType = headerString.contains("account type") || headerString.contains("account")
        let hasEndingValue = headerString.contains("ending mkt value") || headerString.contains("ending net value") || headerString.contains("ending value") || headerString.contains("market value")

        // Holdings-style signals
        let hasSymbol = headerString.contains("symbol") || headerString.contains("symbol/cusip")
        let hasDescription = headerString.contains("description")
        let hasQuantity = headerString.contains("quantity")

        return (hasAccountType && hasEndingValue) || (hasSymbol && hasDescription && hasQuantity)
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        let map = headerMap(headers)
        var balances: [StagedBalance] = []
        var holdings: [StagedHolding] = []

        let asOf = Date()

        // Try to derive a balance from the first data row under the initial header
        if let firstRow = rows.first, !firstRow.isEmpty {
            if let endNet = value(firstRow, map, key: "ending net value"), let dec = Decimal(string: sanitize(endNet)) {
                balances.append(StagedBalance(asOfDate: asOf, balance: dec))
            } else if let endMkt = value(firstRow, map, key: "ending mkt value"), let dec = Decimal(string: sanitize(endMkt)) {
                balances.append(StagedBalance(asOfDate: asOf, balance: dec))
            } else if let endVal = value(firstRow, map, key: "ending value"), let dec = Decimal(string: sanitize(endVal)) {
                balances.append(StagedBalance(asOfDate: asOf, balance: dec))
            } else if let mkt = value(firstRow, map, key: "market value"), let dec = Decimal(string: sanitize(mkt)) {
                balances.append(StagedBalance(asOfDate: asOf, balance: dec))
            }
        }

        // Scan for a holdings header block in subsequent rows
        let expected = [
            "symbol", "description", "quantity", "price", "beginning value", "ending value", "cost basis"
        ]

        var i = 0
        while i < rows.count {
            let row = rows[i].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let lowerRow = row.map { $0.lowercased() }

            if matchesHoldingsHeader(lowerRow, expected: expected) {
                // Consume following rows as holdings until a subtotal/blank/section break
                i += 1
                while i < rows.count {
                    let r = rows[i].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if r.isEmpty || r.allSatisfy({ $0.isEmpty }) { i += 1; continue }

                    let first = r.first?.lowercased() ?? ""
                    if first.hasPrefix("subtotal") { break }
                    if r.count == 1 { i += 1; continue }
                    if first == "stocks" || first == "core account" || first == "mutual funds" { i += 1; continue }

                    // Map fields by fixed positions relative to holdings header
                    let symbol = r[safe: 0] ?? ""
                    let quantityStr = r[safe: 2] ?? ""
                    let endingValueStr = r[safe: 5] ?? r[safe: 4] ?? "" // prefer ending value, fallback beginning value

                    // Skip non-holding rows
                    if symbol.lowercased().contains("symbol") || symbol.lowercased().hasPrefix("subtotal") {
                        i += 1; continue
                    }

                    let qty = Decimal(string: sanitize(quantityStr)) ?? 0
                    let mv = Decimal(string: sanitize(endingValueStr))

                    let holding = StagedHolding(
                        asOfDate: asOf,
                        symbol: symbol,
                        quantity: qty,
                        marketValue: mv,
                        include: true
                    )
                    holdings.append(holding)

                    i += 1
                }
            }

            i += 1
        }

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
        let count = min(row.count, expected.count)
        guard count >= 3 else { return false }
        // Allow either "symbol" or "symbol/cusip" in the first position
        let firstOk = row.first?.contains("symbol") == true
        if !firstOk { return false }
        // Ensure subsequent expected tokens appear in order
        for j in 1..<count {
            if !row[j].contains(expected[j]) { return false }
        }
        return true
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
