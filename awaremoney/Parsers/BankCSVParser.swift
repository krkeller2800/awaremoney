//
//  BankCSVParser.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation

struct BankCSVParser: StatementParser {
    static let dateFormats = ["MM/dd/yyyy", "yyyy-MM-dd", "M/d/yyyy"]
    static var id: String { "bank.csv" }

    func canParse(headers: [String]) -> Bool {
        let lower = headers.map { $0.lowercased() }
        let hasDate = lower.contains(where: { $0.contains("date") })
        let hasDesc = lower.contains(where: { $0.contains("description") || $0.contains("payee") || $0.contains("memo") })
        let hasAmount = lower.contains("amount") || (lower.contains("debit") || lower.contains("credit"))
        return hasDate && hasDesc && hasAmount
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        let map = headerMap(headers)
        var staged: [StagedTransaction] = []

        let hasBalanceColumn = map.keys.contains(where: { $0.contains("balance") })

        var earliest: (date: Date, amount: Decimal, runningBalance: Decimal)? = nil
        var latest: (date: Date, runningBalance: Decimal)? = nil

        var balances: [StagedBalance] = []

        for row in rows {
            guard let dateStr = value(row, map, key: "date"),
                  let date = parseDate(dateStr) else { continue }

            let desc = value(row, map, key: "description") ?? value(row, map, key: "payee") ?? "Unknown"
            let memo = value(row, map, key: "memo")

            // Amount logic
            let amount = try parseAmount(row: row, map: map)

            // Optional running balance column (e.g., Chase CSVs)
            if hasBalanceColumn, let balStr = value(row, map, key: "balance"),
               let bal = Decimal(string: sanitizeAmount(balStr)) {
                // Track earliest transaction with a running balance
                if let e = earliest {
                    if date < e.date {
                        earliest = (date, amount, bal)
                    }
                } else {
                    earliest = (date, amount, bal)
                }

                // Track latest running balance by date
                if let l = latest {
                    if date > l.date { latest = (date, bal) }
                } else {
                    latest = (date, bal)
                }
            }

            let hashKey = Hashing.hashKey(date: date, amount: amount, payee: desc, memo: memo, symbol: nil, quantity: nil)

            let tx = StagedTransaction(
                datePosted: date,
                amount: amount,
                payee: desc,
                memo: memo,
                kind: .bank,
                externalId: value(row, map, key: "id"),
                symbol: nil,
                quantity: nil,
                price: nil,
                fees: nil,
                hashKey: hashKey
            )
            staged.append(tx)
        }

        // Build balance snapshots if present
        if let e = earliest {
            // Opening balance before applying the earliest transaction on that date
            let opening = e.runningBalance - e.amount
            balances.append(StagedBalance(asOfDate: e.date, balance: opening))
        }
        if let l = latest {
            balances.append(StagedBalance(asOfDate: l.date, balance: l.runningBalance))
        }

        return StagedImport(
            parserId: Self.id,
            sourceFileName: "Unknown.csv",
            suggestedAccountType: .checking,
            transactions: staged,
            holdings: [],
            balances: balances
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

    private func parseAmount(row: [String], map: [String: Int]) throws -> Decimal {
        if let amountStr = value(row, map, key: "amount"), let dec = Decimal(string: sanitizeAmount(amountStr)) {
            return dec
        }
        let debitStr = value(row, map, key: "debit")
        let creditStr = value(row, map, key: "credit")
        if let d = debitStr, let dec = Decimal(string: sanitizeAmount(d)) { return -dec }
        if let c = creditStr, let dec = Decimal(string: sanitizeAmount(c)) { return dec }
        throw ImportError.parseFailure("Missing amount")
    }

    private func sanitizeAmount(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
    }
}

