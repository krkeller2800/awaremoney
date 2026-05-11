import Foundation
import SwiftData

@Model
final class CSVColumnMapping {
    enum Field: String, CaseIterable, Codable, Sendable {
        case name
        case email
        case phone
        case address
        case company
        case title
        case notes
        case date
        case kind
        case amount
        case debit
        case credit
        case payee
        case memo
        case category
        case account
        case symbol
        case quantity
        case price
        case marketValue
        case balance
        case runningBalance
        case interestRateAPR
    }

    enum AmountMode: String, Codable, Sendable {
        case none
        case integer
        case decimal
        case currency
    }

    struct ParsingOptions: Codable, Sendable {
        var ignoreCase: Bool = true
        var trimWhitespace: Bool = true
        var allowMissingColumns: Bool = false
    }

    @Attribute(.unique) var id: UUID
    var label: String?
    var mappings: [Field: String]
    var amountMode: AmountMode
    var parsingOptions: ParsingOptions

    init(
        id: UUID = .init(),
        label: String? = nil,
        mappings: [Field: String] = [:],
        amountMode: AmountMode = .none,
        parsingOptions: ParsingOptions = ParsingOptions()
    ) {
        self.id = id
        self.label = label
        self.mappings = mappings
        self.amountMode = amountMode
        self.parsingOptions = parsingOptions
    }

    static func headerSignature() -> [String] {
        Field.allCases.map { $0.rawValue.capitalized }
    }

    func matches(headers: [String]) -> Bool {
        let processedHeaders = parsingOptions.ignoreCase
            ? headers.map { $0.lowercased() }
            : headers

        for (_, mappedHeader) in mappings {
            let comparisonTarget = parsingOptions.ignoreCase
                ? mappedHeader.lowercased()
                : mappedHeader

            if parsingOptions.trimWhitespace {
                if !processedHeaders.contains(where: { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == comparisonTarget.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }) {
                    if !parsingOptions.allowMissingColumns {
                        return false
                    }
                }
            } else {
                if !processedHeaders.contains(comparisonTarget) {
                    if !parsingOptions.allowMissingColumns {
                        return false
                    }
                }
            }
        }
        return true
    }
}
extension CSVColumnMapping {
    var dateColumn: String? { mappings[.date] }
    var kindColumn: String? { mappings[.kind] }
    var amountColumn: String? { mappings[.amount] }
    var debitColumn: String? { mappings[.debit] }
    var creditColumn: String? { mappings[.credit] }
    var payeeColumn: String? { mappings[.payee] }
    var memoColumn: String? { mappings[.memo] }
    var categoryColumn: String? { mappings[.category] }
    var accountColumn: String? { mappings[.account] }
    var symbolColumn: String? { mappings[.symbol] }
    var quantityColumn: String? { mappings[.quantity] }
    var priceColumn: String? { mappings[.price] }
    var marketValueColumn: String? { mappings[.marketValue] }
    var balanceColumn: String? { mappings[.balance] }
    var runningBalanceColumn: String? { mappings[.runningBalance] }
    var interestRateAPRColumn: String? { mappings[.interestRateAPR] }

    static func suggestedMappings(from rawHeaders: [String], sampleRows: [[String]]) -> [Field: String] {
        let normalized = rawHeaders.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        func findHeader(where predicate: (String) -> Bool) -> String? {
            for (index, lowercasedHeader) in normalized.enumerated() where predicate(lowercasedHeader) {
                return rawHeaders[index]
            }
            return nil
        }

        func findHeader(containing tokens: [String]) -> String? {
            findHeader { lowercasedHeader in
                tokens.contains { lowercasedHeader.contains($0) }
            }
        }

        let dateHeader = findHeader(containing: ["transaction date"]) ??
            findHeader(containing: ["post date"]) ??
            findHeader(containing: ["date"])

        let payeeHeader = findHeader { header in
            (header.contains("description") || header.contains("payee") || header.contains("memo") || header.contains("details")) && !header.contains("date")
        }

        var amountHeader: String? = findHeader(containing: ["amount", "amt", "charge"])
        let debitHeader = findHeader(containing: ["debit", "withdrawal"])
        let creditHeader = findHeader(containing: ["credit", "deposit"])

        if amountHeader == nil {
            let excludeTokens = ["date", "description", "payee", "memo", "details", "category", "account", "acct", "balance", "running", "type", "kind", "apr", "interest"]
            let excludedIndices: Set<Int> = Set(rawHeaders.enumerated().compactMap { index, header in
                let lower = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return excludeTokens.contains(where: { lower.contains($0) }) ? index : nil
            })
            var numericCounts: [Int: Int] = [:]
            for row in sampleRows.prefix(50) {
                for (index, cell) in row.enumerated() where !excludedIndices.contains(index) {
                    let cleaned = cell
                        .replacingOccurrences(of: ",", with: "")
                        .replacingOccurrences(of: "$", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty, Decimal(string: cleaned) != nil {
                        numericCounts[index, default: 0] += 1
                    }
                }
            }
            if let bestIndex = numericCounts.max(by: { $0.value < $1.value })?.key, bestIndex < rawHeaders.count {
                amountHeader = rawHeaders[bestIndex]
            }
        }

        var result: [Field: String] = [:]
        if let header = dateHeader { result[.date] = header }
        if let header = payeeHeader { result[.payee] = header }
        if let header = amountHeader { result[.amount] = header }
        if amountHeader == nil, let header = debitHeader { result[.debit] = header }
        if amountHeader == nil, let header = creditHeader { result[.credit] = header }
        if let header = findHeader(containing: ["type", "kind"]) { result[.kind] = header }
        if let header = findHeader(containing: ["category"]) { result[.category] = header }
        if let header = findHeader(containing: ["account", "acct"]) { result[.account] = header }
        if let header = findHeader(containing: ["balance"]) { result[.balance] = header }
        return result
    }
}
