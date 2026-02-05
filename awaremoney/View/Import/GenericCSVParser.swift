import Foundation

// Local error to avoid dependency on ambiguous ImportError in this context
enum GenericCSVImportError: Error {
    case invalidData(String)
}

struct GenericCSVParser: StatementParser {
    static var id: String { "csv.generic" }
    let mapping: CSVColumnMapping

    func canParse(headers: [String]) -> Bool {
        return mapping.matches(headers: headers)
    }

    func parse(rows: [[String]], headers: [String]) throws -> StagedImport {
        var transactions: [StagedTransaction] = []

        for row in rows {
            var valuesByKey: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                guard index < row.count else { continue }
                valuesByKey[header] = row[index]
            }

            guard
                let kindString = mapping.kindColumn.flatMap({ valuesByKey[$0] }),
                let kind = Transaction.Kind(rawValue: kindString.lowercased())
            else {
                throw GenericCSVImportError.invalidData("Missing or invalid transaction kind")
            }

            guard
                let dateString = mapping.dateColumn.flatMap({ valuesByKey[$0] }),
                let date = GenericCSVParser.parseDate(from: dateString)
            else {
                throw GenericCSVImportError.invalidData("Missing or invalid date")
            }

            guard
                let amountString = mapping.amountColumn.flatMap({ valuesByKey[$0] })?.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: ""),
                let amount = Decimal(string: amountString)
            else {
                throw GenericCSVImportError.invalidData("Missing or invalid amount")
            }

            let payee = mapping.payeeColumn.flatMap { valuesByKey[$0] }
            let memo = mapping.memoColumn.flatMap { valuesByKey[$0] }
            let category = mapping.categoryColumn.flatMap { valuesByKey[$0] }
            let account = mapping.accountColumn.flatMap { valuesByKey[$0] }

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

        return StagedImport(
            parserId: Self.id,
            sourceFileName: "Unknown.csv",
            inferredInstitutionName: nil,
            suggestedAccountType: nil,
            transactions: transactions,
            holdings: [],
            balances: []
        )
    }
}

private extension GenericCSVParser {
    static func parseDate(from s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let fmts = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd",
            "MM/dd/yyyy",
            "M/d/yyyy",
            "MM/dd/yy",
            "M/d/yy"
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
}

