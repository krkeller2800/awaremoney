import Foundation

// Local error to avoid dependency on ambiguous ImportError in this context
enum GenericCSVImportError: Error {
    case invalidData(String)
    case missingHeaders(String)
}

struct GenericCSVParser: StatementParser {
    static var id: String { "csv.generic" }
    let mapping: CSVColumnMapping
    let sourceFileName: String
    
    init(mapping: CSVColumnMapping, sourceFileName: String = "Mapped CSV") {
        self.mapping = mapping
        self.sourceFileName = sourceFileName
    }

    func canParse(headers: [String]) -> Bool {
        return mapping.matches(headers: headers)
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        let headerIndex: [String: Int] = {
            var map: [String: Int] = [:]
            for (idx, h) in headers.enumerated() { map[h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = idx }
            return map
        }()
        
        var transactions: [StagedTransaction] = []
        var holdings: [StagedHolding] = []
        var balances: [StagedBalance] = []

        for row in rows {
            var valuesByKey: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                guard index < row.count else { continue }
                valuesByKey[header] = row[index]
            }
            
            let lowerValuesByKey: [String: String] = Dictionary(uniqueKeysWithValues: valuesByKey.map { ($0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0.value) })
            
            let hasTxSignals = [mapping.amountColumn, mapping.dateColumn]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains(where: { headerIndex[$0] != nil })
            if hasTxSignals {
                // Use case-insensitive lookups for all mapped headers
                let dateHeader = mapping.dateColumn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let amountHeader = mapping.amountColumn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let payeeHeader = mapping.payeeColumn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let memoHeader = mapping.memoColumn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let categoryHeader = mapping.categoryColumn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let accountHeader = mapping.accountColumn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let kindHeader = mapping.kindColumn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

                guard
                    let dateString = dateHeader.flatMap({ lowerValuesByKey[$0] }),
                    let date = GenericCSVParser.parseDate(from: dateString)
                else {
                    continue
                }

                guard let amount = GenericCSVParser.parseDecimal(from: amountHeader.flatMap({ lowerValuesByKey[$0] })) else { continue }

                let payee = payeeHeader.flatMap { lowerValuesByKey[$0] }
                let memo = memoHeader.flatMap { lowerValuesByKey[$0] }
                let category = categoryHeader.flatMap { lowerValuesByKey[$0] }
                let account = accountHeader.flatMap { lowerValuesByKey[$0] }

                // Derive kind from mapping or fall back to a reasonable default
                let rawKind = kindHeader.flatMap({ lowerValuesByKey[$0] })?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let kind: Transaction.Kind = {
                    if let rk = rawKind, let exact = Transaction.Kind(rawValue: rk) { return exact }
                    switch rawKind {
                    case "deposit": return .deposit
                    case "withdrawal": return .withdrawal
                    case "buy": return .buy
                    case "sell": return .sell
                    case "dividend": return .dividend
                    case "fee": return .fee
                    case "interest": return .interest
                    case "transfer": return .transfer
                    case "adjustment": return .adjustment
                    case "debit", "credit", "payment", "purchase", "charge": return .bank
                    default: return .bank
                    }
                }()

                let hashKey = Hashing.hashKey(date: date, amount: amount, payee: payee ?? "", memo: memo, symbol: nil, quantity: nil)
                let tx = StagedTransaction(
                    datePosted: date,
                    amount: amount,
                    payee: payee ?? "",
                    memo: memo,
                    kind: kind,
                    externalId: nil,
                    symbol: nil,
                    quantity: nil,
                    price: nil,
                    fees: nil,
                    hashKey: hashKey,
                    sourceAccountLabel: account,
                    include: true
                )

                transactions.append(tx)
            }
            
            let symbolHeader = mapping.symbolColumn?.lowercased()
            let qtyHeader = mapping.quantityColumn?.lowercased()
            let priceHeader = mapping.priceColumn?.lowercased()
            let mvHeader = mapping.marketValueColumn?.lowercased()
            let hasHoldingSignals = [symbolHeader, qtyHeader, priceHeader, mvHeader].compactMap { $0 }.contains(where: { headerIndex[$0] != nil })
            if hasHoldingSignals {
                let symbol = symbolHeader.flatMap { lowerValuesByKey[$0] }?.trimmingCharacters(in: .whitespacesAndNewlines)
                let qtyStr = qtyHeader.flatMap { lowerValuesByKey[$0] }
                let priceStr = priceHeader.flatMap { lowerValuesByKey[$0] }
                let mvStr = mvHeader.flatMap { lowerValuesByKey[$0] }
                let qty = qtyStr.flatMap { GenericCSVParser.parseDecimal(from: $0) } ?? 0
                let price = priceStr.flatMap { GenericCSVParser.parseDecimal(from: $0) }
                let mv = mvStr.flatMap { GenericCSVParser.parseDecimal(from: $0) }
                if let symbol = symbol, !symbol.isEmpty {
                    let holding = StagedHolding(
                        asOfDate: {
                            let dateHeader = mapping.dateColumn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            return GenericCSVParser.parseDate(from: dateHeader.flatMap { lowerValuesByKey[$0] }) ?? Date()
                        }(),
                        symbol: symbol,
                        quantity: qty,
                        marketValue: mv ?? (price.flatMap { $0 * qty }),
                        include: true
                    )
                    holdings.append(holding)
                }
            }
            
            let balHeader = mapping.balanceColumn?.lowercased()
            let runningHeader = mapping.runningBalanceColumn?.lowercased()
            let hasBalanceSignals = [balHeader, runningHeader].compactMap { $0 }.contains(where: { headerIndex[$0] != nil })
            if hasBalanceSignals {
                let dateHeader = mapping.dateColumn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let date = GenericCSVParser.parseDate(from: dateHeader.flatMap { lowerValuesByKey[$0] })
                let balStr = balHeader.flatMap { lowerValuesByKey[$0] } ?? runningHeader.flatMap { lowerValuesByKey[$0] }
                if let bal = GenericCSVParser.parseDecimal(from: balStr), let date = date {
                    balances.append(StagedBalance(asOfDate: date, balance: bal))
                }
            }
        }
        
        if let aprHeader = mapping.interestRateAPRColumn?.lowercased(), headerIndex[aprHeader] != nil {
            // Try to apply APR to all balances if any APR value exists in rows
            for row in rows {
                if let idx = headerIndex[aprHeader], idx < row.count {
                    let raw = row[idx].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
                    if let dec = Decimal(string: raw), dec != 0 {
                        var fraction = dec
                        if fraction > 1 { fraction /= 100 }
                        for i in balances.indices { if balances[i].interestRateAPR == nil { balances[i].interestRateAPR = fraction; balances[i].interestRateScale = GenericCSVParser.decimalPlaces(in: raw) } }
                        break
                    }
                }
            }
        }
        
        return StagedImport(
            parserId: Self.id,
            sourceFileName: sourceFileName,
            inferredInstitutionName: nil,
            suggestedAccountType: nil,
            transactions: transactions,
            holdings: holdings,
            balances: balances
        )
    }
}

private extension GenericCSVParser {
    static func parseDate(from s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let fmts = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "MM/dd/yyyy HH:mm:ss",
            "M/d/yyyy H:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "yyyyMMdd",
            "MM/dd/yyyy",
            "M/d/yyyy",
            "MM/dd/yy",
            "M/d/yy",
            "MM-dd-yyyy",
            "M-d-yyyy",
            "dd/MM/yyyy",
            "d/M/yyyy",
            "dd-MM-yyyy",
            "d-M-yyyy"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for f in fmts {
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
    
    static func parseDecimal(from s: String?) -> Decimal? {
        guard var raw = s?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let upper = raw.uppercased()
        var negativeHint = false
        var positiveHint = false

        if raw.hasPrefix("(") && raw.hasSuffix(")") {
            negativeHint = true
            raw.removeFirst()
            raw.removeLast()
        }
        if raw.hasSuffix("-") { negativeHint = true; raw.removeLast() }
        if raw.hasPrefix("-") { negativeHint = true; raw.removeFirst() }
        if raw.hasPrefix("- ") { negativeHint = true; raw.removeFirst() }

        if upper.contains("DR") || upper.contains("DEBIT") { negativeHint = true }
        if upper.contains("CR") || upper.contains("CREDIT") { positiveHint = true }

        var cleaned = raw
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        let markers = ["CR", "DR", "CREDIT", "DEBIT"]
        for m in markers { cleaned = cleaned.replacingOccurrences(of: m, with: "", options: [.caseInsensitive]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if negativeHint && !positiveHint && !cleaned.hasPrefix("-") { cleaned = "-" + cleaned }
        return Decimal(string: cleaned)
    }
    
    static func decimalPlaces(in s: String) -> Int {
        let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = cleaned.firstIndex(of: ".") {
            return cleaned.distance(from: cleaned.index(after: dot), to: cleaned.endIndex)
        }
        return 0
    }
}

