import Foundation

private let LOG_COMPONENT = "PDFBankTransactionsParser"

struct PDFBankTransactionsParser: StatementParser {
    static var id: String { "pdf.transactions" }

    func canParse(headers: [String]) -> Bool {
        // Expect normalized headers from PDFStatementExtractor: date, description, amount, balance
        let lower = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasDate = lower.contains("date")
        let hasDesc = lower.contains("description")
        let hasAmount = lower.contains("amount")
        // balance is optional but helpful for sign inference
        let _ = lower.contains(where: { $0.contains("balance") })
        return hasDate && hasDesc && hasAmount
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        let map = headerMap(headers)
        var txs: [StagedTransaction] = []

        // Parse all rows into a lightweight struct for optional balance-delta sign inference
        struct RowItem { let date: Date; let desc: String; let amountAbs: Decimal; let balance: Decimal? }
        var items: [RowItem] = []

        func parseDate(_ s: String) -> Date? {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = "MM/dd/yyyy" // normalized by PDFStatementExtractor
            return df.date(from: s)
        }

        func sanitize(_ s: String) -> String {
            s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
        }

        // First pass: parse as absolute amounts; keep optional running balance
        for row in rows {
            guard let dateStr = value(row, map, key: "date"), let date = parseDate(dateStr) else { continue }
            let desc = value(row, map, key: "description") ?? "Unknown"

            // Amount: keep its sign if explicitly present (parentheses/minus/CR/DR already handled in extractor sanitize)
            guard let amountStr = value(row, map, key: "amount"), let amountAbs = Decimal(string: sanitize(amountStr)) else { continue }
            let balStr = value(row, map, key: "balance")
            let balance = balStr.flatMap { Decimal(string: sanitize($0)) }

            items.append(RowItem(date: date, desc: desc, amountAbs: amountAbs.magnitude, balance: balance))
        }

        // Optional: infer sign using balance deltas if balances are present on many rows
        func inferSigns(using items: [RowItem]) -> [Decimal] {
            guard items.count > 0 else { return [] }
            var signed: [Decimal] = Array(repeating: 0, count: items.count)

            // If we have at least two balances, attempt delta-based sign inference
            let withBalances = items.enumerated().compactMap { (idx, it) -> (Int, RowItem)? in
                guard let _ = it.balance else { return nil }
                return (idx, it)
            }
            if withBalances.count >= 2 {
                for i in 0..<items.count {
                    let amt = items[i].amountAbs
                    if let prevIndex = (stride(from: i-1, through: 0, by: -1).first { items[$0].balance != nil }),
                       let currBal = items[i].balance, let prevBal = items[prevIndex].balance {
                        let delta = currBal - prevBal
                        // If delta magnitude matches amount magnitude within a small epsilon, use delta sign
                        let eps: Decimal = 0.01
                        if (delta.magnitude - amt).magnitude <= eps {
                            signed[i] = delta
                            continue
                        }
                    }
                    // Fallback: leave as positive for now; later heuristics may flip
                    signed[i] = amt
                }
                return signed
            }

            // No reliable balances: default to positive; later heuristics can adjust
            for i in 0..<items.count { signed[i] = items[i].amountAbs }
            return signed
        }

        var signedAmounts = inferSigns(using: items)

        // Build staged transactions; default include=false for safety
        for i in 0..<items.count {
            let it = items[i]
            let amount = (i < signedAmounts.count) ? signedAmounts[i] : it.amountAbs
            let hashKey = Hashing.hashKey(date: it.date, amount: amount, payee: it.desc, memo: nil, symbol: nil, quantity: nil)
            var tx = StagedTransaction(
                datePosted: it.date,
                amount: amount,
                payee: it.desc,
                memo: nil,
                kind: .bank,
                externalId: nil,
                symbol: nil,
                quantity: nil,
                price: nil,
                fees: nil,
                hashKey: hashKey,
                include: false
            )
            txs.append(tx)
        }

        AMLogging.always("PDFBankTransactionsParser — produced tx: \(txs.count)", component: LOG_COMPONENT)
        if txs.isEmpty {
            throw ImportError.unknownFormat
        }

        return StagedImport(
            parserId: Self.id,
            sourceFileName: "Unknown.pdf",
            suggestedAccountType: .checking,
            transactions: txs,
            holdings: [],
            balances: []
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
