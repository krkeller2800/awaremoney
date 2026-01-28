//
//  BrokerageCSVParser.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation

private let LOG_COMPONENT = "BrokerageCSVParser"

struct BrokerageCSVParser: StatementParser {
    static let dateFormats = ["MM/dd/yyyy", "yyyy-MM-dd"]
    static var id: String { "brokerage.csv" }

    func canParse(headers: [String]) -> Bool {
        let lower = headers.map { $0.lowercased() }
        AMLogging.always("canParse? headers: \(lower)", component: LOG_COMPONENT)
        return lower.contains(where: { $0.contains("action") }) &&
               lower.contains(where: { $0.contains("symbol") }) &&
               lower.contains(where: { $0.contains("date") })
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        let map = headerMap(headers)
        AMLogging.always("parse() — rows: \(rows.count), headers: \(headers)", component: LOG_COMPONENT)
        AMLogging.always("header map keys: \(Array(map.keys))", component: LOG_COMPONENT)
        var txs: [StagedTransaction] = []
        let holdings: [StagedHolding] = [] // Optional snapshot rows if present

        for row in rows {
            let rawRow = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if rawRow.allSatisfy({ $0.isEmpty }) { continue }
            guard let dateStr = value(rawRow, map, key: "date"),
                  let date = parseDate(dateStr) else { continue }

            let action = (value(rawRow, map, key: "action") ?? "").lowercased()
            let symbol = value(rawRow, map, key: "symbol") ?? ""
            let quantity = Decimal(string: sanitize(value(rawRow, map, key: "quantity")))
            let price = Decimal(string: sanitize(value(rawRow, map, key: "price")))
            let fees = Decimal(string: sanitize(value(rawRow, map, key: "fees")))
            let amount = Decimal(string: sanitize(value(rawRow, map, key: "amount")))

            let kind: Transaction.Kind
            switch action {
            case "buy": kind = .buy
            case "sell": kind = .sell
            case "dividend": kind = .dividend
            case "deposit": kind = .deposit
            case "withdrawal": kind = .withdrawal
            default: kind = .bank
            }

            // Prefer explicit amount if present, else derive from quantity*price +/- fees
            let computedAmount: Decimal = {
                if let a = amount { return a }
                if let q = quantity, let p = price {
                    var gross = q * p
                    if let f = fees { gross -= f }
                    // For buys, amount is negative cash; for sells, positive
                    if kind == .buy { gross *= -1 }
                    return gross
                }
                return 0
            }()

            AMLogging.log("Row parsed — action: \(action), symbol: \(symbol), qty: \(String(describing: quantity)), price: \(String(describing: price)), fees: \(String(describing: fees)), amount: \(String(describing: amount)) => computed: \(computedAmount)", component: LOG_COMPONENT)

            let payee = symbol.isEmpty ? action.capitalized : "\(action.capitalized) \(symbol)"
            let hashKey = Hashing.hashKey(date: date, amount: computedAmount, payee: payee, memo: nil, symbol: symbol.isEmpty ? nil : symbol, quantity: quantity)

            let tx = StagedTransaction(
                datePosted: date,
                amount: computedAmount,
                payee: payee,
                memo: nil,
                kind: kind,
                externalId: value(rawRow, map, key: "id"),
                symbol: symbol.isEmpty ? nil : symbol,
                quantity: quantity,
                price: price,
                fees: fees,
                hashKey: hashKey
            )
            txs.append(tx)

            if tx.kind == .bank && (symbol.isEmpty || quantity == nil) {
                AMLogging.log("Skipped brokerage-specific fields; defaulted kind .bank — row may be non-trade activity", component: LOG_COMPONENT)
            }

            // Optional: detect snapshot rows (broker-specific). For MVP, skip unless explicit.
        }

        AMLogging.always("parse() result — tx: \(txs.count), holdings: 0, balances: 0", component: LOG_COMPONENT)
        return StagedImport(
            parserId: Self.id,
            sourceFileName: "Unknown.csv",
            suggestedAccountType: .brokerage,
            transactions: txs,
            holdings: holdings,
            balances: []
        )
    }

    // MARK: helpers

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

    private func parseDate(_ s: String) -> Date? {
        for fmt in Self.dateFormats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    private func sanitize(_ s: String?) -> String {
        guard let s else { return "" }
        return s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
    }
}

