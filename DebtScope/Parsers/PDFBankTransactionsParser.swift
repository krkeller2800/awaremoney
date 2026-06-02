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
        let result = hasDate && hasDesc && hasAmount
        AMLogging.log("canParse? headers: \(lower) -> \(result)", component: LOG_COMPONENT)
        return result
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        let map = headerMap(headers)
        AMLogging.log("Begin parse — rows: \(rows.count), headers: \(headers), headerMap: \(map)", component: LOG_COMPONENT)
        var txs: [StagedTransaction] = []

        // Parse all rows into a lightweight struct for optional balance-delta sign inference
        struct RowItem { let date: Date; let desc: String; let amount: Decimal; let rawAmount: String; let balance: Decimal? ; let account: String? }
        var items: [RowItem] = []
        var skippedMissingDate = 0
        var skippedDateParse = 0
        var skippedHeaderOrTotal = 0
        var skippedMissingAmount = 0
        var skippedAmountParse = 0

        func parseDate(_ s: String) -> Date? {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            for fmt in ["MM/dd/yy", "M/d/yy", "MM/dd/yyyy", "M/d/yyyy", "MMM d, yyyy", "MMMM d, yyyy"] {
                df.dateFormat = fmt
                if let date = df.date(from: trimmed), calendar.component(.year, from: date) >= 1900 {
                    return date
                }
            }
            return nil
        }

        func sanitize(_ s: String) -> String {
            s.replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: "CR", with: "", options: [.caseInsensitive])
                .replacingOccurrences(of: "DR", with: "", options: [.caseInsensitive])
                .replacingOccurrences(of: "CREDIT", with: "", options: [.caseInsensitive])
                .replacingOccurrences(of: "DEBIT", with: "", options: [.caseInsensitive])
                .replacingOccurrences(of: " ", with: "")
        }

        // First pass: parse as absolute amounts; keep optional running balance
        for (rowIndex, row) in rows.enumerated() {
            AMLogging.log("Row \(rowIndex) raw: \(row)", component: LOG_COMPONENT)
            guard let dateStr = value(row, map, key: "date") else {
                skippedMissingDate += 1
                AMLogging.log("Row \(rowIndex) skipped — missing date cell", component: LOG_COMPONENT)
                continue
            }
            guard let date = parseDate(dateStr) else {
                skippedDateParse += 1
                AMLogging.log("Row \(rowIndex) skipped — date parse failed: \(dateStr)", component: LOG_COMPONENT)
                continue
            }
            let descRaw = value(row, map, key: "description")
            let rowForHeuristics = [value(row, map, key: "date"), descRaw, value(row, map, key: "amount"), value(row, map, key: "balance")].compactMap { $0 }.joined(separator: " ")

            // Skip section/page headers and totals that sometimes get captured as rows
            if isHeaderOrTotal(descRaw ?? "") || isHeaderOrTotal(rowForHeuristics) {
                skippedHeaderOrTotal += 1
                AMLogging.log("Row \(rowIndex) skipped — header/total detected. desc=\(descRaw ?? "<nil>"), row=\(rowForHeuristics)", component: LOG_COMPONENT)
                continue
            }

            guard let amountStr = value(row, map, key: "amount") else {
                skippedMissingAmount += 1
                AMLogging.log("Row \(rowIndex) skipped — missing amount cell", component: LOG_COMPONENT)
                continue
            }
            guard let amountVal = Decimal(string: sanitize(amountStr)) else {
                skippedAmountParse += 1
                AMLogging.log("Row \(rowIndex) skipped — amount parse failed: \(amountStr)", component: LOG_COMPONENT)
                continue
            }
            let balStr = value(row, map, key: "balance")
            let parsedBalance = balStr.flatMap { Decimal(string: sanitize($0)) }
            let desc = descRaw ?? "Unknown"
            let accountLabel: String? = value(row, map, key: "account")

            // Loan statements often use Charges / Payments columns rather than Amount / Running Balance.
            // In that shape, the extractor maps Charges -> amount and Payments -> balance. If Charges is zero
            // and Payments is non-zero for a payment row, recover the real transaction amount from Payments.
            let lowerDesc = desc.lowercased()
            let lowerAccount = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isLoanPaymentRow = (lowerAccount == "loan" || lowerDesc.contains("payment")) && amountVal == .zero && (parsedBalance ?? .zero) != .zero
            let amount = isLoanPaymentRow ? (parsedBalance ?? amountVal) : amountVal
            let balance = isLoanPaymentRow ? nil : parsedBalance

            if isLoanPaymentRow {
                AMLogging.log("Row \(rowIndex) loan payment recovery — charges=\(amountVal), payments=\(parsedBalance?.description ?? "nil"), recoveredAmount=\(amount)", component: LOG_COMPONENT)
            }

            items.append(RowItem(date: date, desc: desc, amount: amount, rawAmount: amountStr, balance: balance, account: accountLabel))
            AMLogging.log("Row \(rowIndex) included — date=\(dateStr), desc=\(desc), amount=\(amount), balance=\(balance?.description ?? "nil"), account=\(accountLabel ?? "(nil)")", component: LOG_COMPONENT)
        }

        AMLogging.log("Parsed items count: \(items.count)", component: LOG_COMPONENT)
        let includedAccountCounts = Dictionary(grouping: items, by: { ($0.account ?? "nil").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            .mapValues { $0.count }
        AMLogging.always(
            "PDF transaction parse summary — inputRows=\(rows.count) includedItems=\(items.count) accounts=\(includedAccountCounts) skippedMissingDate=\(skippedMissingDate) skippedDateParse=\(skippedDateParse) skippedHeaderOrTotal=\(skippedHeaderOrTotal) skippedMissingAmount=\(skippedMissingAmount) skippedAmountParse=\(skippedAmountParse)",
            component: LOG_COMPONENT
        )
        var looksLikeCreditCardActivity = items.contains { item in
            let lowerDesc = item.desc.lowercased()
            let lowerAccount = item.account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return lowerAccount == "creditcard" ||
                lowerAccount == "credit card" ||
                lowerDesc.contains("payment thank you") ||
                lowerDesc.contains("interest charge") ||
                lowerDesc.contains("finance charge") ||
                lowerDesc.contains("cardmember") ||
                lowerDesc.contains("card member")
        }

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
            AMLogging.log("inferSigns — items: \(items.count)", component: LOG_COMPONENT)
            var signed: [Decimal] = Array(repeating: 0, count: items.count)

            func explicitlySignedAmount(for item: RowItem) -> Decimal? {
                let raw = item.rawAmount.trimmingCharacters(in: .whitespacesAndNewlines)
                let upperRaw = raw.uppercased()
                if raw.hasPrefix("-") || upperRaw.contains("DR") || upperRaw.contains("DEBIT") || (raw.hasPrefix("(") && raw.hasSuffix(")")) {
                    return -item.amount.magnitude
                }
                if raw.hasPrefix("+") || upperRaw.contains("CR") || upperRaw.contains("CREDIT") {
                    return item.amount.magnitude
                }
                return nil
            }

            // If we have at least two balances, attempt delta-based sign inference
            let withBalances = items.enumerated().compactMap { (idx, it) -> (Int, RowItem)? in
                guard let _ = it.balance else { return nil }
                return (idx, it)
            }
            AMLogging.log("inferSigns — withBalances indices: \(withBalances.map { $0.0 })", component: LOG_COMPONENT)
            if withBalances.count >= 2 {
                for i in 0..<items.count {
                    if let explicitAmount = explicitlySignedAmount(for: items[i]) {
                        AMLogging.log("inferSigns — row \(i) preserving explicit sign amount=\(explicitAmount), raw=\(items[i].rawAmount)", component: LOG_COMPONENT)
                        signed[i] = explicitAmount
                        continue
                    }

                    let amt = items[i].amount
                    if let prevIndex = (stride(from: i-1, through: 0, by: -1).first { items[$0].balance != nil }),
                       let currBal = items[i].balance, let prevBal = items[prevIndex].balance {
                        let delta = currBal - prevBal
                        // If delta magnitude matches amount magnitude within a small epsilon, use delta sign
                        let eps: Decimal = 0.01
                        if (delta.magnitude - amt.magnitude).magnitude <= eps {
                            AMLogging.log("inferSigns — row \(i) delta match: prevIndex=\(prevIndex), prevBal=\(prevBal), currBal=\(currBal), delta=\(delta), amt=\(amt)", component: LOG_COMPONENT)
                            signed[i] = delta
                            continue
                        }
                    }
                    AMLogging.log("inferSigns — row \(i) fallback sign (no delta match), amt=\(amt)", component: LOG_COMPONENT)
                    // Fallback: leave as signed amount for now; later heuristics may flip
                    signed[i] = items[i].amount
                }
                return signed
            }

            AMLogging.log("inferSigns — no reliable balances, defaulting to signed amounts", component: LOG_COMPONENT)
            // No reliable balances: default to signed amounts; later heuristics can adjust
            for i in 0..<items.count { signed[i] = items[i].amount }
            return signed
        }

        func recoverMissingCreditCardActivity(from text: String, into items: inout [RowItem]) {
            func hasTransaction(matching predicate: (RowItem) -> Bool) -> Bool {
                items.contains(where: predicate)
            }

            func amountDecimal(from raw: String) -> Decimal? {
                Decimal(string: sanitize(raw))
            }

            func firstMatch(_ pattern: String) -> NSTextCheckingResult? {
                guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
                return rx.firstMatch(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
            }

            func group(_ index: Int, in match: NSTextCheckingResult) -> String? {
                guard match.numberOfRanges > index,
                      let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }

            let date = #"\d{1,2}/\d{1,2}/\d{2,4}"#

            let paymentPattern = #"\b("# + date + #")\s+payment\s*-\s*thank\s+you\b.{0,180}?(-\s*\$?\s*(?:[0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)(?:\.[0-9]{2}))"#
            if let match = firstMatch(paymentPattern),
               let dateText = group(1, in: match),
               let paymentDate = parseDate(dateText),
               let rawAmount = group(2, in: match),
               let amount = amountDecimal(from: rawAmount),
               !hasTransaction(matching: { $0.desc.lowercased().contains("payment") && $0.amount.magnitude == amount.magnitude }) {
                items.append(RowItem(date: paymentDate, desc: "PAYMENT - THANK YOU", amount: amount, rawAmount: rawAmount, balance: nil, account: "creditCard"))
                AMLogging.log("Recovered CC payment activity from statement text — date=\(dateText) amount=\(amount)", component: LOG_COMPONENT)
            }

            let closingDate: Date? = {
                let closingPattern = #"statement\s+closing\s+date\b.{0,80}?("# + date + #")"#
                if let match = firstMatch(closingPattern), let dateText = group(1, in: match), let closingDate = parseDate(dateText) {
                    return closingDate
                }

                let rangePattern = #"(?:account\s+summary|open\s+to\s+close\s+date)\b.{0,80}?("# + date + #")\s*(?:–|-|to)\s*("# + date + #")"#
                guard let match = firstMatch(rangePattern), let dateText = group(2, in: match) else { return nil }
                return parseDate(dateText)
            }()

            let interestPattern = #"interest\s+charge\s+on\s+purchases\s+(\$?\s*(?:[0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)(?:\.[0-9]{2}))"#
            if let interestDate = closingDate,
               let match = firstMatch(interestPattern),
               let rawAmount = group(1, in: match),
               let amount = amountDecimal(from: rawAmount),
               amount > 0,
               !hasTransaction(matching: { $0.desc.lowercased().contains("interest charge") && $0.amount.magnitude == amount.magnitude }) {
                items.append(RowItem(date: interestDate, desc: "Interest Charge on Purchases", amount: amount, rawAmount: rawAmount, balance: nil, account: "creditCard"))
                AMLogging.log("Recovered CC interest charge activity from statement text — amount=\(amount)", component: LOG_COMPONENT)
            }
        }

        func removeCreditCardPaymentRowsThatAreActuallyBalances(from items: inout [RowItem], documentText: String) {
            let balanceMagnitudes = summaryBalanceMagnitudes(in: documentText)
            guard !balanceMagnitudes.isEmpty else { return }

            let before = items.count
            items.removeAll { item in
                let lowerDescription = item.desc.lowercased()
                guard lowerDescription.contains("payment") else { return false }
                return balanceMagnitudes.contains(item.amount.magnitude)
            }
            let removed = before - items.count
            if removed > 0 {
                AMLogging.always(
                    "Removed \(removed) credit-card payment row(s) whose amount matched statement balances: \(balanceMagnitudes)",
                    component: LOG_COMPONENT
                )
            }
        }

        func summaryBalanceMagnitudes(in text: String) -> Set<Decimal> {
            let balanceLabels = ["previous balance", "new balance"]
            var amounts = Set<Decimal>()
            for label in balanceLabels {
                let pattern = label + #"\s*:?\s*([+-]?\s*\$?\s*(?:[0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)(?:\.[0-9]{2}))"#
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in regex.matches(in: text, options: [], range: range) {
                    guard match.numberOfRanges >= 2,
                          let amountRange = Range(match.range(at: 1), in: text),
                          let amount = Decimal(string: sanitize(String(text[amountRange]))) else { continue }
                    amounts.insert(amount.magnitude)
                }
            }
            return amounts
        }

        let docText = rows.flatMap { $0 }.joined(separator: " ")
        let docTextLower = docText.lowercased()
        let documentLooksLikeCreditCard = (
            docTextLower.contains("summary of account activity") ||
            docTextLower.contains("account summary") ||
            docTextLower.contains("card ending in")
        ) &&
            docTextLower.contains("previous balance") &&
            docTextLower.contains("new balance") &&
            (docTextLower.contains("minimum payment") || docTextLower.contains("credit limit") || docTextLower.contains("credit line") || docTextLower.contains("available credit"))

        if documentLooksLikeCreditCard {
            looksLikeCreditCardActivity = true
            removeCreditCardPaymentRowsThatAreActuallyBalances(from: &items, documentText: docText)
            recoverMissingCreditCardActivity(from: docText, into: &items)
        }

        let signedAmounts = inferSigns(using: items)
        AMLogging.log("Signed amounts: \(signedAmounts)", component: LOG_COMPONENT)
        // Build staged transactions; default include=true, propagate sourceAccountLabel
        for i in 0..<items.count {
            let it = items[i]
            let inferredAmount = (i < signedAmounts.count) ? signedAmounts[i] : it.amount
            let accountLabel = it.account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let shouldNormalizeAsCreditCardActivity = looksLikeCreditCardActivity &&
                (accountLabel.isEmpty || accountLabel == "unknown" || accountLabel == "creditcard" || accountLabel == "credit card")
            let amount = normalizeCreditCardActivityAmount(inferredAmount, description: it.desc, rawAmount: it.rawAmount, isCreditCardActivity: shouldNormalizeAsCreditCardActivity)
            let outputAccountLabel = shouldNormalizeAsCreditCardActivity && (accountLabel.isEmpty || accountLabel == "unknown") ? "creditCard" : it.account
            let hashKey = Hashing.hashKey(date: it.date, amount: amount, payee: it.desc, memo: nil, symbol: nil, quantity: nil)
            let tx = StagedTransaction(
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
                sourceAccountLabel: outputAccountLabel,
                include: true
            )
            AMLogging.log("TX \(i) built — date=\(it.date), desc=\(it.desc), amount=\(amount), include=true, account=\(it.account ?? "(nil)")", component: LOG_COMPONENT)
            txs.append(tx)
        }

        AMLogging.log("PDFBankTransactionsParser — produced tx: \(txs.count)", component: LOG_COMPONENT)
        if txs.isEmpty {
            throw ImportError.parseFailure("We couldn't detect any transactions in this PDF. You can try Summary Only mode to capture balances, or export a CSV for best results.")
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

    private func normalizeCreditCardActivityAmount(_ amount: Decimal, description: String, rawAmount: String, isCreditCardActivity: Bool) -> Decimal {
        guard isCreditCardActivity else { return amount }

        let upperRawAmount = rawAmount.uppercased()
        if upperRawAmount.contains("CR") || upperRawAmount.contains("CREDIT") {
            return amount.magnitude
        }
        if upperRawAmount.contains("DR") || upperRawAmount.contains("DEBIT") {
            return -amount.magnitude
        }

        let lowerDescription = description.lowercased()
        let normalizedDescription = lowerDescription
            .split(whereSeparator: { !$0.isLetter })
            .joined(separator: " ")
        let words = Set(normalizedDescription.split(separator: " ").map(String.init))
        let fusedPaymentRowCarriesDifferentAmount = embeddedPaymentAmountMagnitude(in: lowerDescription).map { $0 != amount.magnitude } ?? false
        let isPayment = !fusedPaymentRowCarriesDifferentAmount && (
            words.contains("payment")
            || words.contains("pymt")
            || words.contains("pmt")
            || words.contains("autopay")
            || (words.contains("auto") && words.contains("pay"))
        )
        let creditPhrases = [
            "refund", "return", "returned merchandise", "payment reversal",
            "statement credit", "account credit", "merchant credit", "credit adjustment"
        ]
        let isCredit = creditPhrases.contains { normalizedDescription.contains($0) }

        // DebtScope stores liability balances as negative values. Credit-card charges increase
        // the liability, so they are negative; payments and credits reduce it, so they are positive.
        if isPayment || isCredit {
            return amount.magnitude
        }

        return -amount.magnitude
    }

    private func embeddedPaymentAmountMagnitude(in lowerDescription: String) -> Decimal? {
        let amountPattern = #"(-\s*\$?\s*(?:[0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)(?:\.[0-9]{2}))"#
        let pattern = #"payment\s*-\s*thank\s+you\b.{0,160}?"# + amountPattern
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(lowerDescription.startIndex..<lowerDescription.endIndex, in: lowerDescription)
        guard let match = regex.firstMatch(in: lowerDescription, options: [], range: range),
              match.numberOfRanges >= 2,
              let amountRange = Range(match.range(at: 1), in: lowerDescription) else {
            return nil
        }

        let token = String(lowerDescription[amountRange])
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Decimal(string: token)?.magnitude
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

        let summaryBalanceMarkers = [
            "account summary", "previous balance", "new balance", "payment information",
            "credit line", "credit limit", "available credit", "payments and credits",
            "balance transfers", "cash advances", "fees charged", "interest charged"
        ]
        if summaryBalanceMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        if lower.contains("interest charge") {
            return false
        }
        if lower.contains("interest earned") || lower.contains("interest paid") {
            return false
        }

        if lower.contains("amount enclosed") || lower.contains("payment coupon") || lower.contains("return this portion") || lower.contains("mail payment") || lower.contains("remittance") {
            return true
        }

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
            "balance forward",
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
