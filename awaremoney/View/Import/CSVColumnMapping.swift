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
        case payee
        case memo
        case category
        case account
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
    var mappings: [Field: String]
    var amountMode: AmountMode
    var parsingOptions: ParsingOptions

    init(
        id: UUID = .init(),
        mappings: [Field: String] = [:],
        amountMode: AmountMode = .none,
        parsingOptions: ParsingOptions = ParsingOptions()
    ) {
        self.id = id
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

        for (field, mappedHeader) in mappings {
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
    var payeeColumn: String? { mappings[.payee] }
    var memoColumn: String? { mappings[.memo] }
    var categoryColumn: String? { mappings[.category] }
    var accountColumn: String? { mappings[.account] }
}

