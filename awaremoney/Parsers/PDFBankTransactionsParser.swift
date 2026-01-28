import Foundation

private let LOG_COMPONENT = "PDFBankTransactionsParser"

struct PDFBankTransactionsParser: StatementParser {
    static var id: String { "pdf.transactions" }

    func canParse(headers: [String]) -> Bool {
        // Expect normalized headers from PDFStatementExtractor: date, description, amount, balance, optionally account
        let lower = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasDate = lower.contains("date")
        let hasDesc = lower.contains("description")
        let hasAmount = lower.contains("amount")
        // balance is optional but helpful for sign inference
        let _ = lower.contains(where: { $0.contains("balance") })
        // account column is optional; no logic change needed
        return hasDate && hasDesc && hasAmount
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        let map = headerMap(headers)
        AMLogging.always("Begin parse — rows: \(rows.count), headers: \(headers), headerMap: \(map)", component: LOG_COMPONENT)
        var txs: [StagedTransaction] = []

        // Parse all rows into a lightweight struct for optional balance-delta sign inference
        struct RowItem { let date: Date; let desc: String; let amount: Decimal; let balance: Decimal? ; let account: String? }
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
        for (rowIndex, row) in rows.enumerated() {
            AMLogging.always("Row \(rowIndex) raw: \(row)", component: LOG_COMPONENT)
            guard let dateStr = value(row, map, key: "date") else {
                AMLogging.always("Row \(rowIndex) skipped — missing date cell", component: LOG_COMPONENT)
                continue
            }
            guard let date = parseDate(dateStr) else {
                AMLogging.always("Row \(rowIndex) skipped — date parse failed: \(dateStr)", component: LOG_COMPONENT)
                continue
            }
            let descRaw = value(row, map, key: "description")
            let rowForHeuristics = [value(row, map, key: "date"), descRaw, value(row, map, key: "amount"), value(row, map, key: "balance")].compactMap { $0 }.joined(separator: " ")

            // Skip section/page headers and totals that sometimes get captured as rows
            if isHeaderOrTotal(descRaw ?? "") || isHeaderOrTotal(rowForHeuristics) {
                AMLogging.always("Row \(rowIndex) skipped — header/total detected. desc=\(descRaw ?? "<nil>"), row=\(rowForHeuristics)", component: LOG_COMPONENT)
                continue
            }

            guard let amountStr = value(row, map, key: "amount") else {
                AMLogging.always("Row \(rowIndex) skipped — missing amount cell", component: LOG_COMPONENT)
                continue
            }
            guard let amountVal = Decimal(string: sanitize(amountStr)) else {
                AMLogging.always("Row \(rowIndex) skipped — amount parse failed: \(amountStr)", component: LOG_COMPONENT)
                continue
            }
            let balStr = value(row, map, key: "balance")
            let balance = balStr.flatMap { Decimal(string: sanitize($0)) }
            let desc = descRaw ?? "Unknown"
            let accountLabel: String? = value(row, map, key: "account")

            items.append(RowItem(date: date, desc: desc, amount: amountVal, balance: balance, account: accountLabel))
            AMLogging.always("Row \(rowIndex) included — date=\(dateStr), desc=\(desc), amount=\(amountVal), balance=\(balance?.description ?? "nil"), account=\(accountLabel ?? "(nil)")", component: LOG_COMPONENT)
        }

        AMLogging.always("Parsed items count: \(items.count)", component: LOG_COMPONENT)

        // Determine a suggested account type from account labels in the PDF
        let accountLabels: Set<String> = Set(items.compactMap { $0.account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        let suggestedType: Account.AccountType? = {
            if accountLabels == ["checking"] { return .checking }
            if accountLabels == ["savings"] { return .savings }
            return nil // mixed or unknown — let the user choose
        }()

        // Optional: infer sign using balance deltas if balances are present on many rows
        func inferSigns(using items: [RowItem]) -> [Decimal] {
            guard items.count > 0 else { return [] }
            AMLogging.always("inferSigns — items: \(items.count)", component: LOG_COMPONENT)
            var signed: [Decimal] = Array(repeating: 0, count: items.count)

            // If we have at least two balances, attempt delta-based sign inference
            let withBalances = items.enumerated().compactMap { (idx, it) -> (Int, RowItem)? in
                guard let _ = it.balance else { return nil }
                return (idx, it)
            }
            AMLogging.always("inferSigns — withBalances indices: \(withBalances.map { $0.0 })", component: LOG_COMPONENT)
            if withBalances.count >= 2 {
                for i in 0..<items.count {
                    let amt = items[i].amount
                    if let prevIndex = (stride(from: i-1, through: 0, by: -1).first { items[$0].balance != nil }),
                       let currBal = items[i].balance, let prevBal = items[prevIndex].balance {
                        let delta = currBal - prevBal
                        // If delta magnitude matches amount magnitude within a small epsilon, use delta sign
                        let eps: Decimal = 0.01
                        if (delta.magnitude - amt.magnitude).magnitude <= eps {
                            AMLogging.always("inferSigns — row \(i) delta match: prevIndex=\(prevIndex), prevBal=\(prevBal), currBal=\(currBal), delta=\(delta), amt=\(amt)", component: LOG_COMPONENT)
                            signed[i] = delta
                            continue
                        }
                    }
                    AMLogging.always("inferSigns — row \(i) fallback sign (no delta match), amt=\(amt)", component: LOG_COMPONENT)
                    // Fallback: leave as signed amount for now; later heuristics may flip
                    signed[i] = items[i].amount
                }
                return signed
            }

            AMLogging.always("inferSigns — no reliable balances, defaulting to signed amounts", component: LOG_COMPONENT)
            // No reliable balances: default to signed amounts; later heuristics can adjust
            for i in 0..<items.count { signed[i] = items[i].amount }
            return signed
        }

        var signedAmounts = inferSigns(using: items)
        AMLogging.always("Signed amounts: \(signedAmounts)", component: LOG_COMPONENT)

        // Build staged transactions; default include=true, propagate sourceAccountLabel
        for i in 0..<items.count {
            let it = items[i]
            let amount = (i < signedAmounts.count) ? signedAmounts[i] : it.amount
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
                sourceAccountLabel: it.account,
                include: true
            )
            AMLogging.always("TX \(i) built — date=\(it.date), desc=\(it.desc), amount=\(amount), include=true, account=\(it.account ?? "(nil)")", component: LOG_COMPONENT)
            txs.append(tx)
        }

        AMLogging.always("PDFBankTransactionsParser — produced tx: \(txs.count)", component: LOG_COMPONENT)
        if txs.isEmpty {
            throw ImportError.unknownFormat
        }

        return StagedImport(
            parserId: Self.id,
            sourceFileName: "Unknown.pdf",
            suggestedAccountType: suggestedType,
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
    
    private func isHeaderOrTotal(_ desc: String) -> Bool {
        let s = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        let lower = s.lowercased()

        // Normalize by collapsing non-letter runs to a single space for resilient matching
        var normalized = ""
        var lastWasSpace = false
        for ch in lower {
            if ch.isLetter {
                normalized.append(ch)
                lastWasSpace = false
            } else {
                if !lastWasSpace {
                    normalized.append(" ")
                    lastWasSpace = true
                }
            }
        }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        // Exact/normalized section headers commonly seen in bank PDFs
        let sectionHeaders: Set<String> = [
            "deposits and additions",
            "electronic withdrawals",
            "electronic deposits",
            "electronic credits",
            "electronic debits",
            "deposits",
            "withdrawals",
            "checks",
            "other withdrawals",
            "fees",
            "interest",
            "daily ending balance",
            "daily balance",
            "ending balance",
            "beginning balance",
            "opening balance",
            "closing balance",
            "deposits additions",
            "electronic withdrawal"
        ]
        if sectionHeaders.contains(lower) || sectionHeaders.contains(normalized) {
            return true
        }

        // Contains-based match for section headers with extra words/formatting
        if sectionHeaders.contains(where: { lower.contains($0) }) || sectionHeaders.contains(where: { normalized.contains($0) }) {
            return true
        }

        // Totals for sections (e.g., "Total Electronic Withdrawals", "Total Deposits and Additions")
        if lower.hasPrefix("total ") || normalized.hasPrefix("total ") || lower.contains(" total ") {
            if lower.contains("deposit") || lower.contains("withdrawal") || lower.contains("check") || lower.contains("fee") || lower.contains("addition") || lower.contains("electronic") {
                return true
            }
        }

        // Column header rows repeated on each page (any combination of these words)
        if (lower.contains("date") && lower.contains("description") && (lower.contains("amount") || lower.contains("balance"))) {
            return true
        }

        // Common page header patterns
        if lower.contains("page ") && lower.contains(" of ") { return true }
        if lower.contains("statement") && (lower.contains("date") || lower.contains("period")) { return true }
        if lower.contains("account number") || lower.contains("account ending") { return true }

        // Lines that are all caps with no digits and short (likely headings)
        let hasLowercase = s.rangeOfCharacter(from: CharacterSet.lowercaseLetters) != nil
        let hasDigits = s.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil
        if !hasLowercase && !hasDigits && s == s.uppercased() && s.count <= 48 {
            return true
        }

        return false
    }

    private func isLikelyStatementPeriodRow(date: Date, desc: String, amountAbs: Decimal, balance: Decimal?) -> Bool {
        // Must have no balance value
        if balance != nil { return false }
        let lower = desc.lowercased()
        // Look for phrases indicating statement period
        let indicators = ["through", "statement period", "statement cycle"]
        let hasIndicator = indicators.contains(where: { lower.contains($0) })
        if !hasIndicator { return false }

        // Check if amount equals the day-of-month of the date (common artifact: amount=17 for 12/17/2025)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let day = calendar.component(.day, from: date)
        if day <= 0 { return false }

        if amountAbs == Decimal(day) {
            return true
        }

        // Treat small integer amounts <= 31 with no cents as suspicious in this context
        var truncated = amountAbs
        var rounded = Decimal()
        NSDecimalRound(&rounded, &truncated, 0, .plain)
        if amountAbs == rounded && amountAbs >= 1 && amountAbs <= 31 {
            return true
        }

        // If it has indicator + month name and no balance, it's likely a header regardless of amount
        let months = ["january","february","march","april","may","june","july","august","september","october","november","december"]
        if months.contains(where: { lower.contains($0) }) {
            return true
        }

        return false
    }
}

