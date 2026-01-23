//
//  BrokerageCSVParser.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation

struct BrokerageCSVParser: StatementParser {
    static let dateFormats = ["MM/dd/yyyy", "yyyy-MM-dd"]
    static var id: String { "brokerage.csv" }

    func canParse(headers: [String]) -> Bool {
        let lower = headers.map { $0.lowercased() }
        return lower.contains(where: { $0.contains("action") }) &&
               lower.contains(where: { $0.contains("symbol") }) &&
               lower.contains(where: { $0.contains("date") })
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        let map = headerMap(headers)
        var txs: [StagedTransaction] = []
        let holdings: [StagedHolding] = [] // Optional snapshot rows if present

        for row in rows {
            guard let dateStr = value(row, map, key: "date"),
                  let date = parseDate(dateStr) else { continue }

            let action = (value(row, map, key: "action") ?? "").lowercased()
            let symbol = value(row, map, key: "symbol") ?? ""
            let quantity = Decimal(string: sanitize(value(row, map, key: "quantity")))
            let price = Decimal(string: sanitize(value(row, map, key: "price")))
            let fees = Decimal(string: sanitize(value(row, map, key: "fees")))
            let amount = Decimal(string: sanitize(value(row, map, key: "amount")))

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

            let payee = symbol.isEmpty ? action.capitalized : "\(action.capitalized) \(symbol)"
            let hashKey = Hashing.hashKey(date: date, amount: computedAmount, payee: payee, memo: nil, symbol: symbol.isEmpty ? nil : symbol, quantity: quantity)

            let tx = StagedTransaction(
                datePosted: date,
                amount: computedAmount,
                payee: payee,
                memo: nil,
                kind: kind,
                externalId: value(row, map, key: "id"),
                symbol: symbol.isEmpty ? nil : symbol,
                quantity: quantity,
                price: price,
                fees: fees,
                hashKey: hashKey
            )
            txs.append(tx)

            // Optional: detect snapshot rows (broker-specific). For MVP, skip unless explicit.
        }

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
